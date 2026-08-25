import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/platform_capabilities.dart';
import 'package:voyager/src/services/vpn_service.dart';

void main() {
  group('VoyagerPlatform', () {
    test('reports tvOS capabilities when BH_TARGET_TVOS is enabled', () {
      if (!VoyagerPlatform.isTvOS) {
        return;
      }

      expect(VoyagerPlatform.deviceType, 'tv');
      expect(VoyagerPlatform.supportsDesktopDrop, isFalse);
      expect(VoyagerPlatform.supportsWindowTitle, isFalse);
      expect(VoyagerPlatform.usesHardwareKeyboardOnlyTerminalInput, isTrue);
      expect(VpnService.isSupportedPlatform, isFalse);
    });

    test('does not report tvOS without the build flag', () {
      if (VoyagerPlatform.isTvOS) {
        return;
      }

      expect(VoyagerPlatform.deviceType, isNot('tv'));
    });
  });
}
