import FlutterMacOS
import CryptoKit
import os.log

class VpnPlugin: NSObject, FlutterPlugin {
    private let log = OSLog(subsystem: "com.blackhole.voyager", category: "VPN")
    private var statusSink: FlutterEventSink?
    private var statusPollingTimer: DispatchSourceTimer?

    // Userspace WG tunnel state
    private var udpFd: Int32 = -1
    private var tunnelHandle: UnsafeMutableRawPointer?
    private var tunFd: Int32 = -1
    private var helperSocket: Int32 = -1
    private var isActive = false
    private var activeConfig: [String: Any]?
    private var tunPacketsOut: UInt64 = 0
    private var tunPacketsIn: UInt64 = 0
    private var udpPacketsOut: UInt64 = 0
    private var udpPacketsIn: UInt64 = 0
    private var timerSource: DispatchSourceTimer?
    private var tunReadThread: Thread?
    private var udpReadThread: Thread?
    private let wgQueue = DispatchQueue(label: "com.blackhole.voyager.macOS.wg")
    private let destLock = NSLock()
    private var peerSockaddr = sockaddr_in()
    private var hasPeer = false
    private var lastError: String?
    private var tunnelStartedAt: Date?
    private var netcheckNonce: String?
    private var observedCandidates: [[String: Any]] = []
    private let handshakeTotalBudget: TimeInterval = 30
    private let netcheckTimeout: TimeInterval = 1.2

    private var helperSocketPath: String {
        let home = NSHomeDirectory()
        return "\(home)/.blackhole/voyager/vpn-helper.sock"
    }

    private var helperBundlePath: String? {
        Bundle.main.path(forResource: "voyager-vpn-helper", ofType: nil)
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.blackhole.voyager/vpn", binaryMessenger: registrar.messenger)
        let instance = VpnPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        let eventChannel = FlutterEventChannel(name: "com.blackhole.voyager/vpn_status", binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
                return
            }
            DispatchQueue.global().async { self.startVpn(args: args, result: result) }
        case "stop":
            stopVpn(result: result)
        case "getStatus":
            result(currentStatusPayload())
        case "generateKeypair":
            generateKeypair(result: result)
        case "setActiveCandidate":
            setActiveCandidate(args: call.arguments, result: result)
        case "fail":
            failTunnel(args: call.arguments, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Start VPN

    private func startVpn(args: [String: Any], result: @escaping FlutterResult) {
        if isActive { stopTunnel() }
        lastError = nil

        guard let privateKey = args["privateKey"] as? String,
              let peerPublicKey = args["peerPublicKey"] as? String,
              let serverAddr = args["serverAddr"] as? String,
              let serverPort = args["serverPort"] as? Int else {
            failStart(code: "CONFIG", message: "Missing WG config fields", result: result)
            return
        }
        let clientIp = args["clientIp"] as? String ?? "10.13.37.2"
        let localPort = (args["localPort"] as? Int) ?? 0
        activeConfig = args
        tunPacketsOut = 0; tunPacketsIn = 0; udpPacketsOut = 0; udpPacketsIn = 0
        observedCandidates = []
        netcheckNonce = nil

        guard let configJson = try? JSONSerialization.data(withJSONObject: [
            "private_key": privateKey,
            "peer_public_key": peerPublicKey,
            "preshared_key": args["presharedKey"] as Any,
            "keepalive_secs": args["keepaliveSecs"] as Any,
        ]), let configStr = String(data: configJson, encoding: .utf8) else {
            failStart(code: "SERIALIZE", message: "Failed to serialize WG config", result: result)
            return
        }
        tunnelHandle = configStr.withCString { bh_wg_tunnel_new($0) }
        guard tunnelHandle != nil else {
            failStart(code: "WG_INIT", message: "Failed to create WG tunnel", result: result)
            return
        }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            failStart(code: "UDP", message: "socket() failed", result: result)
            return
        }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var nosig: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = UInt16(localPort).bigEndian
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindOk = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else {
            close(sock)
            failStart(code: "UDP", message: "bind() failed: \(errno)", result: result)
            return
        }
        udpFd = sock
        guard setPeer(addr: serverAddr, port: serverPort) else {
            failStart(code: "UDP", message: "Failed to resolve \(serverAddr):\(serverPort)", result: result)
            return
        }
        NSLog("[VpnPlugin] UDP bound localPort=\(localPort) dest=\(serverAddr):\(serverPort)")

        isActive = true
        startUDPReceive()
        performNetcheck(args: args)

        do {
            try ensureHelperRunning()
        } catch {
            failStart(code: "HELPER", message: error.localizedDescription, result: result)
            return
        }
        let hr = connectHelper(clientIp: clientIp)
        if let error = hr.error {
            failStart(code: "HELPER", message: error, result: result)
            return
        }
        guard let fd = hr.tunFd, fd >= 0 else {
            failStart(code: "TUN", message: "VPN helper did not return a TUN fd", result: result)
            return
        }
        tunFd = fd
        NSLog("[VpnPlugin] got TUN fd=\(fd)")
        startTUNReadLoop()
        tunnelStartedAt = Date()
        startTimerLoop()
        sendHandshakeInitiation()

        notifyStatusChange()
        DispatchQueue.main.async { result(nil) }
    }

    private func failStart(code: String, message: String, result: @escaping FlutterResult) {
        lastError = message
        stopTunnel()
        notifyStatusChange()
        DispatchQueue.main.async {
            result(FlutterError(code: code, message: message, details: nil))
        }
    }

    // MARK: - Helper management

    private func ensureHelperRunning() throws {
        if FileManager.default.fileExists(atPath: helperSocketPath) { return }

        guard let helperPath = helperBundlePath else {
            throw NSError(
                domain: "VpnPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "VPN helper binary not found in app bundle"]
            )
        }

        let dir = (helperSocketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let script = "do shell script \"\\\"\(helperPath)\\\" --socket \\\"\(helperSocketPath)\\\" --pid-file \\\"\(dir)/vpn-helper.pid\\\" &\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try proc.run()
        proc.waitUntilExit()
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: helperSocketPath) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NSError(
            domain: "VpnPlugin",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "VPN helper failed to start"]
        )
    }

    // MARK: - Helper communication (Unix socket + SCM_RIGHTS)

    private func connectHelper(clientIp: String) -> (tunFd: Int32?, error: String?) {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return (nil, "socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = helperSocketPath
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock); return (nil, "path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
            }
        }
        let connectOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectOk == 0 else {
            close(sock); return (nil, "connect to helper failed: errno=\(errno)")
        }

        let request = "{\"type\":\"start_vpn\",\"version\":1,\"server_ip\":\"\(clientIp)\",\"subnet\":\"10.13.37.0/24\",\"netmask\":\"255.255.255.0\",\"app_port\":9527}\n"
        request.withCString { ptr in _ = Darwin.write(sock, ptr, strlen(ptr)) }

        let controlSize = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 16
        var responseBuf = [UInt8](repeating: 0, count: 4096)
        let controlBuf = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { controlBuf.deallocate() }
        var iov = iovec(iov_base: &responseBuf, iov_len: responseBuf.count)
        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = controlBuf
        msg.msg_controllen = socklen_t(controlSize)

        let bytesRead = recvmsg(sock, &msg, 0)
        guard bytesRead > 0 else {
            close(sock); return (nil, "recvmsg failed: errno=\(errno)")
        }
        helperSocket = sock

        let responseStr = String(bytes: responseBuf.prefix(bytesRead), encoding: .utf8) ?? ""
        NSLog("[VpnPlugin] helper response: \(responseStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard responseStr.contains("\"started\"") else {
            return (nil, "helper error: \(responseStr)")
        }

        var receivedFd: Int32?
        if msg.msg_controllen > 0 {
            let cmsgPtr = controlBuf.assumingMemoryBound(to: cmsghdr.self)
            if cmsgPtr.pointee.cmsg_level == SOL_SOCKET && cmsgPtr.pointee.cmsg_type == SCM_RIGHTS {
                receivedFd = (controlBuf + MemoryLayout<cmsghdr>.size).load(as: Int32.self)
            }
        }
        guard let fd = receivedFd, fd >= 0 else {
            return (nil, "helper did not return a TUN fd")
        }
        return (fd, nil)
    }

    // MARK: - TUN read loop

    private func startTUNReadLoop() {
        guard tunFd >= 0 else { return }
        fcntl(tunFd, F_SETFL, fcntl(tunFd, F_GETFL) & ~O_NONBLOCK)
        let fd = tunFd
        tunReadThread = Thread { self.tunReadLoop(fd: fd) }
        tunReadThread?.name = "VpnPlugin.tunRead"
        tunReadThread?.start()
    }

    private func tunReadLoop(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048 + 4)
        while isActive && tunFd >= 0 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 4 {
                if !isActive { break }
                if n < 0 && errno == EAGAIN { Thread.sleep(forTimeInterval: 0.001) }
                continue
            }
            let ipStart = 4
            let ipLen = n - 4
            tunPacketsOut &+= 1
            guard let handle = tunnelHandle else { continue }
            var enc = [UInt8](repeating: 0, count: ipLen + 80)
            var encLen = enc.count
            let r = buf.withUnsafeBufferPointer { bufPtr -> Int32 in
                wgQueue.sync {
                    bh_wg_encapsulate(handle, bufPtr.baseAddress! + ipStart, ipLen, &enc, &encLen)
                }
            }
            if r == BH_WG_WRITE_TO_NET && encLen > 0 {
                sendUDP(enc, count: encLen)
            }
        }
    }

    // MARK: - UDP

    private func startUDPReceive() {
        guard udpFd >= 0 else { return }
        let fd = udpFd
        udpReadThread = Thread {
            var buf = [UInt8](repeating: 0, count: 2048)
            while self.isActive && self.udpFd >= 0 {
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &src) { srcPtr -> Int in
                    srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &srcLen)
                    }
                }
                if n <= 0 { continue }
                let datagram = Data(bytes: buf, count: n)
                if self.handleNetcheckResponse(datagram) { continue }
                self.udpPacketsIn &+= 1
                self.handleIncomingUDP(datagram)
            }
        }
        udpReadThread?.name = "VpnPlugin.udpRead"
        udpReadThread?.start()
    }

    private func handleIncomingUDP(_ datagram: Data) {
        guard let handle = tunnelHandle else { return }
        var dst = [UInt8](repeating: 0, count: datagram.count + 80)
        var dstLen = dst.count

        let r = datagram.withUnsafeBytes { srcPtr -> Int32 in
            wgQueue.sync {
                bh_wg_decapsulate(handle,
                    srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    srcPtr.count, &dst, &dstLen)
            }
        }

        if r == BH_WG_WRITE_TO_TUN && dstLen > 0 {
            tunPacketsIn &+= 1
            writeToTUN(dst, count: dstLen)
        } else if r == BH_WG_WRITE_TO_NET && dstLen > 0 {
            sendUDP(dst, count: dstLen)
            drainTunnel()
        }
        notifyStatusChange()
    }

    private func drainTunnel() {
        guard let handle = tunnelHandle else { return }
        var dst = [UInt8](repeating: 0, count: 2048)
        var dstLen = dst.count
        let r = wgQueue.sync { bh_wg_decapsulate(handle, nil, 0, &dst, &dstLen) }
        if r == BH_WG_WRITE_TO_TUN && dstLen > 0 {
            tunPacketsIn &+= 1
            writeToTUN(dst, count: dstLen)
            drainTunnel()
        } else if r == BH_WG_WRITE_TO_NET && dstLen > 0 {
            sendUDP(dst, count: dstLen)
            drainTunnel()
        }
    }

    /// Write raw IP packet to TUN fd, prepending 4-byte AF header.
    private func writeToTUN(_ packet: UnsafePointer<UInt8>, count: Int) {
        guard tunFd >= 0, count > 0 else { return }
        let version = packet[0] >> 4
        var af: UInt32 = (version == 6) ? UInt32(AF_INET6) : UInt32(AF_INET)
        var iov0 = iovec(iov_base: &af, iov_len: 4)
        var iov1 = iovec(iov_base: UnsafeMutableRawPointer(mutating: packet), iov_len: count)
        var iovecs = [iov0, iov1]
        _ = writev(tunFd, &iovecs, 2)
    }

    @discardableResult
    private func setPeer(addr: String, port: Int) -> Bool {
        guard let resolved = resolveIPv4(addr: addr, port: port) else { return false }
        destLock.lock()
        peerSockaddr = resolved
        hasPeer = true
        destLock.unlock()
        return true
    }

    private func resolveIPv4(addr: String, port: Int) -> sockaddr_in? {
        var saddr = sockaddr_in()
        saddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        saddr.sin_family = sa_family_t(AF_INET)
        saddr.sin_port = UInt16(port).bigEndian
        if inet_pton(AF_INET, addr, &saddr.sin_addr) == 1 {
            return saddr
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(addr, nil, &hints, &res) == 0, let info = res else {
            return nil
        }
        defer { freeaddrinfo(res) }
        guard let aiAddr = info.pointee.ai_addr else { return nil }
        aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
            saddr.sin_addr = ptr.pointee.sin_addr
        }
        return saddr
    }

    private func sendUDP(_ data: UnsafePointer<UInt8>, count: Int) {
        udpPacketsOut &+= 1
        guard udpFd >= 0 else { return }
        destLock.lock()
        var dest = peerSockaddr
        let ready = hasPeer
        destLock.unlock()
        guard ready else { return }
        _ = withUnsafePointer(to: &dest) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(udpFd, data, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func sendHandshakeInitiation() {
        guard let handle = tunnelHandle else { return }
        var dst = [UInt8](repeating: 0, count: 2048)
        var dstLen = dst.count
        let r = wgQueue.sync { bh_wg_force_handshake(handle, &dst, &dstLen) }
        if r == BH_WG_WRITE_TO_NET && dstLen > 0 { sendUDP(dst, count: dstLen) }
    }

    private func performNetcheck(args: [String: Any]) {
        guard let host = args["netcheckHost"] as? String, !host.isEmpty,
              let port = args["netcheckPort"] as? Int, port > 0 else {
            return
        }
        guard var dest = resolveIPv4(addr: host, port: port) else {
            NSLog("[VpnPlugin] netcheck resolve failed for \(host)")
            return
        }
        let nonce = UUID().uuidString
        netcheckNonce = nonce
        let payload = "{\"type\":\"netcheck\",\"nonce\":\"\(nonce)\"}"
        guard let data = payload.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            udpPacketsOut &+= 1
            _ = withUnsafePointer(to: &dest) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(udpFd, ptr, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let deadline = Date().addingTimeInterval(netcheckTimeout)
        while netcheckNonce != nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        netcheckNonce = nil
    }

    private func handleNetcheckResponse(_ datagram: Data) -> Bool {
        guard let nonce = netcheckNonce else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: datagram) as? [String: Any],
              object["nonce"] as? String == nonce,
              let observedAddr = object["observedAddr"] as? String else {
            return false
        }
        let observedPort: Int
        if let number = object["observedPort"] as? NSNumber {
            observedPort = number.intValue
        } else if let intPort = object["observedPort"] as? Int {
            observedPort = intPort
        } else {
            return true
        }
        if !observedAddr.isEmpty, observedPort > 0 {
            observedCandidates = [[
                "addr": observedAddr,
                "port": observedPort,
                "scope": "public_observed",
                "priority": 180,
                "source": "wormhole_netcheck",
            ]]
            notifyStatusChange()
        }
        netcheckNonce = nil
        return true
    }

    private func startTimerLoop() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive, let handle = self.tunnelHandle else { return }
            var dst = [UInt8](repeating: 0, count: 2048)
            var dstLen = dst.count
            let r = self.wgQueue.sync { bh_wg_update_timers(handle, &dst, &dstLen) }
            if r == BH_WG_WRITE_TO_NET && dstLen > 0 { self.sendUDP(dst, count: dstLen) }
            let stats = self.currentWireGuardStats()
            if stats.handshakeAgeSecs < 0,
               let startedAt = self.tunnelStartedAt,
               Date().timeIntervalSince(startedAt) >= self.handshakeTotalBudget {
                self.lastError = "WireGuard handshake timed out"
                self.stopTunnel()
            }
        }
        timer.resume()
        timerSource = timer
    }

    private func setActiveCandidate(args: Any?, result: @escaping FlutterResult) {
        guard let args = args as? [String: Any],
              let addr = args["addr"] as? String, !addr.isEmpty,
              let port = args["port"] as? Int, port > 0 else {
            result(FlutterError(code: "INVALID_ARGS", message: "setActiveCandidate requires addr and port", details: nil))
            return
        }
        guard tunnelHandle != nil else {
            result(FlutterError(code: "NO_VPN", message: "VPN is not running", details: nil))
            return
        }
        if currentWireGuardStats().handshakeAgeSecs >= 0 {
            result(nil)
            return
        }
        guard setPeer(addr: addr, port: port) else {
            result(FlutterError(code: "RESOLVE", message: "Failed to resolve \(addr)", details: nil))
            return
        }
        NSLog("[VpnPlugin] Active candidate set to \(addr):\(port)")
        sendHandshakeInitiation()
        notifyStatusChange()
        result(nil)
    }

    private func failTunnel(args: Any?, result: @escaping FlutterResult) {
        let message = (args as? [String: Any])?["error"] as? String ?? "WireGuard handshake timed out"
        lastError = message
        stopTunnel()
        result(nil)
    }

    // MARK: - Lifecycle

    private func stopTunnel() {
        isActive = false
        tunReadThread = nil; udpReadThread = nil
        timerSource?.cancel(); timerSource = nil
        if udpFd >= 0 { close(udpFd); udpFd = -1 }
        if tunFd >= 0 { close(tunFd); tunFd = -1 }
        if helperSocket >= 0 { close(helperSocket); helperSocket = -1 }
        if let h = tunnelHandle { bh_wg_tunnel_free(h); tunnelHandle = nil }
        destLock.lock(); hasPeer = false; destLock.unlock()
        netcheckNonce = nil
        notifyStatusChange()
    }

    private func stopVpn(result: @escaping FlutterResult) {
        lastError = nil
        stopTunnel()
        result(nil)
    }

    private struct WireGuardStats {
        var handshakeAgeSecs: Int64
        var txBytes: UInt64
        var rxBytes: UInt64
    }

    private func currentWireGuardStats() -> WireGuardStats {
        guard let h = tunnelHandle else {
            return WireGuardStats(handshakeAgeSecs: -1, txBytes: 0, rxBytes: 0)
        }
        var s = bh_wg_stats(
            time_since_last_handshake_secs: -1,
            tx_bytes: 0,
            rx_bytes: 0,
            estimated_loss: 0,
            estimated_rtt_ms: -1
        )
        guard withUnsafeMutablePointer(to: &s, { bh_wg_get_stats(h, $0) }) == 1 else {
            return WireGuardStats(handshakeAgeSecs: -1, txBytes: 0, rxBytes: 0)
        }
        return WireGuardStats(
            handshakeAgeSecs: s.time_since_last_handshake_secs,
            txBytes: s.tx_bytes,
            rxBytes: s.rx_bytes
        )
    }

    private func currentStatusPayload() -> [String: Any] {
        var r: [String: Any] = [:]
        let stats = currentWireGuardStats()
        let handshakeReady = stats.handshakeAgeSecs >= 0
        if let lastError, tunnelHandle == nil, !isActive {
            r["status"] = "error"
            r["connectionMode"] = "direct"
            r["error"] = lastError
        } else if isActive && handshakeReady {
            r["status"] = "connected"
            r["connectionMode"] = "direct"
        } else if isActive || tunnelHandle != nil {
            r["status"] = "connecting"
            r["connectionMode"] = "direct"
        } else {
            r["status"] = "disconnected"
            r["connectionMode"] = "unknown"
        }
        r["timestamp"] = ISO8601DateFormatter().string(from: Date())
        r["clientIp"] = activeConfig?["clientIp"] as? String
        r["serverIp"] = activeConfig?["serverIp"] as? String
        r["lanPort"] = activeConfig?["lanPort"] as? Int
        r["tunPacketsOut"] = Int64(tunPacketsOut)
        r["tunPacketsIn"] = Int64(tunPacketsIn)
        r["udpPacketsOut"] = Int64(udpPacketsOut)
        r["udpPacketsIn"] = Int64(udpPacketsIn)
        r["wgTxBytes"] = Int64(stats.txBytes)
        r["wgRxBytes"] = Int64(stats.rxBytes)
        r["timeSinceLastHandshakeSecs"] = stats.handshakeAgeSecs
        r["directSessionReady"] = handshakeReady
        if !observedCandidates.isEmpty {
            r["observedCandidates"] = observedCandidates
        }
        return r
    }

    private func generateKeypair(result: @escaping FlutterResult) {
        let pk = Curve25519.KeyAgreement.PrivateKey()
        result(["privateKey": pk.rawRepresentation.base64EncodedString(),
                "publicKey": pk.publicKey.rawRepresentation.base64EncodedString()])
    }

    private func notifyStatusChange() {
        DispatchQueue.main.async { [weak self] in self?.statusSink?(self?.currentStatusPayload()) }
    }
}

// MARK: - FlutterStreamHandler

extension VpnPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        statusSink = events
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.notifyStatusChange() }
        timer.resume()
        statusPollingTimer = timer
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        statusPollingTimer?.cancel(); statusPollingTimer = nil; statusSink = nil; return nil
    }
}
