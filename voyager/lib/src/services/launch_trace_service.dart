import 'package:shared_preferences/shared_preferences.dart';

const String kLaunchTraceEntriesKey = 'launchTraceEntries';
const String kLaunchTraceLastKey = 'launchTraceLast';
const int _maxLaunchTraceEntries = 40;
Future<void> _launchTraceWriteChain = Future<void>.value();

Future<void> resetLaunchTrace(String reason) async {
  await _enqueueLaunchTraceWrite((prefs) async {
    final entry = _formatLaunchTraceEntry('reset: $reason');
    await prefs.setStringList(kLaunchTraceEntriesKey, <String>[entry]);
    await prefs.setString(kLaunchTraceLastKey, entry);
  });
}

Future<void> appendLaunchTrace(String message) async {
  await _enqueueLaunchTraceWrite((prefs) async {
    final entries =
        prefs.getStringList(kLaunchTraceEntriesKey)?.toList() ?? <String>[];
    final entry = _formatLaunchTraceEntry(message);
    entries.add(entry);
    if (entries.length > _maxLaunchTraceEntries) {
      entries.removeRange(0, entries.length - _maxLaunchTraceEntries);
    }
    await prefs.setStringList(kLaunchTraceEntriesKey, entries);
    await prefs.setString(kLaunchTraceLastKey, entry);
  });
}

String _formatLaunchTraceEntry(String message) {
  return '[${DateTime.now().toUtc().toIso8601String()}] $message';
}

Future<void> _enqueueLaunchTraceWrite(
  Future<void> Function(SharedPreferences prefs) operation,
) {
  final nextWrite = _launchTraceWriteChain.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    await operation(prefs);
  });
  _launchTraceWriteChain = nextWrite.catchError((_, __) {});
  return nextWrite;
}
