import Foundation

struct TunnelConfig: Codable {
    let privateKey: String
    let peerPublicKey: String
    let presharedKey: String?
    let keepaliveSecs: UInt16?
    let serverAddr: String        // Horizon's address
    let serverPort: UInt16        // Horizon's WG port
    let clientIp: String          // Assigned VPN IP (e.g., "10.13.37.2")
    let serverIp: String          // Server VPN IP (e.g., "10.13.37.1")
    let subnet: String            // VPN subnet (e.g., "10.13.37.0/24")
    let dns: [String]             // DNS servers
    let dnsMatchDomains: [String] // DNS match domains for split DNS
    let internalRoutes: [String]  // Internal routes for split tunnel
    let mtu: UInt16               // MTU (default 1280)
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
    let connectionMode: String? // "direct" or "relay"
    let tunPacketsOut: UInt64?
    let tunPacketsIn: UInt64?
    let udpPacketsOut: UInt64?
    let udpPacketsIn: UInt64?
    let wgTxBytes: UInt64?
    let wgRxBytes: UInt64?
}
