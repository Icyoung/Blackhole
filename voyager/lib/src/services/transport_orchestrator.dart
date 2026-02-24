import 'transport_models.dart';

typedef TransportProbe =
    Future<TransportProbeResult> Function(TransportCandidate candidate);

class TransportOrchestrator {
  TransportOrchestrator({
    this.rttWeight = 1000,
    this.successWeight = 100000,
    this.switchThresholdScore = 150,
    this.minHoldWindow = const Duration(seconds: 8),
  });

  final int rttWeight;
  final int successWeight;
  final int switchThresholdScore;
  final Duration minHoldWindow;
  TransportSelection? _lastSelection;
  DateTime? _lastSelectionAt;

  Future<TransportSelection?> selectBest({
    required List<TransportCandidate> candidates,
    required TransportProbe probe,
  }) async {
    if (candidates.isEmpty) {
      return null;
    }

    final futures = candidates.map(probe).toList(growable: false);
    final results = await Future.wait(futures);

    final successful = results.where((result) => result.success).toList();
    if (successful.isEmpty) {
      return null;
    }

    successful.sort((a, b) => _score(b).compareTo(_score(a)));
    final best = successful.first;
    final bestScore = _score(best);

    final previous = _lastSelection;
    final previousAt = _lastSelectionAt;
    if (previous != null && previousAt != null) {
      final inWindow = DateTime.now().difference(previousAt) < minHoldWindow;
      if (inWindow && previous.candidate.id != best.candidate.id) {
        TransportProbeResult? previousCandidateResult;
        for (final item in successful) {
          if (item.candidate.id == previous.candidate.id) {
            previousCandidateResult = item;
            break;
          }
        }
        final previousScore =
            previousCandidateResult != null
                ? _score(previousCandidateResult)
                : (previous.score ?? 0);
        if (bestScore - previousScore < switchThresholdScore) {
          return previous;
        }
      }
    }
    final selection = TransportSelection(
      candidate: best.candidate,
      probeResult: best,
      pathId: '${best.candidate.kind.wireName}:${best.candidate.id}',
      switchReason:
          previous != null && previous.candidate.id != best.candidate.id
              ? 'rtt_better'
              : null,
      score: bestScore,
    );
    _lastSelection = selection;
    _lastSelectionAt = DateTime.now();
    return selection;
  }

  int _score(TransportProbeResult result) {
    final rttPenalty = result.rtt?.inMilliseconds ?? rttWeight;
    final successBonus = result.success ? successWeight : 0;
    return successBonus + (result.candidate.priority * 100) - rttPenalty;
  }
}
