import Foundation

// Compile with TunnelRuntimeCoordinator.swift + DirectDatapathCoordinator.swift +
// DirectCandidatePlanner.swift, or use
// `voyager/tool/run_ios_tunnel_runtime_replay.sh`.

private struct Scenario {
    let name: String
    let run: () -> Void
}

private func describe(_ snapshot: TunnelRuntimeSnapshot) -> String {
    "status=\(snapshot.status.rawValue) mode=\(snapshot.connectionMode.rawValue) error=\(snapshot.error ?? "-")"
}

private final class ReplayDirectSession {
    let name: String
    private(set) var writes: [String] = []

    init(name: String) {
        self.name = name
    }

    func write(_ packet: DirectDatapathPacket) {
        writes.append(packet.label)
    }
}

private final class DirectDatapathReplayHarness {
    private let datapath = DirectDatapathCoordinator()
    private(set) var session: ReplayDirectSession?

    func activateSession(name: String) {
        _ = datapath.activateSession()
        session = ReplayDirectSession(name: name)
    }

    func queueHandshake(label: String) {
        queue(
            DirectDatapathPacket(
                data: Data(label.utf8),
                label: label,
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )
    }

    func queueTransport(label: String) {
        queue(
            DirectDatapathPacket(
                data: Data(label.utf8),
                label: label,
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )
    }

    func markReady() {
        let flushed = datapath.markReady()
        for packet in flushed {
            session?.write(packet)
        }
    }

    var pendingLabels: [String] {
        datapath.pendingPackets.map(\.label)
    }

    private func queue(_ packet: DirectDatapathPacket) {
        if datapath.isSessionReady {
            session?.write(packet)
        } else {
            _ = datapath.enqueue(packet)
        }
    }
}

private func expect(
    _ actual: [String],
    equals expected: [String],
    scenario: String,
    step: String
) {
    guard actual == expected else {
        fputs(
            """
            [\(scenario)] \(step) failed
              expected: \(expected)
              actual:   \(actual)

            """,
            stderr
        )
        exit(1)
    }
}

private func expectSnapshot(
    _ snapshot: TunnelRuntimeSnapshot,
    status: TunnelRuntimeStatus,
    error: String? = nil,
    scenario: String,
    step: String
) {
    if snapshot.status != status || snapshot.error != error {
        fputs(
            """
            [\(scenario)] \(step) failed
              expected: status=\(status.rawValue) error=\(error ?? "-")
              actual:   \(describe(snapshot))

            """,
            stderr
        )
        exit(1)
    }
}

private func runScenarios() {
    let scenarios: [Scenario] = [
        Scenario(name: "direct-timeout-errors") {
            let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
            let startedAt = Date(timeIntervalSince1970: 100)
            runtime.start(now: startedAt)
            print("  start => \(describe(runtime.snapshot))")

            let action = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(12.1)
            )
            print("  timeout => action=\(action) \(describe(runtime.snapshot))")
            expectSnapshot(
                runtime.snapshot,
                status: .error,
                error: "WireGuard handshake timed out",
                scenario: "direct-timeout-errors",
                step: "timeout"
            )
        },
        Scenario(name: "direct-timeout-retries-next-candidate") {
            let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
            let startedAt = Date(timeIntervalSince1970: 100)
            runtime.start(now: startedAt)
            print("  start => \(describe(runtime.snapshot))")

            let action = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 3,
                now: startedAt.addingTimeInterval(12.1)
            )
            print("  timeout => action=\(action) \(describe(runtime.snapshot))")
            if action != .retryDirect(1) {
                fputs(
                    "[direct-timeout-retries-next-candidate] expected retryDirect(1), got \(action)\n",
                    stderr
                )
                exit(1)
            }
        },
        Scenario(name: "wan-cone-handshake-gated-connected") {
            let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
            let startedAt = Date(timeIntervalSince1970: 100)
            runtime.start(now: startedAt)
            let withoutHandshake = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 2048,
                inboundUdpPackets: 9,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(1)
            )
            print("  udp-only => action=\(withoutHandshake) \(describe(runtime.snapshot))")
            expectSnapshot(
                runtime.snapshot,
                status: .connecting,
                scenario: "wan-cone-handshake-gated-connected",
                step: "udp-only"
            )

            let withHandshake = runtime.refresh(
                handshakeAgeSeconds: 0,
                inboundWireGuardBytes: 2048,
                inboundUdpPackets: 9,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(2)
            )
            print("  handshake => action=\(withHandshake) \(describe(runtime.snapshot))")
            expectSnapshot(
                runtime.snapshot,
                status: .connected,
                scenario: "wan-cone-handshake-gated-connected",
                step: "handshake"
            )
        },
        Scenario(name: "symmetric-nat-candidates-exhausted-errors") {
            let runtime = TunnelRuntimeCoordinator(
                handshakeTimeout: 12,
                totalBudget: 40
            )
            let startedAt = Date(timeIntervalSince1970: 100)
            runtime.start(now: startedAt)

            let retry1 = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 3,
                now: startedAt.addingTimeInterval(12.1)
            )
            let retry2 = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 3,
                now: startedAt.addingTimeInterval(24.2)
            )
            let exhausted = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 3,
                now: startedAt.addingTimeInterval(36.2)
            )
            print("  retry1 => \(retry1)")
            print("  retry2 => \(retry2)")
            print("  exhausted => action=\(exhausted) \(describe(runtime.snapshot))")
            if retry1 != .retryDirect(1) || retry2 != .retryDirect(2) || exhausted != .none {
                fputs(
                    "[symmetric-nat-candidates-exhausted-errors] unexpected retry sequence\n",
                    stderr
                )
                exit(1)
            }
            expectSnapshot(
                runtime.snapshot,
                status: .error,
                error: "WireGuard handshake timed out",
                scenario: "symmetric-nat-candidates-exhausted-errors",
                step: "exhausted"
            )
        },
        Scenario(name: "healthy-direct-degrades-only-after-grace-window") {
            let runtime = TunnelRuntimeCoordinator(
                handshakeTimeout: 12,
                directHealthGracePeriod: 8
            )
            let startedAt = Date(timeIntervalSince1970: 100)
            runtime.start(now: startedAt)
            _ = runtime.refresh(
                handshakeAgeSeconds: 0,
                inboundWireGuardBytes: 1024,
                inboundUdpPackets: 1,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(1)
            )
            print("  handshake => \(describe(runtime.snapshot))")

            let beforeGraceExpires = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(13)
            )
            print("  before-grace-expires => action=\(beforeGraceExpires) \(describe(runtime.snapshot))")

            let afterGraceExpires = runtime.refresh(
                handshakeAgeSeconds: nil,
                inboundWireGuardBytes: 0,
                inboundUdpPackets: 0,
                availableDirectCandidateCount: 1,
                now: startedAt.addingTimeInterval(21.5)
            )
            print("  after-grace-expires => action=\(afterGraceExpires) \(describe(runtime.snapshot))")
        },
        Scenario(name: "direct-datapath-flushes-handshake-before-plaintext") {
            let replay = DirectDatapathReplayHarness()
            replay.activateSession(name: "candidate-0")
            replay.queueTransport(label: "queued plaintext")
            replay.queueHandshake(label: "initial handshake")
            print("  pending-before-ready => \(replay.pendingLabels)")

            replay.markReady()
            let writes = replay.session?.writes ?? []
            print("  writes-after-ready => \(writes)")
            expect(
                writes,
                equals: ["initial handshake", "queued plaintext"],
                scenario: "direct-datapath-flushes-handshake-before-plaintext",
                step: "ready flush order"
            )
        },
        Scenario(name: "candidate-replacement-retains-plaintext-and-prunes-stale-handshake") {
            let replay = DirectDatapathReplayHarness()
            replay.activateSession(name: "candidate-0")
            replay.queueHandshake(label: "stale handshake")
            replay.queueTransport(label: "first plaintext")
            print("  pending-before-replacement => \(replay.pendingLabels)")

            replay.activateSession(name: "candidate-1")
            replay.queueHandshake(label: "fresh handshake")
            print("  pending-after-replacement => \(replay.pendingLabels)")

            replay.markReady()
            let writes = replay.session?.writes ?? []
            print("  writes-after-replacement-ready => \(writes)")
            expect(
                writes,
                equals: ["fresh handshake", "first plaintext"],
                scenario: "candidate-replacement-retains-plaintext-and-prunes-stale-handshake",
                step: "replacement flush order"
            )
        },
        Scenario(name: "full-queue-transport-enqueue-preserves-pending-handshake") {
            let datapath = DirectDatapathCoordinator(maxPendingPackets: 3)
            _ = datapath.activateSession()
            _ = datapath.enqueue(
                DirectDatapathPacket(
                    data: Data([0x01]),
                    label: "initial handshake",
                    kind: .handshake,
                    surfaceStatusOnSuccess: true
                )
            )
            _ = datapath.enqueue(
                DirectDatapathPacket(
                    data: Data([0x02]),
                    label: "queued plaintext 1",
                    kind: .transport,
                    surfaceStatusOnSuccess: false
                )
            )
            _ = datapath.enqueue(
                DirectDatapathPacket(
                    data: Data([0x03]),
                    label: "queued plaintext 2",
                    kind: .transport,
                    surfaceStatusOnSuccess: false
                )
            )

            let dropped = datapath.enqueue(
                DirectDatapathPacket(
                    data: Data([0x04]),
                    label: "queued plaintext 3",
                    kind: .transport,
                    surfaceStatusOnSuccess: false
                )
            )
            let pending = datapath.pendingPackets.map(\.label)
            print("  dropped-on-full-transport => \(dropped?.label ?? "-")")
            print("  pending-after-full-transport => \(pending)")
            expect(
                [dropped?.label ?? "-"] + pending,
                equals: [
                    "queued plaintext 1",
                    "initial handshake",
                    "queued plaintext 2",
                    "queued plaintext 3",
                ],
                scenario: "full-queue-transport-enqueue-preserves-pending-handshake",
                step: "bounded transport eviction"
            )
        },
        Scenario(name: "viable-preparing-session-sends-handshake-before-ready") {
            let handshakeImmediate = DirectSessionWritePolicy.shouldWriteImmediately(
                packetKind: .handshake,
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: true
            )
            let transportImmediate = DirectSessionWritePolicy.shouldWriteImmediately(
                packetKind: .transport,
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: true
            )
            let probeImmediate = DirectSessionWritePolicy.shouldSendProbe(
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: true
            )

            print("  handshake-immediate => \(handshakeImmediate)")
            print("  transport-immediate => \(transportImmediate)")
            print("  probe-immediate => \(probeImmediate)")
            expect(
                [
                    handshakeImmediate ? "handshake" : "queued",
                    transportImmediate ? "transport" : "queued",
                    probeImmediate ? "probe" : "blocked",
                ],
                equals: ["handshake", "queued", "probe"],
                scenario: "viable-preparing-session-sends-handshake-before-ready",
                step: "pre-ready write policy"
            )
        },
        Scenario(name: "direct-candidate-plan-retains-server-fallback") {
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

            let labels = planned.map { "\($0.addr):\($0.port)/\($0.scope)" }
            print("  planned-candidates => \(labels)")
            expect(
                labels,
                equals: [
                    "192.168.1.219:51820/lan",
                    "100.65.238.106:51820/lan",
                    "14.153.180.50:51820/legacy",
                ],
                scenario: "direct-candidate-plan-retains-server-fallback",
                step: "fallback inclusion"
            )
        },
    ]

    for scenario in scenarios {
        print("[\(scenario.name)]")
        scenario.run()
    }
}

@main
struct TunnelRuntimeReplayMain {
    static func main() {
        runScenarios()
    }
}
