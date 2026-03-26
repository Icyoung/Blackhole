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
    private var helperProcess: Process?
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Start VPN

    private func startVpn(args: [String: Any], result: @escaping FlutterResult) {
        if isActive { stopTunnel() }

        guard let privateKey = args["privateKey"] as? String,
              let peerPublicKey = args["peerPublicKey"] as? String,
              let serverAddr = args["serverAddr"] as? String,
              let serverPort = args["serverPort"] as? Int else {
            DispatchQueue.main.async {
                result(FlutterError(code: "CONFIG", message: "Missing WG config fields", details: nil))
            }
            return
        }
        let clientIp = args["clientIp"] as? String ?? "10.13.37.2"
        activeConfig = args
        tunPacketsOut = 0; tunPacketsIn = 0; udpPacketsOut = 0; udpPacketsIn = 0

        // 1. Create WG tunnel handle
        guard let configJson = try? JSONSerialization.data(withJSONObject: [
            "private_key": privateKey,
            "peer_public_key": peerPublicKey,
            "preshared_key": args["presharedKey"] as Any,
            "keepalive_secs": args["keepaliveSecs"] as Any,
        ]), let configStr = String(data: configJson, encoding: .utf8) else {
            DispatchQueue.main.async {
                result(FlutterError(code: "SERIALIZE", message: "Failed to serialize WG config", details: nil))
            }
            return
        }
        tunnelHandle = configStr.withCString { bh_wg_tunnel_new($0) }
        guard tunnelHandle != nil else {
            DispatchQueue.main.async {
                result(FlutterError(code: "WG_INIT", message: "Failed to create WG tunnel", details: nil))
            }
            return
        }

        // 2. Create POSIX UDP socket
        NSLog("[VpnPlugin] connecting UDP to \(serverAddr):\(serverPort)")
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            DispatchQueue.main.async {
                result(FlutterError(code: "UDP", message: "socket() failed", details: nil))
            }
            return
        }
        var saddr = sockaddr_in()
        saddr.sin_family = sa_family_t(AF_INET)
        saddr.sin_port = UInt16(serverPort).bigEndian
        inet_pton(AF_INET, serverAddr, &saddr.sin_addr)
        let ok = withUnsafePointer(to: &saddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            close(sock)
            DispatchQueue.main.async {
                result(FlutterError(code: "UDP", message: "connect() failed: \(errno)", details: nil))
            }
            return
        }
        udpFd = sock
        isActive = true
        NSLog("[VpnPlugin] UDP connected fd=\(sock)")

        // 3. Start UDP receive + WG timer + handshake
        startUDPReceive()
        startTimerLoop()
        sendHandshakeInitiation()

        // 4. Launch helper and get TUN (async, non-blocking)
        ensureHelperRunning()
        let hr = connectHelper(clientIp: clientIp)
        if let error = hr.error {
            NSLog("[VpnPlugin] helper: \(error) — continuing without TUN")
        } else if let fd = hr.tunFd {
            tunFd = fd
            NSLog("[VpnPlugin] got TUN fd=\(fd)")
            startTUNReadLoop()
        }

        notifyStatusChange()
        DispatchQueue.main.async { result(nil) }
    }

    // MARK: - Helper management

    private func ensureHelperRunning() {
        // Check if socket already exists (helper already running)
        if FileManager.default.fileExists(atPath: helperSocketPath) { return }

        guard let helperPath = helperBundlePath else {
            NSLog("[VpnPlugin] helper binary not found in app bundle")
            return
        }

        // Create directory
        let dir = (helperSocketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Launch with sudo via osascript (prompts user for password)
        let script = "do shell script \"\\\"\(helperPath)\\\" --socket \\\"\(helperSocketPath)\\\" --pid-file \\\"\(dir)/vpn-helper.pid\\\" &\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            // Wait for socket to appear
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath: helperSocketPath) { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            NSLog("[VpnPlugin] helper launched")
        } catch {
            NSLog("[VpnPlugin] failed to launch helper: \(error)")
        }
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

        // Send StartVpn — pass clientIp as server_ip (helper uses it as TUN local addr)
        let request = "{\"type\":\"start_vpn\",\"version\":1,\"server_ip\":\"\(clientIp)\",\"subnet\":\"10.13.37.0/24\",\"netmask\":\"255.255.255.0\",\"app_port\":9527}\n"
        request.withCString { ptr in _ = Darwin.write(sock, ptr, strlen(ptr)) }

        // Receive response with TUN fd
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

        // Extract fd from SCM_RIGHTS
        var receivedFd: Int32?
        if msg.msg_controllen > 0 {
            let cmsgPtr = controlBuf.assumingMemoryBound(to: cmsghdr.self)
            if cmsgPtr.pointee.cmsg_level == SOL_SOCKET && cmsgPtr.pointee.cmsg_type == SCM_RIGHTS {
                receivedFd = (controlBuf + MemoryLayout<cmsghdr>.size).load(as: Int32.self)
            }
        }
        return (receivedFd, nil)
    }

    // MARK: - TUN read loop

    private func startTUNReadLoop() {
        guard tunFd >= 0 else { return }
        // Ensure blocking mode for read thread
        fcntl(tunFd, F_SETFL, fcntl(tunFd, F_GETFL) & ~O_NONBLOCK)
        let fd = tunFd
        tunReadThread = Thread { self.tunReadLoop(fd: fd) }
        tunReadThread?.name = "VpnPlugin.tunRead"
        tunReadThread?.start()
    }

    private func tunReadLoop(fd: Int32) {
        // Raw TUN fd — reads have 4-byte AF header + IP packet.
        var buf = [UInt8](repeating: 0, count: 2048 + 4)
        while isActive && tunFd >= 0 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 4 {
                if !isActive { break }
                if n < 0 && errno == EAGAIN { Thread.sleep(forTimeInterval: 0.001) }
                continue
            }
            // Skip 4-byte AF header
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
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                if n <= 0 { continue }
                self.udpPacketsIn &+= 1
                self.handleIncomingUDP(Data(bytes: buf, count: n))
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

    private func sendUDP(_ data: UnsafePointer<UInt8>, count: Int) {
        udpPacketsOut &+= 1
        guard udpFd >= 0 else { return }
        _ = Darwin.send(udpFd, data, count, 0)
    }

    private func sendHandshakeInitiation() {
        guard let handle = tunnelHandle else { return }
        var dst = [UInt8](repeating: 0, count: 2048)
        var dstLen = dst.count
        let r = wgQueue.sync { bh_wg_update_timers(handle, &dst, &dstLen) }
        if r == BH_WG_WRITE_TO_NET && dstLen > 0 { sendUDP(dst, count: dstLen) }
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
        }
        timer.resume()
        timerSource = timer
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
        notifyStatusChange()
    }

    private func stopVpn(result: @escaping FlutterResult) {
        stopTunnel(); result(nil)
    }

    private func currentStatusPayload() -> [String: Any] {
        var r: [String: Any] = [:]
        if isActive {
            r["status"] = "connected"; r["connectionMode"] = "direct"
        } else if tunnelHandle != nil {
            r["status"] = "connecting"
        } else {
            r["status"] = "disconnected"
        }
        r["clientIp"] = activeConfig?["clientIp"] as? String
        r["serverIp"] = activeConfig?["serverIp"] as? String
        r["lanPort"] = activeConfig?["lanPort"] as? Int
        r["tunPacketsOut"] = Int64(tunPacketsOut)
        r["tunPacketsIn"] = Int64(tunPacketsIn)
        r["udpPacketsOut"] = Int64(udpPacketsOut)
        r["udpPacketsIn"] = Int64(udpPacketsIn)
        if let h = tunnelHandle {
            var s = bh_wg_stats(time_since_last_handshake_secs: -1, tx_bytes: 0, rx_bytes: 0, estimated_loss: 0, estimated_rtt_ms: -1)
            if withUnsafeMutablePointer(to: &s, { bh_wg_get_stats(h, $0) }) == 1 {
                r["wgTxBytes"] = Int64(s.tx_bytes); r["wgRxBytes"] = Int64(s.rx_bytes)
            }
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
