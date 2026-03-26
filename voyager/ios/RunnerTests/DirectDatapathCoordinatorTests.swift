import XCTest

final class DirectDatapathCoordinatorTests: XCTestCase {

    func testQueuedHandshakeFlushesAheadOfQueuedTransport() {
        let coordinator = DirectDatapathCoordinator()
        _ = coordinator.activateSession()

        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x02]),
                label: "WireGuard packet",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x01]),
                label: "Initial handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )

        let flushed = coordinator.markReady()

        XCTAssertEqual(flushed.map(\.label), ["Initial handshake", "WireGuard packet"])
        XCTAssertTrue(coordinator.isSessionReady)
        XCTAssertTrue(coordinator.pendingPackets.isEmpty)
    }

    func testCandidateReplacementRetainsTransportButPrunesStaleHandshake() {
        let coordinator = DirectDatapathCoordinator()
        _ = coordinator.activateSession()

        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x11]),
                label: "stale handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x22]),
                label: "first plaintext",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )

        _ = coordinator.activateSession()
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x33]),
                label: "fresh handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )

        let flushed = coordinator.markReady()

        XCTAssertEqual(flushed.map(\.label), ["fresh handshake", "first plaintext"])
    }

    func testBoundedQueueDropsOldestTransportFirst() {
        let coordinator = DirectDatapathCoordinator(maxPendingPackets: 2)
        _ = coordinator.activateSession()

        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x01]),
                label: "oldest transport",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x02]),
                label: "existing handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )

        let dropped = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x03]),
                label: "fresh handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )

        XCTAssertEqual(dropped?.label, "oldest transport")
        XCTAssertEqual(
            coordinator.pendingPackets.map(\.label),
            ["existing handshake", "fresh handshake"]
        )
    }

    func testFullQueueTransportEnqueuePreservesPendingHandshake() {
        let coordinator = DirectDatapathCoordinator(maxPendingPackets: 3)
        _ = coordinator.activateSession()

        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x01]),
                label: "initial handshake",
                kind: .handshake,
                surfaceStatusOnSuccess: true
            )
        )
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x02]),
                label: "queued plaintext 1",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )
        _ = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x03]),
                label: "queued plaintext 2",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )

        let dropped = coordinator.enqueue(
            DirectDatapathPacket(
                data: Data([0x04]),
                label: "queued plaintext 3",
                kind: .transport,
                surfaceStatusOnSuccess: false
            )
        )

        XCTAssertEqual(dropped?.label, "queued plaintext 1")
        XCTAssertEqual(
            coordinator.pendingPackets.map(\.label),
            ["initial handshake", "queued plaintext 2", "queued plaintext 3"]
        )
    }

    func testPreparingViableSessionSendsHandshakeBeforeReadyButQueuesTransport() {
        XCTAssertTrue(
            DirectSessionWritePolicy.shouldWriteImmediately(
                packetKind: .handshake,
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: true
            )
        )
        XCTAssertFalse(
            DirectSessionWritePolicy.shouldWriteImmediately(
                packetKind: .transport,
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: true
            )
        )
    }

    func testNonViablePreparingSessionDoesNotSendHandshakeOrProbeBeforeReady() {
        XCTAssertFalse(
            DirectSessionWritePolicy.shouldWriteImmediately(
                packetKind: .handshake,
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: false
            )
        )
        XCTAssertFalse(
            DirectSessionWritePolicy.shouldSendProbe(
                isSessionReady: false,
                sessionState: "preparing",
                sessionViable: false
            )
        )
    }
}
