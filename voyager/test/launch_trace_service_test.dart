import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyager/src/services/launch_trace_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('serializes reset and append calls in invocation order', () async {
    await Future.wait([
      resetLaunchTrace('initState'),
      appendLaunchTrace('_loadSettings start'),
      appendLaunchTrace('_connect enter'),
    ]);

    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(kLaunchTraceEntriesKey);

    expect(entries, isNotNull);
    expect(entries, hasLength(3));
    expect(entries![0], contains('reset: initState'));
    expect(entries[1], contains('_loadSettings start'));
    expect(entries[2], contains('_connect enter'));
    expect(prefs.getString(kLaunchTraceLastKey), entries.last);
  });
}
