import NetworkExtension
import os.log

private enum NativeTunnelConfig {
    static let appGroup = "group.dev.icyou.blackhole.voyager"
    static let statusNotification = "com.blackhole.voyager.vpn.status"
    static let statusDefaultsKey = "vpn_status_payload"
}

/// File-based debug log for PacketTunnelProvider (os_log not visible via idevicesyslog on iOS 18+).
private func tunnelDebugLog(_ message: String) {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NativeTunnelConfig.appGroup
    ) else { return }
    let logURL = containerURL.appendingPathComponent("tunnel_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

private extension TunnelRuntimeStatus {
    var tunnelStatus: TunnelStatus {
        switch self {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .error:
            return .error
        }
    }
}

private enum WireGuardIngressPath {
    case direct
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.blackhole.voyager.tunnel", category: "PacketTunnel")

    private var tunnelHandle: UnsafeMutableRawPointer?
    private var udpSession: NWUDPSession?
    private var netcheckSession: NWUDPSession?
    private var isRunning = false
    private var activeConfig: TunnelConfig?
    private var tunnelConfigJson: String?
    private let wgQueue = DispatchQueue(label: "com.blackhole.voyager.tunnel.wg")
    private let runtime = TunnelRuntimeCoordinator()
    private let directDatapath = DirectDatapathCoordinator()
    private lazy var directPunchAttempt = DirectPunchAttemptCoordinator(
        retryWindow: runtime.handshakeTimeout
    )
    private var lastStatusSignature: String?
    private var tunPacketsOut: UInt64 = 0
    private var tunPacketsIn: UInt64 = 0
    private var udpPacketsOut: UInt64 = 0
    private var udpPacketsIn: UInt64 = 0
    private var directWriteAttempts: UInt64 = 0
    private var directWriteErrors: UInt64 = 0
    private var directHandshakePacketsPrepared: UInt64 = 0
    private var directHandshakePacketsSuppressed: UInt64 = 0
    private var directProbeWriteAttempts: UInt64 = 0
    private var lastDirectWriteLabel: String?
    private var lastDirectWriteError: String?
    private var directCandidates: [DirectCandidateConfig] = []
    private var observedCandidates: [DirectCandidateConfig] = []
    private var activeDirectCandidateIndex = 0
    private var directPunchTimer: DispatchSourceTimer?
    private var directSessionStateObservation: NSKeyValueObservation?
    private var directSessionViableObservation: NSKeyValueObservation?
    private var directSessionStateDescription: String?
    private var directSessionIsViable: Bool?

    private var activeDirectCandidate: DirectCandidateConfig? {
        guard directCandidates.indices.contains(activeDirectCandidateIndex) else {
            return nil
        }
        return directCandidates[activeDirectCandidateIndex]
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel", log: log, type: .info)

        guard let config = loadConfig(options: options) else {
            failStart(
                code: 1,
                message: "No VPN configuration found",
                completionHandler: completionHandler
            )
            return
        }
        activeConfig = config
        lastStatusSignature = nil
        tunPacketsOut = 0
        tunPacketsIn = 0
        udpPacketsOut = 0
        udpPacketsIn = 0
        directWriteAttempts = 0
        directWriteErrors = 0
        directHandshakePacketsPrepared = 0
        directHandshakePacketsSuppressed = 0
        directProbeWriteAttempts = 0
        lastDirectWriteLabel = nil
        lastDirectWriteError = nil
        directCandidates = []
        observedCandidates = []
        activeDirectCandidateIndex = 0
        directPunchAttempt.stop()
        directSessionStateObservation = nil
        directSessionViableObservation = nil
        directSessionStateDescription = nil
        directSessionIsViable = nil
        directDatapath.reset()
        runtime.start()
        applyRuntimeStatus(force: true)

        // Initialize blackhole_wg tunnel
        guard let configJson = try? JSONSerialization.data(withJSONObject: [
            "private_key": config.privateKey,
            "peer_public_key": config.peerPublicKey,
            "preshared_key": config.presharedKey as Any,
            "keepalive_secs": config.keepaliveSecs as Any,
        ]) else {
            failStart(
                code: 2,
                message: "Failed to serialize config",
                completionHandler: completionHandler
            )
            return
        }

        let configStr = String(data: configJson, encoding: .utf8)!
        tunnelConfigJson = configStr
        guard recreateTunnelHandle() else {
            failStart(
                code: 3,
                message: "Failed to create WG tunnel",
                completionHandler: completionHandler
            )
            return
        }

        // Configure network settings
        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.serverAddr)
        let (subnetAddress, subnetMask) = parseCIDR(config.subnet) ?? ("10.13.37.0", "255.255.255.0")

        let ipv4Settings = NEIPv4Settings(addresses: [config.clientIp], subnetMasks: [subnetMask])

        // Split tunnel: only route internal networks through VPN
        var includedRoutes: [NEIPv4Route] = []
        for route in config.internalRoutes {
            if let (destinationAddress, routeMask) = parseCIDR(route) {
                includedRoutes.append(
                    NEIPv4Route(destinationAddress: destinationAddress, subnetMask: routeMask)
                )
            }
        }
        // Always include the VPN subnet
        includedRoutes.append(
            NEIPv4Route(destinationAddress: subnetAddress, subnetMask: subnetMask)
        )
        ipv4Settings.includedRoutes = includedRoutes

        tunnelSettings.ipv4Settings = ipv4Settings
        tunnelSettings.mtu = NSNumber(value: config.mtu)

        // DNS settings
        let dnsSettings = NEDNSSettings(servers: config.dns)
        // Keep the VPN as a true split tunnel by default. If we set [""] here,
        // iOS routes all DNS lookups through the tunnel, which can interfere
        // with non-VPN control traffic such as the Wormhole websocket. Only
        // enable split-DNS when the config explicitly provides match domains.
        if !config.dnsMatchDomains.isEmpty {
            dnsSettings.matchDomains = config.dnsMatchDomains
        }
        tunnelSettings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(tunnelSettings) { [weak self] error in
            if let error = error {
                os_log("Failed to set tunnel settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                self?.runtime.fail(error.localizedDescription)
                self?.applyRuntimeStatus(force: true)
                completionHandler(error)
                return
            }

            self?.isRunning = true
            self?.startPacketLoop(config: config)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping tunnel: %{public}@", log: log, type: .info, String(describing: reason))
        runtime.beginDisconnecting()
        applyRuntimeStatus(force: true)
        isRunning = false

        udpSession?.cancel()
        udpSession = nil
        directSessionStateObservation = nil
        directSessionViableObservation = nil
        directSessionStateDescription = nil
        directSessionIsViable = nil
        directDatapath.reset()
        netcheckSession?.cancel()
        netcheckSession = nil
        stopDirectPunchTimer()

        if let handle = tunnelHandle {
            bh_wg_tunnel_free(handle)
            tunnelHandle = nil
        }

        lastStatusSignature = nil
        runtime.stop()
        applyRuntimeStatus(force: true)
        activeConfig = nil
        tunnelConfigJson = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Handle messages from the main app
        if let message = String(data: messageData, encoding: .utf8) {
            os_log("App message: %{public}@", log: log, type: .info, message)
        }
        completionHandler?(nil)
    }

    // MARK: - Packet Loop

    private func startPacketLoop(config: TunnelConfig) {
        configureDirectCandidates(config: config)

        // Read packets from TUN and encapsulate
        readPacketsFromTUN()

        // Start timer for WG keepalives
        startTimerLoop()

        startInitialDirectFlow(config: config)
    }

    private func startInitialDirectFlow(config: TunnelConfig) {
        performNetcheckIfNeeded(config: config) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.activateDirectCandidate(index: self.activeDirectCandidateIndex)
        }
    }

    private func sendInitialHandshake() {
        sendInitialHandshake(preferDirectPath: runtime.snapshot.connectionMode == .direct)
    }

    private func sendInitialHandshake(preferDirectPath: Bool) {
        guard let handle = tunnelHandle else { return }

        var dst = Data(count: 256)
        var dstLen = dst.count
        let result = wgQueue.sync { () -> Int32 in
            dst.withUnsafeMutableBytes { dstPtr -> Int32 in
                bh_wg_force_handshake(
                    handle,
                    dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    &dstLen
                )
            }
        }

        guard result == BH_WG_WRITE_TO_NET, dstLen > 0 else {
            if preferDirectPath {
                directHandshakePacketsSuppressed &+= 1
                applyRuntimeStatus(force: true)
            }
            os_log("Initial handshake not emitted immediately", log: log, type: .debug)
            return
        }

        let packet = Data(dst.prefix(dstLen))
        if preferDirectPath {
            directHandshakePacketsPrepared &+= 1
            sendDirectPacket(
                packet,
                label: "Initial handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        } else {
            sendEncryptedPacket(
                packet,
                label: "Initial handshake"
            )
        }
    }

    private func readPacketsFromTUN() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self, self.isRunning else { return }

            for packet in packets {
                self.tunPacketsOut &+= 1
                self.encapsulateAndSend(packet: packet)
            }

            // Continue reading
            self.readPacketsFromTUN()
        }
    }

    private func encapsulateAndSend(packet: Data) {
        guard let handle = tunnelHandle else { return }

        var dst = Data(count: packet.count + 80) // WG overhead ~60 bytes + margin
        var dstLen = dst.count

        let result = wgQueue.sync { () -> Int32 in
            packet.withUnsafeBytes { srcPtr -> Int32 in
                dst.withUnsafeMutableBytes { dstPtr -> Int32 in
                    bh_wg_encapsulate(
                        handle,
                        srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        srcPtr.count,
                        dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        &dstLen
                    )
                }
            }
        }

        if result == BH_WG_WRITE_TO_NET {
            sendEncryptedPacket(Data(dst.prefix(dstLen)), label: "WireGuard packet")
        }
    }

    private func readPacketsFromUDP() {
        guard let session = udpSession else { return }

        session.setReadHandler({ [weak self] datagrams, error in
            guard let self = self, self.isRunning else { return }

            if let error = error {
                os_log("UDP read error: %{public}@", type: .error, error.localizedDescription)
                return
            }

            guard let datagrams = datagrams else { return }

            for datagram in datagrams {
                self.udpPacketsIn &+= 1
                self.decapsulateAndInject(datagram: datagram, ingressPath: .direct)
            }
        }, maxDatagrams: 64)
    }

    private func decapsulateAndInject(datagram: Data, ingressPath: WireGuardIngressPath = .direct) {
        guard let handle = tunnelHandle else { return }

        var dst = Data(count: datagram.count + 80)
        var dstLen = dst.count

        let result = wgQueue.sync { () -> Int32 in
            datagram.withUnsafeBytes { srcPtr -> Int32 in
                dst.withUnsafeMutableBytes { dstPtr -> Int32 in
                    bh_wg_decapsulate(
                        handle,
                        srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        srcPtr.count,
                        dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        &dstLen
                    )
                }
            }
        }

        let shouldPromoteReadyFromInboundDirectTraffic =
            ingressPath == .direct &&
            !directDatapath.isSessionReady &&
            (result == BH_WG_WRITE_TO_TUN || result == BH_WG_WRITE_TO_NET)

        if result == BH_WG_WRITE_TO_TUN {
            let ipPacket = dst.prefix(dstLen)
            // Determine IP version from first nibble
            let version: NSNumber = ipPacket.first.map { ($0 >> 4) == 6 ? 10 : 2 } ?? 2 // AF_INET6 : AF_INET
            tunPacketsIn &+= 1
            packetFlow.writePackets([ipPacket], withProtocols: [version])
        } else if result == BH_WG_WRITE_TO_NET {
            // Handshake response — return it over the same transport that
            // produced the packet so direct handshakes can complete before the
            // runtime has promoted the tunnel.
            let preferDirectPath = ingressPath == .direct
            sendEncryptedPacket(
                Data(dst.prefix(dstLen)),
                label: "WireGuard response",
                preferDirectPath: preferDirectPath
            )

            // Drain any buffered packets
            drainTunnel(preferDirectPath: preferDirectPath)
        }

        if shouldPromoteReadyFromInboundDirectTraffic {
            let queuedPackets = directDatapath.markReady()
            os_log(
                "Direct UDP session became usable after inbound WireGuard traffic",
                log: log,
                type: .info
            )
            applyRuntimeStatus(force: true)
            flushPendingDirectPackets(queuedPackets)
        }

        refreshHandshakeStatus()
    }

    private func drainTunnel(preferDirectPath: Bool = false) {
        guard let handle = tunnelHandle else { return }

        var dst = Data(count: 2048)
        var dstLen = dst.count

        let result = wgQueue.sync { () -> Int32 in
            dst.withUnsafeMutableBytes { dstPtr -> Int32 in
                // Call decapsulate with empty src to drain buffered packets
                let emptyPtr: UnsafePointer<UInt8>? = nil
                return bh_wg_decapsulate(handle, emptyPtr, 0, dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), &dstLen)
            }
        }

        if result == BH_WG_WRITE_TO_TUN && dstLen > 0 {
            let ipPacket = dst.prefix(dstLen)
            let version: NSNumber = ipPacket.first.map { ($0 >> 4) == 6 ? 10 : 2 } ?? 2
            tunPacketsIn &+= 1
            packetFlow.writePackets([ipPacket], withProtocols: [version])
            drainTunnel(preferDirectPath: preferDirectPath) // Continue draining
        } else if result == BH_WG_WRITE_TO_NET && dstLen > 0 {
            sendEncryptedPacket(
                Data(dst.prefix(dstLen)),
                label: "WireGuard drain packet",
                preferDirectPath: preferDirectPath
            )
            drainTunnel(preferDirectPath: preferDirectPath)
        }
    }

    private func startTimerLoop() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.isRunning, let handle = self.tunnelHandle else { return }

            var dst = Data(count: 2048)
            var dstLen = dst.count

            let result = self.wgQueue.sync { () -> Int32 in
                dst.withUnsafeMutableBytes { dstPtr -> Int32 in
                    bh_wg_update_timers(handle, dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), &dstLen)
                }
            }

            if result == BH_WG_WRITE_TO_NET && dstLen > 0 {
                let packet = Data(dst.prefix(dstLen))
                self.sendEncryptedPacket(
                    packet,
                    label: "WireGuard timer packet"
                )
            }

            self.refreshHandshakeStatus()

            self.startTimerLoop()
        }
    }

    // MARK: - Config & Status

    private func loadConfig(options: [String: NSObject]?) -> TunnelConfig? {
        let persistedConfig = loadPersistedConfig()

        if let options,
           let config = decodeConfig(from: options) {
            return config.preferringPersistedDirectCandidates(persistedConfig)
        }

        if let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let config = decodeConfig(from: providerConfig) {
            return config.preferringPersistedDirectCandidates(persistedConfig)
        }

        return persistedConfig
    }

    private func loadPersistedConfig() -> TunnelConfig? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeTunnelConfig.appGroup
        ) else { return nil }

        let configURL = containerURL.appendingPathComponent("vpn_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func decodeConfig(from object: Any) -> TunnelConfig? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func failStart(
        code: Int,
        message: String,
        completionHandler: @escaping (Error?) -> Void
    ) {
        runtime.fail(message)
        applyRuntimeStatus(force: true)
        if let handle = tunnelHandle {
            bh_wg_tunnel_free(handle)
            tunnelHandle = nil
        }
        activeConfig = nil
        completionHandler(
            NSError(
                domain: "VoyagerTunnel",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private func applyRuntimeStatus(force: Bool = false) {
        updateStatus(
            runtime.snapshot.status.tunnelStatus,
            error: runtime.snapshot.error,
            force: force
        )
    }

    private func updateStatus(_ status: TunnelStatus, error: String? = nil, force: Bool = false) {
        let statusMode = activeConfig == nil ? nil : runtime.snapshot.connectionMode.rawValue

        var stats = bh_wg_stats(
            time_since_last_handshake_secs: -1,
            tx_bytes: 0,
            rx_bytes: 0,
            estimated_loss: 0,
            estimated_rtt_ms: -1
        )
        let didLoadStats = tunnelHandle != nil && withUnsafeMutablePointer(to: &stats) { pointer in
            bh_wg_get_stats(tunnelHandle, pointer) == 1
        }

        let wgTxBytes = didLoadStats ? stats.tx_bytes : nil
        let wgRxBytes = didLoadStats ? stats.rx_bytes : nil
        var signatureParts: [String] = []
        signatureParts.append(status.rawValue)
        signatureParts.append(statusMode ?? "")
        signatureParts.append(error ?? "")
        signatureParts.append(String(tunPacketsOut))
        signatureParts.append(String(tunPacketsIn))
        signatureParts.append(String(udpPacketsOut))
        signatureParts.append(String(udpPacketsIn))
        signatureParts.append(String(directWriteAttempts))
        signatureParts.append(String(directWriteErrors))
        signatureParts.append(String(directHandshakePacketsPrepared))
        signatureParts.append(String(directHandshakePacketsSuppressed))
        signatureParts.append(String(directProbeWriteAttempts))
        signatureParts.append(String(wgTxBytes ?? 0))
        signatureParts.append(String(wgRxBytes ?? 0))
        signatureParts.append(String(didLoadStats ? stats.time_since_last_handshake_secs : -1))
        signatureParts.append(directCandidates.map { "\($0.scope):\($0.addr):\($0.port):\($0.priority)" }.joined(separator: ","))
        signatureParts.append(String(activeDirectCandidateIndex))
        signatureParts.append(activeDirectCandidate?.addr ?? "")
        signatureParts.append(activeDirectCandidate?.scope ?? "")
        signatureParts.append(directSessionStateDescription ?? "")
        signatureParts.append(String(directSessionIsViable ?? false))
        signatureParts.append(String(directDatapath.isSessionReady))
        signatureParts.append(String(directDatapath.pendingPackets.count))
        signatureParts.append(lastDirectWriteLabel ?? "")
        signatureParts.append(lastDirectWriteError ?? "")
        let signature = signatureParts.joined(separator: "|")
        if !force && lastStatusSignature == signature {
            return
        }
        lastStatusSignature = signature

        let info = TunnelStatusInfo(
            status: status,
            timestamp: Date(),
            clientIp: activeConfig?.clientIp,
            serverIp: activeConfig?.serverIp,
            lanPort: activeConfig?.lanPort,
            connectionMode: statusMode,
            tunPacketsOut: tunPacketsOut,
            tunPacketsIn: tunPacketsIn,
            udpPacketsOut: udpPacketsOut,
            udpPacketsIn: udpPacketsIn,
            wgTxBytes: wgTxBytes,
            wgRxBytes: wgRxBytes,
            timeSinceLastHandshakeSecs: didLoadStats ? stats.time_since_last_handshake_secs : -1,
            plannedDirectCandidates: directCandidates.isEmpty ? nil : directCandidates,
            observedCandidates: observedCandidates.isEmpty ? nil : observedCandidates,
            activeDirectCandidateIndex: activeDirectCandidate != nil ? activeDirectCandidateIndex : nil,
            activeDirectCandidate: activeDirectCandidate,
            directSessionState: directSessionStateDescription,
            directSessionViable: directSessionIsViable,
            directSessionReady: directDatapath.isSessionReady,
            pendingDirectQueueDepth: directDatapath.pendingPackets.count,
            directWriteAttempts: directWriteAttempts,
            directWriteErrors: directWriteErrors,
            directHandshakePacketsPrepared: directHandshakePacketsPrepared,
            directHandshakePacketsSuppressed: directHandshakePacketsSuppressed,
            directProbeWriteAttempts: directProbeWriteAttempts,
            lastDirectWriteLabel: lastDirectWriteLabel,
            lastDirectWriteError: lastDirectWriteError,
            error: error
        )
        let statusData = try? JSONEncoder().encode(info)
        if let defaults = UserDefaults(suiteName: NativeTunnelConfig.appGroup) {
            defaults.set(statusData, forKey: NativeTunnelConfig.statusDefaultsKey)
            defaults.synchronize()
        }
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeTunnelConfig.appGroup
        ) {
            let statusURL = containerURL.appendingPathComponent("vpn_status.json")
            if let statusData {
                try? statusData.write(to: statusURL, options: .atomic)
            }
        }

        // Post Darwin notification for status change
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(NativeTunnelConfig.statusNotification as CFString), nil, nil, true)
    }

    private func refreshHandshakeStatus() {
        guard isRunning, let handle = tunnelHandle else { return }

        var stats = bh_wg_stats(
            time_since_last_handshake_secs: -1,
            tx_bytes: 0,
            rx_bytes: 0,
            estimated_loss: 0,
            estimated_rtt_ms: -1
        )
        let didLoadStats = withUnsafeMutablePointer(to: &stats) { pointer in
            bh_wg_get_stats(handle, pointer) == 1
        }
        guard didLoadStats else { return }

        let previousSnapshot = runtime.snapshot
        let handshakeAgeSeconds = stats.time_since_last_handshake_secs >= 0
            ? stats.time_since_last_handshake_secs
            : nil
        let action = runtime.refresh(
            handshakeAgeSeconds: handshakeAgeSeconds,
            inboundWireGuardBytes: stats.rx_bytes,
            inboundUdpPackets: udpPacketsIn,
            availableDirectCandidateCount: max(directCandidates.count, 1)
        )

        if runtime.snapshot != previousSnapshot {
            switch (previousSnapshot.status, runtime.snapshot.status) {
            case (_, .connected):
                os_log(
                    "WireGuard handshake completed after %{public}llds",
                    log: log,
                    type: .info,
                    handshakeAgeSeconds ?? -1
                )
            case (_, .error):
                os_log("WireGuard handshake timed out", log: log, type: .error)
            default:
                break
            }
        }

        if !TunnelRetryTimerPolicy.shouldKeepDirectPunchRunning(
            snapshot: runtime.snapshot
        ) {
            stopDirectPunchTimer()
        }

        applyRuntimeStatus()

        switch action {
        case .none:
            break
        case .retryDirect(let index):
            os_log(
                "Direct WireGuard candidate %{public}d timed out, retrying next candidate",
                log: log,
                type: .info,
                index
            )
            activateDirectCandidate(index: index)
        }
    }

    private func recreateTunnelHandle() -> Bool {
        guard let tunnelConfigJson else { return false }

        if let handle = tunnelHandle {
            bh_wg_tunnel_free(handle)
            tunnelHandle = nil
        }

        tunnelHandle = tunnelConfigJson.withCString { ptr in
            bh_wg_tunnel_new(ptr)
        }
        return tunnelHandle != nil
    }

    private func configureDirectCandidates(config: TunnelConfig) {
        directCandidates = DirectCandidatePlanner.plan(
            configured: config.directCandidates ?? [],
            fallbackAddr: config.serverAddr,
            fallbackPort: config.serverPort
        )
        activeDirectCandidateIndex = 0
    }

    private func performNetcheckIfNeeded(config: TunnelConfig, completion: @escaping () -> Void) {
        guard let host = config.netcheckHost,
              !host.isEmpty,
              let port = config.netcheckPort,
              port > 0,
              let localPort = config.localPort,
              localPort > 0 else {
            completion()
            return
        }

        let endpoint = NWHostEndpoint(hostname: host, port: String(port))
        let localEndpoint = NWHostEndpoint(hostname: "0.0.0.0", port: String(localPort))
        let session = createUDPSession(to: endpoint, from: localEndpoint)
        netcheckSession?.cancel()
        netcheckSession = session

        let nonce = UUID().uuidString
        let payload = """
        {"type":"netcheck","nonce":"\(nonce)"}
        """
        var finished = false

        func finish() {
            if finished { return }
            finished = true
            self.netcheckSession?.cancel()
            self.netcheckSession = nil
            completion()
        }

        session.setReadHandler({ [weak self] datagrams, error in
            guard let self else {
                finish()
                return
            }
            if let error {
                os_log("UDP netcheck read error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                finish()
                return
            }
            guard let datagram = datagrams?.first,
                  let object = try? JSONSerialization.jsonObject(with: datagram) as? [String: Any],
                  let observedAddr = object["observedAddr"] as? String,
                  let observedPortNumber = object["observedPort"] as? NSNumber,
                  let responseNonce = object["nonce"] as? String,
                  responseNonce == nonce else {
                finish()
                return
            }

            let observedPort = UInt16(truncating: observedPortNumber)
            if !observedAddr.isEmpty, observedPort > 0 {
                self.observedCandidates = [
                    DirectCandidateConfig(
                        addr: observedAddr,
                        port: observedPort,
                        scope: "public_observed",
                        priority: 180,
                        source: "wormhole_netcheck"
                    ),
                ]
                self.applyRuntimeStatus(force: true)
                os_log(
                    "UDP netcheck observed %{public}@:%{public}d",
                    log: self.log,
                    type: .info,
                    observedAddr,
                    Int(observedPort)
                )
            }
            finish()
        }, maxDatagrams: 1)

        session.writeDatagram(payload.data(using: .utf8) ?? Data()) { [weak self] error in
            if let error {
                os_log("UDP netcheck send error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                finish()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                finish()
            }
        }
    }

    private func activateDirectCandidate(index: Int) {
        guard isRunning else { return }
        guard !directCandidates.isEmpty else { return }

        let boundedIndex = min(max(index, 0), directCandidates.count - 1)
        activeDirectCandidateIndex = boundedIndex
        let candidate = directCandidates[boundedIndex]
        let endpoint = NWHostEndpoint(hostname: candidate.addr, port: String(candidate.port))
        let localEndpoint = activeConfig?.localPort.map {
            NWHostEndpoint(hostname: "0.0.0.0", port: String($0))
        }
        udpSession?.cancel()
        directSessionStateObservation = nil
        directSessionViableObservation = nil
        directSessionStateDescription = nil
        directSessionIsViable = nil
        let generation = directDatapath.activateSession()
        tunnelDebugLog("activateDirectCandidate idx=\(boundedIndex) addr=\(candidate.addr):\(candidate.port) scope=\(candidate.scope) localPort=\(activeConfig?.localPort ?? 0) tunnelRemoteAddress=\(activeConfig?.serverAddr ?? "nil")")
        let session = createUDPSession(to: endpoint, from: localEndpoint)
        udpSession = session
        os_log(
            "Activating direct candidate %{public}d %{public}@:%{public}d scope=%{public}@ source=%{public}@ localPort=%{public}d",
            log: log,
            type: .info,
            boundedIndex,
            candidate.addr,
            candidate.port,
            candidate.scope,
            candidate.source,
            Int(activeConfig?.localPort ?? 0)
        )
        observeDirectSession(session, generation: generation)
        applyRuntimeStatus(force: true)
        startDirectPunchTimer(for: session)
        readPacketsFromUDP()
        sendInitialHandshake(preferDirectPath: true)
    }

    private func sendDirectPunchProbeBurst(on session: NWUDPSession?) {
        guard let session else { return }
        guard udpSession === session else { return }
        guard DirectSessionWritePolicy.shouldSendProbe(
            isSessionReady: directDatapath.isSessionReady,
            sessionState: directSessionStateDescription,
            sessionViable: directSessionIsViable
        ) else { return }
        let probe = Data([0])
        let delays: [TimeInterval] = [0, 0.25, 0.75]

        for delay in delays {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
                guard let self, self.isRunning, let session, self.udpSession === session else { return }
                self.directWriteAttempts &+= 1
                self.directProbeWriteAttempts &+= 1
                self.lastDirectWriteLabel = "Direct preflight probe"
                self.lastDirectWriteError = nil
                self.applyRuntimeStatus(force: true)
                session.writeDatagram(probe) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.directWriteErrors &+= 1
                        self.lastDirectWriteError = error.localizedDescription
                        os_log(
                            "Direct UDP preflight probe send error: %{public}@",
                            log: self.log,
                            type: .error,
                            error.localizedDescription
                        )
                        self.applyRuntimeStatus(force: true)
                    } else {
                        self.udpPacketsOut &+= 1
                        self.applyRuntimeStatus(force: true)
                    }
                }
            }
        }
    }

    private func startDirectPunchTimer(for session: NWUDPSession?) {
        stopDirectPunchTimer()
        guard let session else { return }

        let generation = directPunchAttempt.start()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak session] in
            guard let self = self, self.isRunning, let session else { return }
            guard self.udpSession === session else {
                self.stopDirectPunchTimer()
                return
            }
            guard TunnelRetryTimerPolicy.shouldKeepDirectPunchRunning(
                snapshot: self.runtime.snapshot
            ) else {
                self.stopDirectPunchTimer()
                return
            }
            guard self.directPunchAttempt.shouldSend(generation: generation) else {
                self.stopDirectPunchTimer()
                self.applyRuntimeStatus(force: true)
                return
            }
            self.sendDirectPunchProbeBurst(on: session)
        }
        directPunchTimer = timer
        timer.resume()
    }

    private func stopDirectPunchTimer() {
        directPunchAttempt.stop()
        directPunchTimer?.cancel()
        directPunchTimer = nil
    }

    private func sendDirectPacket(
        _ packet: Data,
        label: StaticString,
        kind: DirectDatapathPacketKind = .transport,
        surfaceStatusOnSuccess: Bool = false
    ) {
        let labelText = String(describing: label)
        let entry = DirectDatapathPacket(
            data: packet,
            label: labelText,
            kind: kind,
            surfaceStatusOnSuccess: surfaceStatusOnSuccess
        )

        guard let session = udpSession,
              DirectSessionWritePolicy.shouldWriteImmediately(
                  packetKind: kind,
                  isSessionReady: directDatapath.isSessionReady,
                  sessionState: directSessionStateDescription,
                  sessionViable: directSessionIsViable
              ) else {
            let droppedPacket = directDatapath.enqueue(entry)
            os_log(
                "%{public}@ queued until direct UDP session becomes ready",
                log: log,
                type: .info,
                labelText
            )
            if let droppedPacket {
                os_log(
                    "Dropping oldest queued direct packet %{public}@ to keep queue bounded",
                    log: log,
                    type: .info,
                    droppedPacket.label
                )
            }
            applyRuntimeStatus(force: true)
            return
        }
        writeDirectPacket(entry, on: session, sendContext: "direct send")
    }

    private func observeDirectSession(_ session: NWUDPSession, generation: UInt64) {
        directSessionStateObservation = session.observe(\.state, options: [.initial, .new]) { [weak self] observedSession, _ in
            guard let self else { return }
            guard self.udpSession === observedSession else { return }
            guard self.directDatapath.generation == generation else { return }
            self.handleDirectSessionStateChange(observedSession.state)
        }
        directSessionViableObservation = session.observe(\.isViable, options: [.initial, .new]) { [weak self] observedSession, _ in
            guard let self else { return }
            guard self.udpSession === observedSession else { return }
            guard self.directDatapath.generation == generation else { return }
            os_log(
                "Direct UDP session viability changed: %{public}@",
                log: self.log,
                type: .info,
                observedSession.isViable ? "viable" : "not_viable"
            )
            self.directSessionIsViable = observedSession.isViable
            self.applyRuntimeStatus(force: true)
        }
    }

    private func handleDirectSessionStateChange(_ state: NWUDPSessionState) {
        directSessionStateDescription = describeDirectSessionState(state)
        switch state {
        case .ready:
            let becameReady = !directDatapath.isSessionReady
            guard becameReady else { return }
            let queuedPackets = directDatapath.markReady()
            os_log("Direct UDP session became ready", log: log, type: .info)
            tunnelDebugLog("UDP session READY endpoint=\(udpSession?.endpoint.debugDescription ?? "nil") viable=\(udpSession?.isViable ?? false)")
            applyRuntimeStatus(force: true)
            flushPendingDirectPackets(queuedPackets)
            sendDirectPunchProbeBurst(on: udpSession)
        case .waiting:
            os_log("Direct UDP session waiting", log: log, type: .info)
            tunnelDebugLog("UDP session WAITING")
        case .preparing:
            os_log("Direct UDP session preparing", log: log, type: .info)
            tunnelDebugLog("UDP session PREPARING")
        case .failed:
            directDatapath.markNotReady()
            os_log("Direct UDP session failed", log: log, type: .error)
            tunnelDebugLog("UDP session FAILED endpoint=\(udpSession?.endpoint.debugDescription ?? "nil") resolvedEndpoint=\(udpSession?.resolvedEndpoint?.debugDescription ?? "nil") currentPath=\(udpSession?.currentPath?.debugDescription ?? "nil") hasBetterPath=\(udpSession?.hasBetterPath ?? false)")
            applyRuntimeStatus(force: true)
        case .cancelled:
            directDatapath.markNotReady()
            os_log("Direct UDP session cancelled", log: log, type: .info)
        case .invalid:
            directDatapath.markNotReady()
            os_log("Direct UDP session invalid", log: log, type: .error)
        @unknown default:
            directDatapath.markNotReady()
            os_log("Direct UDP session entered unknown state", log: log, type: .error)
        }
        applyRuntimeStatus(force: true)
    }

    private func flushPendingDirectPackets(_ queuedPackets: [DirectDatapathPacket]) {
        guard directDatapath.isSessionReady else { return }
        guard let session = udpSession else { return }
        for entry in queuedPackets {
            writeDirectPacket(entry, on: session, sendContext: "direct send after queue flush")
        }
    }

    private func writeDirectPacket(
        _ entry: DirectDatapathPacket,
        on session: NWUDPSession,
        sendContext: StaticString
    ) {
        directWriteAttempts &+= 1
        lastDirectWriteLabel = entry.label
        lastDirectWriteError = nil
        applyRuntimeStatus(force: true)
        session.writeDatagram(entry.data) { [weak self] error in
            if let error = error {
                self?.directWriteErrors &+= 1
                self?.lastDirectWriteError = error.localizedDescription
                os_log(
                    "%{public}@ %{public}@ error: %{public}@",
                    log: self?.log ?? .default,
                    type: .error,
                    entry.label,
                    String(describing: sendContext),
                    error.localizedDescription
                )
                self?.applyRuntimeStatus(force: true)
            } else {
                self?.udpPacketsOut &+= 1
                if entry.surfaceStatusOnSuccess {
                    self?.applyRuntimeStatus(force: true)
                }
            }
        }
    }

    private func describeDirectSessionState(_ state: NWUDPSessionState) -> String {
        switch state {
        case .invalid:
            return "invalid"
        case .waiting:
            return "waiting"
        case .preparing:
            return "preparing"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    private func sendEncryptedPacket(
        _ packet: Data,
        label: StaticString,
        preferDirectPath: Bool = false
    ) {
        let labelText = String(describing: label)
        if preferDirectPath, udpSession != nil {
            sendDirectPacket(packet, label: label)
            return
        }
        sendDirectPacket(packet, label: label)
    }

    private func describeWGResult(_ result: Int32) -> String {
        switch result {
        case BH_WG_DONE:
            return "done"
        case BH_WG_WRITE_TO_TUN:
            return "write_to_tun"
        case BH_WG_WRITE_TO_NET:
            return "write_to_net"
        default:
            return "unknown(\(result))"
        }
    }

    // MARK: - Helpers

    private func cidrToMask(_ prefix: Int) -> String {
        let mask = prefix > 0 ? ~UInt32(0) << (32 - prefix) : 0
        return "\(mask >> 24 & 0xFF).\(mask >> 16 & 0xFF).\(mask >> 8 & 0xFF).\(mask & 0xFF)"
    }

    private func parseCIDR(_ cidr: String) -> (String, String)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2 else { return nil }
        guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        return (String(parts[0]), cidrToMask(prefix))
    }
}
