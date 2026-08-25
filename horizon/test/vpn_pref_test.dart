import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/vpn_pref.dart';

void main() {
  group('resolveVpnEnabledPref', () {
    test('missing key defaults on', () {
      expect(resolveVpnEnabledPref(null), isTrue);
      expect(resolveVpnEnabledPref(const {}), isTrue);
      expect(resolveVpnEnabledPref({'hostName': 'box'}), isTrue);
    });

    test('explicit false is kept', () {
      expect(resolveVpnEnabledPref({'vpnEnabled': false}), isFalse);
    });

    test('explicit true is kept', () {
      expect(resolveVpnEnabledPref({'vpnEnabled': true}), isTrue);
    });
  });

  group('settings init/save', () {
    test(
      'empty settings.json is not overwritten to vpnEnabled: false',
      () async {
        final dir = await Directory.systemTemp.createTemp('horizon-vpn-pref-');
        addTearDown(() async {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
          }
        });
        final file = File('${dir.path}/settings.json');
        await file.writeAsString('{}');

        final decoded = jsonDecode(await file.readAsString());
        final document =
            decoded is Map<String, dynamic>
                ? Map<String, dynamic>.from(decoded)
                : <String, dynamic>{};
        final saved = settingsDocumentAfterInitSave(document);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(saved),
        );

        final roundTrip =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final settings = roundTrip['settings'] as Map<String, dynamic>;
        expect(settings.containsKey('vpnEnabled'), isTrue);
        expect(settings['vpnEnabled'], isNot(false));
        expect(settings['vpnEnabled'], isTrue);
      },
    );

    test('empty settings map save does not write vpnEnabled: false', () {
      for (final document in [
        <String, dynamic>{},
        <String, dynamic>{'settings': <String, dynamic>{}},
        <String, dynamic>{'version': 2, 'settings': <String, dynamic>{}},
      ]) {
        final saved = settingsDocumentAfterInitSave(document);
        expect(
          (saved['settings'] as Map)['vpnEnabled'],
          isTrue,
          reason: '$document',
        );
      }
    });

    test('existing false survives settings init/save', () {
      final saved = settingsDocumentAfterInitSave({
        'settings': {'vpnEnabled': false, 'hostName': 'kept'},
      });
      final settings = saved['settings'] as Map<String, dynamic>;
      expect(settings['vpnEnabled'], isFalse);
      expect(settings['hostName'], 'kept');
    });
  });

  group('persistHorizonVpnEnabled', () {
    test('deny persists false without dropping other keys', () async {
      final dir = await Directory.systemTemp.createTemp('horizon-vpn-pref-');
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': 2,
          'settings': {'hostName': 'box', 'lanEnabled': true},
          'devices': [
            {'id': 'abc'},
          ],
        }),
      );

      await persistHorizonVpnEnabled(enabled: false, settingsFile: file);

      final saved =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final settings = saved['settings'] as Map<String, dynamic>;
      expect(settings['vpnEnabled'], isFalse);
      expect(settings['hostName'], 'box');
      expect(settings['lanEnabled'], isTrue);
      expect(saved['devices'], [
        {'id': 'abc'},
      ]);
    });
  });

  group('isVpnHelperDenied', () {
    test('matches osascript cancel', () {
      expect(
        isVpnHelperDenied(
          PlatformException(code: 'VPN_HELPER', message: 'User canceled.'),
        ),
        isTrue,
      );
      expect(
        isVpnHelperDenied(
          PlatformException(
            code: 'VPN_HELPER',
            message: 'The authorization was cancelled by the user.',
          ),
        ),
        isTrue,
      );
      expect(
        isVpnHelperDenied(
          PlatformException(code: 'VPN_HELPER', message: 'Timed out waiting'),
        ),
        isFalse,
      );
    });
  });
}
