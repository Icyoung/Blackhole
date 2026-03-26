import Foundation

enum DirectCandidatePlanner {

    static func plan(
        configured: [DirectCandidateConfig],
        fallbackAddr: String,
        fallbackPort: UInt16
    ) -> [DirectCandidateConfig] {
        var candidates = configured.filter { !$0.addr.isEmpty && $0.port > 0 }

        let normalizedFallbackAddr = fallbackAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFallbackAddr.isEmpty, fallbackPort > 0 {
            candidates.append(
                DirectCandidateConfig(
                    addr: normalizedFallbackAddr,
                    port: fallbackPort,
                    scope: "legacy",
                    priority: 0,
                    source: "vpn_config"
                )
            )
        }

        var deduped: [DirectCandidateConfig] = []
        let prioritized = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.priority == rhs.element.priority {
                return lhs.offset < rhs.offset
            }
            return lhs.element.priority > rhs.element.priority
        }

        for candidate in prioritized.map(\.element) {
            let duplicate = deduped.contains {
                $0.addr == candidate.addr && $0.port == candidate.port
            }
            if !duplicate {
                deduped.append(candidate)
            }
        }
        return deduped
    }
}
