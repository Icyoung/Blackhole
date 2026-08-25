import XCTest

final class TunnelRuntimeCoordinatorTests: XCTestCase {

    func testDirectPunchAttemptWindowExpiresAtDeadline() {
        let attempt = DirectPunchAttemptCoordinator(retryWindow: 12)
        let startedAt = Date(timeIntervalSince1970: 100)
        let generation = attempt.start(now: startedAt)

        XCTAssertTrue(
            attempt.shouldSend(
                generation: generation,
                now: startedAt.addingTimeInterval(11.9)
            )
        )
        XCTAssertFalse(
            attempt.shouldSend(
                generation: generation,
                now: startedAt.addingTimeInterval(12.0)
            )
        )
    }

    func testDirectPunchAttemptRestartInvalidatesPreviousGeneration() {
        let attempt = DirectPunchAttemptCoordinator(retryWindow: 12)
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstGeneration = attempt.start(now: startedAt)
        let secondGeneration = attempt.start(now: startedAt.addingTimeInterval(3))

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(
            attempt.shouldSend(
                generation: firstGeneration,
                now: startedAt.addingTimeInterval(4)
            )
        )
        XCTAssertTrue(
            attempt.shouldSend(
                generation: secondGeneration,
                now: startedAt.addingTimeInterval(14)
            )
        )
    }

    func testDirectPunchAttemptStopClearsActiveWindow() {
        let attempt = DirectPunchAttemptCoordinator(retryWindow: 12)
        let startedAt = Date(timeIntervalSince1970: 100)
        let generation = attempt.start(now: startedAt)

        attempt.stop()

        XCTAssertFalse(
            attempt.shouldSend(
                generation: generation,
                now: startedAt.addingTimeInterval(1)
            )
        )
        XCTAssertNil(attempt.deadline)
    }

    func testDirectPunchTimerStopsAfterDirectSuccess() {
        let snapshot = TunnelRuntimeSnapshot(
            status: .connected,
            connectionMode: .direct,
            error: nil
        )

        XCTAssertFalse(
            TunnelRetryTimerPolicy.shouldKeepDirectPunchRunning(snapshot: snapshot)
        )
    }

    func testDirectTimeoutWithoutRelayErrors() {
        let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)

        let action = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 1,
            now: startedAt.addingTimeInterval(12.1)
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(runtime.snapshot.status, .error)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
        XCTAssertEqual(runtime.snapshot.error, "WireGuard handshake timed out")
    }

    func testDirectTimeoutRetriesNextCandidateBeforeError() {
        let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)

        let action = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(12.1)
        )

        XCTAssertEqual(action, .retryDirect(1))
        XCTAssertEqual(runtime.snapshot.status, .connecting)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
    }

    func testDirectDoesNotFlapImmediatelyAfterHealthyHandshakeDisappears() {
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

        let action = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 1,
            now: startedAt.addingTimeInterval(13)
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(runtime.snapshot.status, .connected)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
    }

    func testDirectErrorsAfterHealthyGraceWindowExpires() {
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

        let action = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 1,
            now: startedAt.addingTimeInterval(21.5)
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(runtime.snapshot.status, .error)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
        XCTAssertEqual(runtime.snapshot.error, "WireGuard handshake timed out")
    }

    func testDirectRetriesNextCandidateAfterHealthyGraceExpires() {
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
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(1)
        )

        let action = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(21.5)
        )

        XCTAssertEqual(action, .retryDirect(1))
        XCTAssertEqual(runtime.snapshot.status, .connecting)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
        XCTAssertNil(runtime.snapshot.error)
    }

    func testLongLivedSessionHealthLossStartsFreshBudget() {
        let runtime = TunnelRuntimeCoordinator(
            handshakeTimeout: 12,
            directHealthGracePeriod: 8,
            totalBudget: 30
        )
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)
        _ = runtime.refresh(
            handshakeAgeSeconds: 0,
            inboundWireGuardBytes: 1024,
            inboundUdpPackets: 1,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(1)
        )

        let retry = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(120)
        )
        XCTAssertEqual(retry, .retryDirect(1))
        XCTAssertEqual(runtime.snapshot.status, .connecting)
        XCTAssertNil(runtime.snapshot.error)

        let nextTick = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(120.25)
        )
        XCTAssertEqual(nextTick, .none)
        XCTAssertEqual(runtime.snapshot.status, .connecting)
        XCTAssertNil(runtime.snapshot.error)
    }

    func testAllDirectCandidatesExhaustedEmitsError() {
        let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)

        let retry1 = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(12.1)
        )
        XCTAssertEqual(retry1, .retryDirect(1))

        let retry2 = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(24.2)
        )
        XCTAssertEqual(retry2, .retryDirect(2))

        let exhausted = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 3,
            now: startedAt.addingTimeInterval(30.0)
        )
        XCTAssertEqual(exhausted, .none)
        XCTAssertEqual(runtime.snapshot.status, .error)
        XCTAssertEqual(runtime.snapshot.error, "WireGuard handshake timed out")
    }

    func testTotalBudgetExpiresEvenIfCandidatesRemain() {
        let runtime = TunnelRuntimeCoordinator(
            handshakeTimeout: 12,
            totalBudget: 30
        )
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)

        let retry1 = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 4,
            now: startedAt.addingTimeInterval(12.1)
        )
        XCTAssertEqual(retry1, .retryDirect(1))

        let retry2 = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 4,
            now: startedAt.addingTimeInterval(24.2)
        )
        XCTAssertEqual(retry2, .retryDirect(2))

        let budgetExpired = runtime.refresh(
            handshakeAgeSeconds: nil,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 4,
            now: startedAt.addingTimeInterval(30.0)
        )
        XCTAssertEqual(budgetExpired, .none)
        XCTAssertEqual(runtime.snapshot.status, .error)
        XCTAssertEqual(runtime.snapshot.error, "WireGuard handshake timed out")
    }

    func testHandshakeCompletionMarksConnected() {
        let runtime = TunnelRuntimeCoordinator(handshakeTimeout: 12)
        let startedAt = Date(timeIntervalSince1970: 100)

        runtime.start(now: startedAt)

        let action = runtime.refresh(
            handshakeAgeSeconds: 0,
            inboundWireGuardBytes: 0,
            inboundUdpPackets: 0,
            availableDirectCandidateCount: 1,
            now: startedAt.addingTimeInterval(5)
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(runtime.snapshot.status, .connected)
        XCTAssertEqual(runtime.snapshot.connectionMode, .direct)
        XCTAssertNil(runtime.snapshot.error)
    }
}
