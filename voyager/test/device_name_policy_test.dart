import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/device_name_policy.dart';

void main() {
  group('initialDeviceNameForLaunch', () {
    test('uses persisted specific device name immediately', () {
      expect(
        initialDeviceNameForLaunch('Icy iPhone 15 Pro'),
        'Icy iPhone 15 Pro',
      );
    });

    test('falls back to unknown device when persisted name is missing', () {
      expect(initialDeviceNameForLaunch(null), kUnknownDeviceName);
      expect(initialDeviceNameForLaunch('   '), kUnknownDeviceName);
    });
  });

  group('shouldRefreshDeviceNameInBackground', () {
    test('refreshes generic iOS device names in background', () {
      expect(shouldRefreshDeviceNameInBackground('iPhone'), isTrue);
      expect(shouldRefreshDeviceNameInBackground('iPhone (iPhone)'), isTrue);
    });

    test('keeps specific device names without background refresh', () {
      expect(shouldRefreshDeviceNameInBackground('Icy iPhone 15 Pro'), isFalse);
    });
  });
}
