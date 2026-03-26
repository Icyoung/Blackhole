import XCTest

final class DirectCandidatePlannerTests: XCTestCase {

    func testPlanRetainsServerFallbackWhenConfiguredCandidatesAreLanOnly() {
        let planned = DirectCandidatePlanner.plan(
            configured: [
                DirectCandidateConfig(
                    addr: "192.168.1.219",
                    port: 51820,
                    scope: "lan",
                    priority: 250,
                    source: "local_interface:en1"
                ),
                DirectCandidateConfig(
                    addr: "100.65.238.106",
                    port: 51820,
                    scope: "lan",
                    priority: 250,
                    source: "local_interface:utun7"
                ),
            ],
            fallbackAddr: "14.153.180.50",
            fallbackPort: 51820
        )

        XCTAssertEqual(
            planned.map { "\($0.addr):\($0.port)" },
            ["192.168.1.219:51820", "100.65.238.106:51820", "14.153.180.50:51820"]
        )
        XCTAssertEqual(planned.last?.scope, "legacy")
    }

    func testPlanDoesNotDuplicateConfiguredEndpointWhenFallbackMatches() {
        let planned = DirectCandidatePlanner.plan(
            configured: [
                DirectCandidateConfig(
                    addr: "14.153.180.50",
                    port: 51820,
                    scope: "public_observed",
                    priority: 180,
                    source: "wormhole_observed"
                ),
            ],
            fallbackAddr: "14.153.180.50",
            fallbackPort: 51820
        )

        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned[0].scope, "public_observed")
    }

    func testTunnelConfigFallsBackToPersistedDirectCandidatesWhenRuntimeConfigOmitsThem() {
        let persisted = TunnelConfig(
            privateKey: "priv",
            peerPublicKey: "pub",
            presharedKey: nil,
            keepaliveSecs: 25,
            serverAddr: "14.153.180.50",
            serverPort: 51820,
            clientIp: "10.13.37.2",
            serverIp: "10.13.37.1",
            localPort: 34084,
            netcheckHost: "38.60.162.209",
            netcheckPort: 6666,
            lanPort: 9529,
            subnet: "10.13.37.0/24",
            dns: ["10.13.37.1"],
            dnsMatchDomains: [],
            internalRoutes: [],
            mtu: 1420,
            directCandidates: [
                DirectCandidateConfig(
                    addr: "192.168.1.219",
                    port: 51820,
                    scope: "lan",
                    priority: 250,
                    source: "local_interface:en1"
                ),
            ]
        )
        let runtime = TunnelConfig(
            privateKey: "priv",
            peerPublicKey: "pub",
            presharedKey: nil,
            keepaliveSecs: 25,
            serverAddr: "14.153.180.50",
            serverPort: 51820,
            clientIp: "10.13.37.2",
            serverIp: "10.13.37.1",
            localPort: 34084,
            netcheckHost: "38.60.162.209",
            netcheckPort: 6666,
            lanPort: 9529,
            subnet: "10.13.37.0/24",
            dns: ["10.13.37.1"],
            dnsMatchDomains: [],
            internalRoutes: [],
            mtu: 1420,
            directCandidates: nil
        )

        let merged = runtime.preferringPersistedDirectCandidates(persisted)

        XCTAssertEqual(merged.directCandidates?.count, 1)
        XCTAssertEqual(merged.directCandidates?.first?.addr, "192.168.1.219")
        XCTAssertEqual(merged.serverAddr, "14.153.180.50")
        XCTAssertEqual(merged.localPort, 34084)
    }
}
