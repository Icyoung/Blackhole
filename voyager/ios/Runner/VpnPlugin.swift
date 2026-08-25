import Flutter
import NetworkExtension
import CryptoKit
import os.log

private enum NativeVpnConfig {
    static let appGroup = "group.dev.icyou.blackhole.voyager"
    static let tunnelBundleIdentifier = "dev.icyou.blackhole.voyager.tunnel"
    static let statusNotification = "com.blackhole.voyager.vpn.status"
    static let statusDefaultsKey = "vpn_status_payload"
}

class VpnPlugin: NSObject, FlutterPlugin {

    private let log = OSLog(subsystem: "com.blackhole.voyager", category: "VPN")
    private var statusChannel: FlutterEventChannel?
    private var statusSink: FlutterEventSink?
    private var darwinObserver: CFNotificationCallback?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.blackhole.voyager/vpn", binaryMessenger: registrar.messenger())
        let instance = VpnPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Event channel for status updates
        let eventChannel = FlutterEventChannel(name: "com.blackhole.voyager/vpn_status", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        instance.statusChannel = eventChannel
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
                return
            }
            startVpn(args: args, result: result)

        case "stop":
            stopVpn(result: result)

        case "getStatus":
            getStatus(result: result)

        case "generateKeypair":
            generateKeypair(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startVpn(args: [String: Any], result: @escaping FlutterResult) {
        // Write config to App Group container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeVpnConfig.appGroup
        ) else {
            result(FlutterError(code: "NO_GROUP", message: "App Group not available", details: nil))
            return
        }

        let configURL = containerURL.appendingPathComponent("vpn_config.json")
        guard let configData = try? JSONSerialization.data(withJSONObject: args) else {
            result(FlutterError(code: "SERIALIZE", message: "Failed to serialize config", details: nil))
            return
        }

        do {
            try configData.write(to: configURL, options: .atomic)
        } catch {
            result(FlutterError(code: "WRITE", message: "Failed to write config: \(error)", details: nil))
            return
        }

        persistStatusSnapshot(
            status: "connecting",
            serverIp: args["serverIp"] as? String,
            clientIp: args["clientIp"] as? String,
            lanPort: uint16Value(args["lanPort"]),
            connectionMode: nil,
            error: nil
        )

        // Load/create NETunnelProviderManager
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                result(FlutterError(code: "LOAD", message: "Failed to load VPN: \(error)", details: nil))
                return
            }

            let manager = self.selectManager(from: managers) ?? NETunnelProviderManager()
            self.configure(manager: manager, args: args)
            self.saveAndStart(
                manager: manager,
                args: args,
                retryOnStaleSave: true,
                result: result
            )
        }
    }

    private func stopVpn(result: @escaping FlutterResult) {
        persistStatusSnapshot(
            status: "disconnecting",
            serverIp: nil,
            clientIp: nil,
            lanPort: nil,
            connectionMode: nil,
            error: nil
        )
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                result(FlutterError(code: "LOAD", message: error.localizedDescription, details: nil))
                return
            }

            self.selectManager(from: managers)?.connection.stopVPNTunnel()
            result(nil)
        }
    }

    private func getStatus(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let manager = self.selectManager(from: managers)
            if #available(iOS 16.0, *), let connection = manager?.connection {
                connection.fetchLastDisconnectError { error in
                    result(self.mergedStatusPayload(managers: managers, disconnectError: error))
                }
            } else {
                result(self.mergedStatusPayload(managers: managers, disconnectError: nil))
            }
        }
    }

    private func generateKeypair(result: @escaping FlutterResult) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        let privKeyBase64 = privateKey.rawRepresentation.base64EncodedString()
        let pubKeyBase64 = publicKey.rawRepresentation.base64EncodedString()

        result([
            "privateKey": privKeyBase64,
            "publicKey": pubKeyBase64,
        ])
    }

    private func selectManager(from managers: [NETunnelProviderManager]?) -> NETunnelProviderManager? {
        managers?.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ==
                NativeVpnConfig.tunnelBundleIdentifier
        }) ?? managers?.first
    }

    private func configure(manager: NETunnelProviderManager, args: [String: Any]) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = NativeVpnConfig.tunnelBundleIdentifier
        proto.serverAddress = args["serverAddr"] as? String ?? "Horizon"
        proto.providerConfiguration = propertyListDictionary(from: args)
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Blackhole VPN"
        manager.isEnabled = true
    }

    private func saveAndStart(
        manager: NETunnelProviderManager,
        args: [String: Any],
        retryOnStaleSave: Bool,
        result: @escaping FlutterResult
    ) {
        manager.saveToPreferences { error in
            if let nsError = error as NSError? {
                let isStale =
                    nsError.domain == NEVPNErrorDomain &&
                    nsError.code == NEVPNError.configurationStale.rawValue
                guard retryOnStaleSave && isStale else {
                    result(
                        FlutterError(
                            code: "SAVE",
                            message: "Failed to save VPN: \(nsError)",
                            details: nil
                        )
                    )
                    return
                }

                NETunnelProviderManager.loadAllFromPreferences { managers, reloadError in
                    if let reloadError = reloadError {
                        result(
                            FlutterError(
                                code: "RELOAD",
                                message: "Failed to reload stale VPN configuration: \(reloadError)",
                                details: nil
                            )
                        )
                        return
                    }

                    let refreshedManager = self.selectManager(from: managers) ?? NETunnelProviderManager()
                    self.configure(manager: refreshedManager, args: args)
                    self.saveAndStart(
                        manager: refreshedManager,
                        args: args,
                        retryOnStaleSave: false,
                        result: result
                    )
                }
                return
            }

            // Reload from preferences and start using the fresh manager instance.
            NETunnelProviderManager.loadAllFromPreferences { refreshedManagers, error in
                if let error = error {
                    result(FlutterError(code: "RELOAD", message: "Failed to reload VPN: \(error)", details: nil))
                    return
                }

                let refreshedManager = self.selectManager(from: refreshedManagers) ?? manager
                self.startTunnel(using: refreshedManager, args: args, retryOnStale: true, result: result)
            }
        }
    }

    private func startTunnel(
        using manager: NETunnelProviderManager,
        args: [String: Any],
        retryOnStale: Bool,
        result: @escaping FlutterResult
    ) {
        do {
            try manager.connection.startVPNTunnel(options: tunnelOptions(from: args))
            result(nil)
        } catch let nsError as NSError {
            let isStale =
                nsError.domain == NEVPNErrorDomain &&
                nsError.code == NEVPNError.configurationStale.rawValue
            guard retryOnStale && isStale else {
                result(
                    FlutterError(
                        code: "START",
                        message: "Failed to start VPN: \(nsError)",
                        details: nil
                    )
                )
                return
            }

            manager.loadFromPreferences { error in
                if let error = error {
                    result(
                        FlutterError(
                            code: "RELOAD",
                            message: "Failed to reload stale VPN configuration: \(error)",
                            details: nil
                        )
                    )
                    return
                }

                self.startTunnel(using: manager, args: args, retryOnStale: false, result: result)
            }
        } catch {
            result(FlutterError(code: "START", message: "Failed to start VPN: \(error)", details: nil))
        }
    }

    private func tunnelOptions(from args: [String: Any]) -> [String: NSObject] {
        propertyListDictionary(from: args)
    }

    private func propertyListDictionary(from args: [String: Any]) -> [String: NSObject] {
        var normalized: [String: NSObject] = [:]
        for (key, value) in args {
            guard let object = propertyListObject(from: value) else {
                continue
            }
            normalized[key] = object
        }
        return normalized
    }

    private func propertyListObject(from value: Any) -> NSObject? {
        switch value {
        case let object as NSString:
            return object
        case let object as NSNumber:
            return object
        case let string as String:
            return string as NSString
        case let int as Int:
            return NSNumber(value: int)
        case let int8 as Int8:
            return NSNumber(value: int8)
        case let int16 as Int16:
            return NSNumber(value: int16)
        case let int32 as Int32:
            return NSNumber(value: int32)
        case let int64 as Int64:
            return NSNumber(value: int64)
        case let uint as UInt:
            return NSNumber(value: uint)
        case let uint8 as UInt8:
            return NSNumber(value: uint8)
        case let uint16 as UInt16:
            return NSNumber(value: uint16)
        case let uint32 as UInt32:
            return NSNumber(value: uint32)
        case let uint64 as UInt64:
            return NSNumber(value: uint64)
        case let double as Double:
            return NSNumber(value: double)
        case let float as Float:
            return NSNumber(value: float)
        case let bool as Bool:
            return NSNumber(value: bool)
        case let array as [Any]:
            var normalized: [NSObject] = []
            normalized.reserveCapacity(array.count)
            for item in array {
                guard let object = propertyListObject(from: item) else {
                    return nil
                }
                normalized.append(object)
            }
            return normalized as NSArray
        case let dictionary as [String: Any]:
            var normalized: [String: NSObject] = [:]
            normalized.reserveCapacity(dictionary.count)
            for (key, item) in dictionary {
                guard let object = propertyListObject(from: item) else {
                    return nil
                }
                normalized[key] = object
            }
            return normalized as NSDictionary
        default:
            return nil
        }
    }

    private func uint16Value(_ value: Any?) -> UInt16? {
        switch value {
        case let number as NSNumber:
            return UInt16(truncating: number)
        case let int as Int:
            return UInt16(clamping: int)
        default:
            return nil
        }
    }

    private func persistStatusSnapshot(
        status: String,
        serverIp: String?,
        clientIp: String?,
        lanPort: UInt16?,
        connectionMode: String?,
        error: String?
    ) {
        var payload: [String: Any] = [
            "status": status,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let clientIp {
            payload["clientIp"] = clientIp
        }
        if let serverIp {
            payload["serverIp"] = serverIp
        }
        if let lanPort {
            payload["lanPort"] = Int(lanPort)
        }
        if let connectionMode {
            payload["connectionMode"] = connectionMode
        }
        if let error {
            payload["error"] = error
        }
        guard let statusData = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        if let defaults = UserDefaults(suiteName: NativeVpnConfig.appGroup) {
            defaults.set(statusData, forKey: NativeVpnConfig.statusDefaultsKey)
            defaults.synchronize()
        }
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeVpnConfig.appGroup
        ) {
            let statusURL = containerURL.appendingPathComponent("vpn_status.json")
            try? statusData.write(to: statusURL, options: .atomic)
        }
    }

    private func mergedStatusPayload(
        managers: [NETunnelProviderManager]?,
        disconnectError: Error?
    ) -> [String: Any] {
        let manager = selectManager(from: managers)
        let managerStatus: String
        switch manager?.connection.status {
        case .connected: managerStatus = "connected"
        case .connecting: managerStatus = "connecting"
        case .disconnecting: managerStatus = "disconnecting"
        case .reasserting: managerStatus = "connecting"
        default: managerStatus = "disconnected"
        }

        var response: [String: Any] = ["status": managerStatus]
        if let providerConfig = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
            if let clientIp = providerConfig["clientIp"] as? String { response["clientIp"] = clientIp }
            if let serverIp = providerConfig["serverIp"] as? String { response["serverIp"] = serverIp }
            if let lanPort = providerConfig["lanPort"] as? NSNumber {
                response["lanPort"] = lanPort.intValue
            } else if let lanPort = providerConfig["lanPort"] as? Int {
                response["lanPort"] = lanPort
            }
        }
        let shouldTrustPersistedConnectedState = managerStatus != "disconnected"

        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NativeVpnConfig.appGroup
        ) {
            let statusURL = containerURL.appendingPathComponent("vpn_status.json")
            if let data = try? Data(contentsOf: statusURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let status = json["status"] as? String,
                   shouldTrustPersistedConnectedState || status == "disconnected" || status == "error" {
                    response["status"] = status
                }
                if let clientIp = json["clientIp"] as? String { response["clientIp"] = clientIp }
                if let serverIp = json["serverIp"] as? String { response["serverIp"] = serverIp }
                if let lanPort = json["lanPort"] as? NSNumber {
                    response["lanPort"] = lanPort.intValue
                } else if let lanPort = json["lanPort"] as? Int {
                    response["lanPort"] = lanPort
                }
                if let tunPacketsOut = json["tunPacketsOut"] as? NSNumber { response["tunPacketsOut"] = tunPacketsOut.int64Value }
                if let tunPacketsIn = json["tunPacketsIn"] as? NSNumber { response["tunPacketsIn"] = tunPacketsIn.int64Value }

                if let udpPacketsOut = json["udpPacketsOut"] as? NSNumber { response["udpPacketsOut"] = udpPacketsOut.int64Value }
                if let udpPacketsIn = json["udpPacketsIn"] as? NSNumber { response["udpPacketsIn"] = udpPacketsIn.int64Value }
                if let wgTxBytes = json["wgTxBytes"] as? NSNumber { response["wgTxBytes"] = wgTxBytes.int64Value }
                if let wgRxBytes = json["wgRxBytes"] as? NSNumber { response["wgRxBytes"] = wgRxBytes.int64Value }
                if let handshakeAge = json["timeSinceLastHandshakeSecs"] as? NSNumber {
                    response["timeSinceLastHandshakeSecs"] = handshakeAge.int64Value
                }
                if let plannedDirectCandidates = json["plannedDirectCandidates"] as? [Any] { response["plannedDirectCandidates"] = plannedDirectCandidates }
                if let observedCandidates = json["observedCandidates"] as? [Any] { response["observedCandidates"] = observedCandidates }
                if let activeDirectCandidateIndex = json["activeDirectCandidateIndex"] as? NSNumber { response["activeDirectCandidateIndex"] = activeDirectCandidateIndex.intValue }
                if let activeDirectCandidate = json["activeDirectCandidate"] as? [String: Any] { response["activeDirectCandidate"] = activeDirectCandidate }
                if let directSessionState = json["directSessionState"] as? String { response["directSessionState"] = directSessionState }
                if let directSessionViable = json["directSessionViable"] as? Bool { response["directSessionViable"] = directSessionViable }
                if let directSessionReady = json["directSessionReady"] as? Bool { response["directSessionReady"] = directSessionReady }
                if let pendingDirectQueueDepth = json["pendingDirectQueueDepth"] as? NSNumber { response["pendingDirectQueueDepth"] = pendingDirectQueueDepth.intValue }
                if let directWriteAttempts = json["directWriteAttempts"] as? NSNumber { response["directWriteAttempts"] = directWriteAttempts.int64Value }
                if let directWriteErrors = json["directWriteErrors"] as? NSNumber { response["directWriteErrors"] = directWriteErrors.int64Value }
                if let directHandshakePacketsPrepared = json["directHandshakePacketsPrepared"] as? NSNumber { response["directHandshakePacketsPrepared"] = directHandshakePacketsPrepared.int64Value }
                if let directHandshakePacketsSuppressed = json["directHandshakePacketsSuppressed"] as? NSNumber { response["directHandshakePacketsSuppressed"] = directHandshakePacketsSuppressed.int64Value }
                if let directProbeWriteAttempts = json["directProbeWriteAttempts"] as? NSNumber { response["directProbeWriteAttempts"] = directProbeWriteAttempts.int64Value }
                if let lastDirectWriteLabel = json["lastDirectWriteLabel"] as? String { response["lastDirectWriteLabel"] = lastDirectWriteLabel }
                if let lastDirectWriteError = json["lastDirectWriteError"] as? String { response["lastDirectWriteError"] = lastDirectWriteError }
                if shouldTrustPersistedConnectedState, let mode = json["connectionMode"] as? String { response["connectionMode"] = mode }
                if let error = json["error"] as? String { response["error"] = error }
            }
        }

        if let defaults = UserDefaults(suiteName: NativeVpnConfig.appGroup),
           let data = defaults.data(forKey: NativeVpnConfig.statusDefaultsKey),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let status = json["status"] as? String,
               shouldTrustPersistedConnectedState || status == "disconnected" || status == "error" {
                response["status"] = status
            }
            if let clientIp = json["clientIp"] as? String { response["clientIp"] = clientIp }
            if let serverIp = json["serverIp"] as? String { response["serverIp"] = serverIp }
            if let lanPort = json["lanPort"] as? NSNumber {
                response["lanPort"] = lanPort.intValue
            } else if let lanPort = json["lanPort"] as? Int {
                response["lanPort"] = lanPort
            }
            if let tunPacketsOut = json["tunPacketsOut"] as? NSNumber { response["tunPacketsOut"] = tunPacketsOut.int64Value }
            if let tunPacketsIn = json["tunPacketsIn"] as? NSNumber { response["tunPacketsIn"] = tunPacketsIn.int64Value }
            if let udpPacketsOut = json["udpPacketsOut"] as? NSNumber { response["udpPacketsOut"] = udpPacketsOut.int64Value }
            if let udpPacketsIn = json["udpPacketsIn"] as? NSNumber { response["udpPacketsIn"] = udpPacketsIn.int64Value }
            if let wgTxBytes = json["wgTxBytes"] as? NSNumber { response["wgTxBytes"] = wgTxBytes.int64Value }
            if let wgRxBytes = json["wgRxBytes"] as? NSNumber { response["wgRxBytes"] = wgRxBytes.int64Value }
            if let handshakeAge = json["timeSinceLastHandshakeSecs"] as? NSNumber {
                response["timeSinceLastHandshakeSecs"] = handshakeAge.int64Value
            }
            if let plannedDirectCandidates = json["plannedDirectCandidates"] as? [Any] { response["plannedDirectCandidates"] = plannedDirectCandidates }
            if let observedCandidates = json["observedCandidates"] as? [Any] { response["observedCandidates"] = observedCandidates }
            if let activeDirectCandidateIndex = json["activeDirectCandidateIndex"] as? NSNumber { response["activeDirectCandidateIndex"] = activeDirectCandidateIndex.intValue }
            if let activeDirectCandidate = json["activeDirectCandidate"] as? [String: Any] { response["activeDirectCandidate"] = activeDirectCandidate }
            if let directSessionState = json["directSessionState"] as? String { response["directSessionState"] = directSessionState }
            if let directSessionViable = json["directSessionViable"] as? Bool { response["directSessionViable"] = directSessionViable }
            if let directSessionReady = json["directSessionReady"] as? Bool { response["directSessionReady"] = directSessionReady }
            if let pendingDirectQueueDepth = json["pendingDirectQueueDepth"] as? NSNumber { response["pendingDirectQueueDepth"] = pendingDirectQueueDepth.intValue }
            if let directWriteAttempts = json["directWriteAttempts"] as? NSNumber { response["directWriteAttempts"] = directWriteAttempts.int64Value }
            if let directWriteErrors = json["directWriteErrors"] as? NSNumber { response["directWriteErrors"] = directWriteErrors.int64Value }
            if let directHandshakePacketsPrepared = json["directHandshakePacketsPrepared"] as? NSNumber { response["directHandshakePacketsPrepared"] = directHandshakePacketsPrepared.int64Value }
            if let directHandshakePacketsSuppressed = json["directHandshakePacketsSuppressed"] as? NSNumber { response["directHandshakePacketsSuppressed"] = directHandshakePacketsSuppressed.int64Value }
            if let directProbeWriteAttempts = json["directProbeWriteAttempts"] as? NSNumber { response["directProbeWriteAttempts"] = directProbeWriteAttempts.int64Value }
            if let lastDirectWriteLabel = json["lastDirectWriteLabel"] as? String { response["lastDirectWriteLabel"] = lastDirectWriteLabel }
            if let lastDirectWriteError = json["lastDirectWriteError"] as? String { response["lastDirectWriteError"] = lastDirectWriteError }
            if shouldTrustPersistedConnectedState, let mode = json["connectionMode"] as? String { response["connectionMode"] = mode }
            if let error = json["error"] as? String { response["error"] = error }
        }

        if !shouldTrustPersistedConnectedState {
            response["connectionMode"] = "unknown"
        }

        if response["error"] == nil, let disconnectError {
            response["error"] = disconnectError.localizedDescription
        }

        return response
    }
}

// MARK: - FlutterStreamHandler

extension VpnPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        statusSink = events

        // Listen for Darwin notifications from the NE
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let plugin = Unmanaged<VpnPlugin>.fromOpaque(observer).takeUnretainedValue()
            plugin.notifyStatusChange()
        }, NativeVpnConfig.statusNotification as CFString, nil, .deliverImmediately)

        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        statusSink = nil
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(NativeVpnConfig.statusNotification as CFString), nil)
        return nil
    }

    private func notifyStatusChange() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            let manager = self?.selectManager(from: managers)
            if #available(iOS 16.0, *), let connection = manager?.connection {
                connection.fetchLastDisconnectError { error in
                    let payload = self?.mergedStatusPayload(managers: managers, disconnectError: error) ?? ["status": "disconnected"]
                    DispatchQueue.main.async {
                        self?.statusSink?(payload)
                    }
                }
            } else {
                let payload = self?.mergedStatusPayload(managers: managers, disconnectError: nil) ?? ["status": "disconnected"]
                DispatchQueue.main.async {
                    self?.statusSink?(payload)
                }
            }
        }
    }
}
