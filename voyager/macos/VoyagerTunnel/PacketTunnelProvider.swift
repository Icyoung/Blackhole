import NetworkExtension
import os.log

private enum NativeTunnelConfig {
    static let appGroup = "group.dev.icyou.blackhole.voyager"
    static let statusNotification = "com.blackhole.voyager.vpn.status"
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.blackhole.voyager.tunnel", category: "PacketTunnel")

    private var tunnelHandle: UnsafeMutableRawPointer?
    private var udpSession: NWUDPSession?
    private var isRunning = false
    private var activeConfig: TunnelConfig?
    private let wgQueue = DispatchQueue(label: "com.blackhole.voyager.tunnel.wg")
    private var tunPacketsOut: UInt64 = 0
    private var tunPacketsIn: UInt64 = 0
    private var udpPacketsOut: UInt64 = 0
    private var udpPacketsIn: UInt64 = 0
    private var statusTimer: DispatchSourceTimer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel", log: log, type: .info)

        // Read config from App Group shared container
        guard let config = loadConfig() else {
            completionHandler(NSError(domain: "VoyagerTunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No VPN configuration found"]))
            return
        }
        activeConfig = config
        tunPacketsOut = 0
        tunPacketsIn = 0
        udpPacketsOut = 0
        udpPacketsIn = 0

        // Initialize blackhole_wg tunnel
        guard let configJson = try? JSONSerialization.data(withJSONObject: [
            "private_key": config.privateKey,
            "peer_public_key": config.peerPublicKey,
            "preshared_key": config.presharedKey as Any,
            "keepalive_secs": config.keepaliveSecs as Any,
        ]) else {
            completionHandler(NSError(domain: "VoyagerTunnel", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to serialize config"]))
            return
        }

        let configStr = String(data: configJson, encoding: .utf8)!
        tunnelHandle = configStr.withCString { ptr in
            bh_wg_tunnel_new(ptr)
        }

        guard tunnelHandle != nil else {
            completionHandler(NSError(domain: "VoyagerTunnel", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create WG tunnel"]))
            return
        }

        // Configure network settings
        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.serverAddr)

        let ipv4Settings = NEIPv4Settings(addresses: [config.clientIp], subnetMasks: ["255.255.255.0"])

        // Split tunnel: only route internal networks through VPN
        var includedRoutes: [NEIPv4Route] = []
        for route in config.internalRoutes {
            let parts = route.split(separator: "/")
            if parts.count == 2 {
                let mask = cidrToMask(Int(parts[1]) ?? 24)
                includedRoutes.append(NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: mask))
            }
        }
        // Always include the VPN subnet
        includedRoutes.append(NEIPv4Route(destinationAddress: "10.13.37.0", subnetMask: "255.255.255.0"))
        ipv4Settings.includedRoutes = includedRoutes

        tunnelSettings.ipv4Settings = ipv4Settings
        tunnelSettings.mtu = NSNumber(value: config.mtu)

        // DNS settings
        let dnsSettings = NEDNSSettings(servers: config.dns)
        dnsSettings.matchDomains = config.dnsMatchDomains.isEmpty ? [""] : config.dnsMatchDomains
        tunnelSettings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(tunnelSettings) { [weak self] error in
            if let error = error {
                os_log("Failed to set tunnel settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }

            self?.isRunning = true
            self?.startPacketLoop(config: config)
            self?.updateStatus(.connected)
            self?.startStatusTimer()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping tunnel: %{public}@", log: log, type: .info, String(describing: reason))
        isRunning = false
        stopStatusTimer()

        udpSession?.cancel()
        udpSession = nil

        if let handle = tunnelHandle {
            bh_wg_tunnel_free(handle)
            tunnelHandle = nil
        }

        updateStatus(.disconnected)
        activeConfig = nil
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
        // Create UDP session to Horizon
        let endpoint = NWHostEndpoint(hostname: config.serverAddr, port: String(config.serverPort))
        udpSession = createUDPSession(to: endpoint, from: nil)

        // Read packets from TUN and encapsulate
        readPacketsFromTUN()

        // Read packets from UDP and decapsulate
        readPacketsFromUDP()

        // Start timer for WG keepalives
        startTimerLoop()
    }

    private func readPacketsFromTUN() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            for (i, packet) in packets.enumerated() {
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
            tunPacketsOut &+= 1
            udpPacketsOut &+= 1
            udpSession?.writeDatagram(dst.prefix(dstLen)) { error in
                if let error = error {
                    os_log("UDP send error: %{public}@", type: .error, error.localizedDescription)
                }
            }
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
                self.decapsulateAndInject(datagram: datagram)
            }
        }, maxDatagrams: 64)
    }

    private func decapsulateAndInject(datagram: Data) {
        guard let handle = tunnelHandle else { return }
        udpPacketsIn &+= 1

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

        if result == BH_WG_WRITE_TO_TUN {
            tunPacketsIn &+= 1
            let ipPacket = dst.prefix(dstLen)
            // Determine IP version from first nibble
            let version: NSNumber = ipPacket.first.map { ($0 >> 4) == 6 ? 10 : 2 } ?? 2 // AF_INET6 : AF_INET
            packetFlow.writePackets([ipPacket], withProtocols: [version])
        } else if result == BH_WG_WRITE_TO_NET {
            // Handshake response — send back over UDP
            let response = dst.prefix(dstLen)
            udpSession?.writeDatagram(response) { _ in }

            // Drain any buffered packets
            drainTunnel()
        }
    }

    private func drainTunnel() {
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
            packetFlow.writePackets([ipPacket], withProtocols: [version])
            drainTunnel() // Continue draining
        } else if result == BH_WG_WRITE_TO_NET && dstLen > 0 {
            udpSession?.writeDatagram(dst.prefix(dstLen)) { _ in }
            drainTunnel()
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
                self.udpSession?.writeDatagram(dst.prefix(dstLen)) { _ in }
            }

            self.startTimerLoop()
        }
    }

    // MARK: - Config & Status

    private func loadConfig() -> TunnelConfig? {
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

    private func updateStatus(_ status: TunnelStatus) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeTunnelConfig.appGroup
        ) else { return }

        // Fetch WG stats
        var wgTxBytes: UInt64?
        var wgRxBytes: UInt64?
        if let handle = tunnelHandle {
            var stats = bh_wg_stats(
                time_since_last_handshake_secs: -1,
                tx_bytes: 0,
                rx_bytes: 0,
                estimated_loss: 0,
                estimated_rtt_ms: -1
            )
            if withUnsafeMutablePointer(to: &stats, { bh_wg_get_stats(handle, $0) }) == 1 {
                wgTxBytes = stats.tx_bytes
                wgRxBytes = stats.rx_bytes
            }
        }

        let statusURL = containerURL.appendingPathComponent("vpn_status.json")
        let info = TunnelStatusInfo(
            status: status,
            timestamp: Date(),
            clientIp: activeConfig?.clientIp,
            serverIp: activeConfig?.serverIp,
            connectionMode: activeConfig == nil ? nil : "direct",
            tunPacketsOut: tunPacketsOut,
            tunPacketsIn: tunPacketsIn,
            udpPacketsOut: udpPacketsOut,
            udpPacketsIn: udpPacketsIn,
            wgTxBytes: wgTxBytes,
            wgRxBytes: wgRxBytes
        )
        let statusData = try? JSONEncoder().encode(info)
        try? statusData?.write(to: statusURL, options: .atomic)

        // Post Darwin notification for status change
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(NativeTunnelConfig.statusNotification as CFString), nil, nil, true)
    }

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.updateStatus(.connected)
        }
        timer.resume()
        statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    // MARK: - Helpers

    private func cidrToMask(_ prefix: Int) -> String {
        let mask = prefix > 0 ? ~UInt32(0) << (32 - prefix) : 0
        return "\(mask >> 24 & 0xFF).\(mask >> 16 & 0xFF).\(mask >> 8 & 0xFF).\(mask & 0xFF)"
    }
}
