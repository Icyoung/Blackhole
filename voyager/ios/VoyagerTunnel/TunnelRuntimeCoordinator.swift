import Foundation

enum TunnelRuntimeConnectionMode: String, Equatable {
    case direct
}

enum TunnelRuntimeStatus: String, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error
}

enum TunnelRuntimeAction: Equatable {
    case none
    case retryDirect(Int)
}

final class DirectPunchAttemptCoordinator {
    let retryWindow: TimeInterval

    private(set) var generation: UInt64 = 0
    private(set) var deadline: Date?

    init(retryWindow: TimeInterval = 12) {
        self.retryWindow = retryWindow
    }

    @discardableResult
    func start(now: Date = Date()) -> UInt64 {
        generation &+= 1
        deadline = now.addingTimeInterval(retryWindow)
        return generation
    }

    func stop() {
        generation &+= 1
        deadline = nil
    }

    func shouldSend(generation: UInt64, now: Date = Date()) -> Bool {
        guard self.generation == generation, let deadline else {
            return false
        }
        return now < deadline
    }
}

enum TunnelRetryTimerPolicy {
    static func shouldKeepDirectPunchRunning(snapshot: TunnelRuntimeSnapshot) -> Bool {
        switch (snapshot.connectionMode, snapshot.status) {
        case (_, .error), (_, .disconnecting), (_, .disconnected):
            return false
        case (.direct, .connected):
            return false
        default:
            return true
        }
    }
}

struct TunnelRuntimeSnapshot: Equatable {
    let status: TunnelRuntimeStatus
    let connectionMode: TunnelRuntimeConnectionMode
    let error: String?
}

final class TunnelRuntimeCoordinator {
    let handshakeTimeout: TimeInterval
    let directHealthGracePeriod: TimeInterval
    let totalBudget: TimeInterval

    private(set) var snapshot = TunnelRuntimeSnapshot(
        status: .disconnected,
        connectionMode: .direct,
        error: nil
    )

    private var attemptStartedAt: Date?
    private var tunnelStartedAt: Date?
    private var activeDirectCandidateIndex = 0
    private var directHealthyAt: Date?

    init(
        handshakeTimeout: TimeInterval = 12,
        directHealthGracePeriod: TimeInterval = 8,
        totalBudget: TimeInterval = 30
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.directHealthGracePeriod = directHealthGracePeriod
        self.totalBudget = totalBudget
    }

    func start(now: Date = Date()) {
        snapshot = TunnelRuntimeSnapshot(
            status: .connecting,
            connectionMode: .direct,
            error: nil
        )
        attemptStartedAt = now
        tunnelStartedAt = now
        activeDirectCandidateIndex = 0
        directHealthyAt = nil
    }

    func beginDisconnecting() {
        snapshot = TunnelRuntimeSnapshot(
            status: .disconnecting,
            connectionMode: snapshot.connectionMode,
            error: nil
        )
    }

    func stop() {
        snapshot = TunnelRuntimeSnapshot(
            status: .disconnected,
            connectionMode: .direct,
            error: nil
        )
        attemptStartedAt = nil
        tunnelStartedAt = nil
        activeDirectCandidateIndex = 0
        directHealthyAt = nil
    }

    func fail(_ message: String) {
        snapshot = TunnelRuntimeSnapshot(
            status: .error,
            connectionMode: snapshot.connectionMode,
            error: message
        )
    }

    @discardableResult
    func refresh(
        handshakeAgeSeconds: Int64?,
        inboundWireGuardBytes _: UInt64,
        inboundUdpPackets _: UInt64,
        availableDirectCandidateCount: Int,
        now: Date = Date()
    ) -> TunnelRuntimeAction {
        if let handshakeAgeSeconds, handshakeAgeSeconds >= 0 {
            directHealthyAt = now
            snapshot = TunnelRuntimeSnapshot(
                status: .connected,
                connectionMode: .direct,
                error: nil
            )
            return .none
        }

        guard snapshot.status != .error else {
            return .none
        }

        if snapshot.status == .connected {
            guard let startedAt = tunnelStartedAt else {
                return .none
            }
            let elapsed = now.timeIntervalSince(startedAt)
            guard elapsed >= handshakeTimeout else {
                return .none
            }
            if let directHealthyAt,
               now.timeIntervalSince(directHealthyAt) < handshakeTimeout + directHealthGracePeriod {
                return .none
            }
            fail("WireGuard handshake timed out")
            return .none
        }

        guard snapshot.status == .connecting else {
            return .none
        }

        guard let attemptStartedAt, let candidateStartedAt = tunnelStartedAt else {
            return .none
        }

        if now.timeIntervalSince(attemptStartedAt) >= totalBudget {
            fail("WireGuard handshake timed out")
            return .none
        }

        guard now.timeIntervalSince(candidateStartedAt) >= handshakeTimeout else {
            return .none
        }

        if snapshot.connectionMode == .direct {
            let nextIndex = activeDirectCandidateIndex + 1
            if nextIndex < max(availableDirectCandidateCount, 1) {
                activeDirectCandidateIndex = nextIndex
                tunnelStartedAt = now
                snapshot = TunnelRuntimeSnapshot(
                    status: .connecting,
                    connectionMode: .direct,
                    error: nil
                )
                return .retryDirect(nextIndex)
            }
        }

        fail("WireGuard handshake timed out")
        return .none
    }
}
