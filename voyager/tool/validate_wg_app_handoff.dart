import 'dart:convert';
import 'dart:io';

import 'package:voyager/src/services/wg_app_flow_validator.dart';

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
  final horizonLogPath = parsed['horizon-log'];
  final vpnStatusPath = parsed['vpn-status'];

  if (horizonLogPath == null || vpnStatusPath == null) {
    stderr.writeln(
      'Usage: dart run tool/validate_wg_app_handoff.dart '
      '--horizon-log /path/to/daemon.log --vpn-status /path/to/vpn_status.json '
      '[--client-ip 10.13.37.x] [--json]',
    );
    exitCode = 64;
    return;
  }

  final horizonLog = await File(horizonLogPath).readAsString();
  final vpnStatus =
      jsonDecode(await File(vpnStatusPath).readAsString())
          as Map<String, dynamic>;
  final result = WgAppFlowValidator.validate(
    horizonLog: horizonLog,
    vpnStatusJson: vpnStatus,
    clientIpOverride: parsed['client-ip'],
  );

  if (parsed.containsKey('json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  } else {
    _printResult(result);
  }

  exitCode = result.isSuccess ? 0 : 1;
}

void _printResult(WgAppFlowValidationResult result) {
  stdout.writeln('WG direct app-flow validation');
  stdout.writeln('clientIp: ${result.clientIp ?? "unknown"}');
  stdout.writeln('peerPublicKey: ${result.peerPublicKey ?? "unknown"}');
  stdout.writeln(
    'directAcceptedPeer: ${result.directAcceptedPeer ?? "unknown"}',
  );
  stdout.writeln('');

  _printCheck('vpn_status connected/direct', result.vpnStatusConnectedDirect);
  _printCheck('directSessionReady=true', result.directSessionReady);
  _printCheck(
    'direct readiness gate satisfied',
    result.directReadinessGateSatisfied,
  );
  _printCheck('Horizon added peer', result.addedPeer);
  _printCheck('Horizon sent vpn_config', result.vpnConfigSent);
  _printCheck('Horizon observed direct probe', result.directProbeObserved);
  _printCheck('Horizon accepted direct UDP', result.directAcceptedPeer != null);
  _printCheck('VPN websocket accepted', result.vpnWebsocketAccepted);
  _printCheck('VPN websocket bootstrap', result.vpnWebsocketBootstrap);
  _printCheck(
    'terminal stdin over VPN websocket',
    result.vpnTerminalStdinObserved,
  );
  _printCheck(
    'terminal stdout over VPN websocket',
    result.vpnTerminalStdoutObserved,
  );

  if (result.warnings.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Warnings:');
    for (final warning in result.warnings) {
      stdout.writeln('- $warning');
    }
  }

  if (result.failures.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Failures:');
    for (final failure in result.failures) {
      stdout.writeln('- $failure');
    }
  }
}

void _printCheck(String label, bool passed) {
  stdout.writeln('${passed ? "PASS" : "FAIL"} $label');
}

Map<String, String> _parseArgs(List<String> args) {
  final parsed = <String, String>{};
  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    final key = arg.substring(2);
    if (key == 'json') {
      parsed[key] = 'true';
      continue;
    }
    if (i + 1 >= args.length) {
      break;
    }
    parsed[key] = args[i + 1];
    i += 1;
  }
  return parsed;
}
