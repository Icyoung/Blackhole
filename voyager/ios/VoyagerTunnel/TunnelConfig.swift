import Foundation

struct DirectCandidateConfig: Codable {
    let addr: String
    let port: UInt16
    let scope: String
    let priority: Int
    let source: String
}

struct TunnelConfig: Codable {
    let privateKey: String
    let peerPublicKey: String
    let presharedKey: String?
    let keepaliveSecs: UInt16?
    let serverAddr: String        // Horizon's address
    let serverPort: UInt16        // Horizon's WG port
    let clientIp: String          // Assigned VPN IP (e.g., "10.13.37.2")
    let serverIp: String          // Server VPN IP (e.g., "10.13.37.1")
    let localPort: UInt16?        // Fixed local UDP source port for direct punching
    let netcheckHost: String?     // Wormhole UDP netcheck host
    let netcheckPort: UInt16?     // Wormhole UDP netcheck port
    let lanPort: UInt16?          // Horizon application websocket port
    let subnet: String            // VPN subnet (e.g., "10.13.37.0/24")
    let dns: [String]             // DNS servers
    let dnsMatchDomains: [String] // DNS match domains for split DNS
    let internalRoutes: [String]  // Internal routes for split tunnel
    let mtu: UInt16               // MTU (default 1280)
    let directCandidates: [DirectCandidateConfig]?
}

extension TunnelConfig {
    func preferringPersistedDirectCandidates(_ persisted: TunnelConfig?) -> TunnelConfig {
        let mergedDirectCandidates: [DirectCandidateConfig]?
        if let directCandidates, !directCandidates.isEmpty {
            mergedDirectCandidates = directCandidates
        } else {
            mergedDirectCandidates = persisted?.directCandidates
        }

        return TunnelConfig(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            presharedKey: presharedKey,
            keepaliveSecs: keepaliveSecs,
            serverAddr: serverAddr,
            serverPort: serverPort,
            clientIp: clientIp,
            serverIp: serverIp,
            localPort: localPort,
            netcheckHost: netcheckHost,
            netcheckPort: netcheckPort,
            lanPort: lanPort,
            subnet: subnet,
            dns: dns,
            dnsMatchDomains: dnsMatchDomains,
            internalRoutes: internalRoutes,
            mtu: mtu,
            directCandidates: mergedDirectCandidates
        )
    }
}

enum TunnelStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error
}

struct TunnelStatusInfo: Codable {
    let status: TunnelStatus
    let timestamp: Date
    let clientIp: String?
    let serverIp: String?
    let lanPort: UInt16?
    let connectionMode: String?
    let tunPacketsOut: UInt64?
    let tunPacketsIn: UInt64?
    let udpPacketsOut: UInt64?
    let udpPacketsIn: UInt64?
    let wgTxBytes: UInt64?
    let wgRxBytes: UInt64?
    let timeSinceLastHandshakeSecs: Int64?
    let plannedDirectCandidates: [DirectCandidateConfig]?
    let observedCandidates: [DirectCandidateConfig]?
    let activeDirectCandidateIndex: Int?
    let activeDirectCandidate: DirectCandidateConfig?
    let directSessionState: String?
    let directSessionViable: Bool?
    let directSessionReady: Bool?
    let pendingDirectQueueDepth: Int?
    let directWriteAttempts: UInt64?
    let directWriteErrors: UInt64?
    let directHandshakePacketsPrepared: UInt64?
    let directHandshakePacketsSuppressed: UInt64?
    let directProbeWriteAttempts: UInt64?
    let lastDirectWriteLabel: String?
    let lastDirectWriteError: String?
    let error: String?
}
