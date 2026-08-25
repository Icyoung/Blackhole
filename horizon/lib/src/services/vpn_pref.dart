import 'dart:convert';
import 'dart:io';

/// Missing [vpnEnabled] is on. An explicit false is kept.
bool resolveVpnEnabledPref(Map<String, dynamic>? settings) {
  final value = settings?['vpnEnabled'];
  if (value is bool) {
    return value;
  }
  return true;
}

File horizonSettingsFile({String? home}) {
  final resolved = home ?? Platform.environment['HOME'] ?? '';
  return File('$resolved/.blackhole/horizon/settings.json');
}

/// Settings-page load then save of vpnEnabled, leaving other keys intact.
Map<String, dynamic> settingsDocumentAfterInitSave(
  Map<String, dynamic> document,
) {
  final settings = Map<String, dynamic>.from(
    document['settings'] as Map<String, dynamic>? ?? const {},
  );
  settings['vpnEnabled'] = resolveVpnEnabledPref(settings);
  return {...document, 'settings': settings};
}

bool isVpnHelperDenied(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('user canceled') ||
      text.contains('user cancelled') ||
      text.contains('authorization was cancelled') ||
      text.contains('error -128') ||
      text.contains('(-128)');
}

Future<void> persistHorizonVpnEnabled({
  required bool enabled,
  File? settingsFile,
  String? home,
}) async {
  final File file;
  if (settingsFile != null) {
    file = settingsFile;
  } else {
    final resolved = home ?? Platform.environment['HOME'] ?? '';
    if (resolved.isEmpty) {
      return;
    }
    file = horizonSettingsFile(home: resolved);
  }

  Map<String, dynamic> document = {};
  if (await file.exists()) {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        document = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
  }

  final settings = Map<String, dynamic>.from(
    document['settings'] as Map<String, dynamic>? ?? const {},
  );
  settings['vpnEnabled'] = enabled;
  document['settings'] = settings;
  document.putIfAbsent('version', () => 2);
  document.putIfAbsent('devices', () => <dynamic>[]);

  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(document),
  );
}
