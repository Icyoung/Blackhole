import Foundation

enum DirectSessionWritePolicy {
    static func shouldWriteImmediately(
        packetKind: DirectDatapathPacketKind,
        isSessionReady: Bool,
        sessionState: String?,
        sessionViable: Bool?
    ) -> Bool {
        if isSessionReady {
            return true
        }

        guard packetKind == .handshake else {
            return false
        }

        guard sessionViable != false else {
            return false
        }

        return allowsPreReadyWrites(sessionState: sessionState)
    }

    static func shouldSendProbe(
        isSessionReady: Bool,
        sessionState: String?,
        sessionViable: Bool?
    ) -> Bool {
        if isSessionReady {
            return true
        }

        guard sessionViable != false else {
            return false
        }

        return allowsPreReadyWrites(sessionState: sessionState)
    }

    private static func allowsPreReadyWrites(sessionState: String?) -> Bool {
        switch sessionState {
        case nil, "preparing", "waiting":
            return true
        case "ready":
            return true
        default:
            return false
        }
    }
}

enum DirectDatapathPacketKind: Equatable {
    case handshake
    case transport
}

struct DirectDatapathPacket: Equatable {
    let data: Data
    let label: String
    let kind: DirectDatapathPacketKind
    let surfaceStatusOnSuccess: Bool
}

final class DirectDatapathCoordinator {
    let maxPendingPackets: Int

    private(set) var generation: UInt64 = 0
    private(set) var isSessionReady = false
    private(set) var pendingPackets: [DirectDatapathPacket] = []

    init(maxPendingPackets: Int = 64) {
        self.maxPendingPackets = maxPendingPackets
    }

    @discardableResult
    func activateSession(prunePendingHandshakePackets: Bool = true) -> UInt64 {
        generation &+= 1
        isSessionReady = false
        if prunePendingHandshakePackets {
            pendingPackets.removeAll { $0.kind == .handshake }
        }
        return generation
    }

    func reset() {
        generation &+= 1
        isSessionReady = false
        pendingPackets.removeAll(keepingCapacity: true)
    }

    func markNotReady() {
        isSessionReady = false
    }

    func markReady() -> [DirectDatapathPacket] {
        guard !isSessionReady else { return [] }
        isSessionReady = true
        let queuedPackets = pendingPackets
        pendingPackets.removeAll(keepingCapacity: true)
        return queuedPackets
    }

    @discardableResult
    func enqueue(_ packet: DirectDatapathPacket) -> DirectDatapathPacket? {
        var droppedPacket: DirectDatapathPacket?
        if pendingPackets.count >= maxPendingPackets {
            let dropIndex = dropIndex(for: packet.kind)
            droppedPacket = pendingPackets.remove(at: dropIndex)
        }
        pendingPackets.insert(packet, at: insertionIndex(for: packet.kind))
        return droppedPacket
    }

    private func insertionIndex(for kind: DirectDatapathPacketKind) -> Int {
        switch kind {
        case .handshake:
            return pendingPackets.firstIndex(where: { $0.kind != .handshake }) ?? pendingPackets.endIndex
        case .transport:
            return pendingPackets.endIndex
        }
    }

    private func dropIndex(for incomingKind: DirectDatapathPacketKind) -> Int {
        switch incomingKind {
        case .handshake:
            return pendingPackets.firstIndex(where: { $0.kind == .transport }) ?? 0
        case .transport:
            return pendingPackets.firstIndex(where: { $0.kind == .transport }) ?? 0
        }
    }
}
