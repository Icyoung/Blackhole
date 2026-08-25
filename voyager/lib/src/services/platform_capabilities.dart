import 'dart:io';

import 'package:flutter/foundation.dart';

/// Build-time platform capabilities that are not represented by Flutter's
/// built-in TargetPlatform enum.
class VoyagerPlatform {
  const VoyagerPlatform._();

  static const bool isTvOS = bool.fromEnvironment(
    'BH_TARGET_TVOS',
    defaultValue: false,
  );

  static bool get isTelevision => isTvOS;

  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  static bool get supportsDesktopDrop => isDesktop && !isTvOS;

  static bool get supportsWindowTitle => isDesktop && !isTvOS;

  static bool get usesHardwareKeyboardOnlyTerminalInput =>
      isTelevision || (isDesktop && !isTvOS);

  static String get deviceType {
    if (isTvOS) {
      return 'tv';
    }
    if (kIsWeb) {
      return 'web';
    }
    if (Platform.isIOS || Platform.isAndroid) {
      return 'mobile';
    }
    return 'desktop';
  }
}
