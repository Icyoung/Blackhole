const String kUnknownDeviceName = 'Unknown Device';

String initialDeviceNameForLaunch(String? persistedDeviceName) {
  final trimmed = persistedDeviceName?.trim() ?? '';
  if (trimmed.isEmpty) {
    return kUnknownDeviceName;
  }
  return trimmed;
}

bool shouldRefreshDeviceNameInBackground(String? deviceName) {
  return isGenericDeviceName(deviceName);
}

bool isGenericDeviceName(String? name) {
  if (name == null) {
    return true;
  }
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return true;
  }
  const genericNames = {
    'iPhone',
    'iPad',
    'iPod touch',
    'Android',
    'Apple TV',
    'Mac',
    'Windows',
    'Linux',
    'Web Browser',
    kUnknownDeviceName,
    'Unknown device',
  };
  if (genericNames.contains(trimmed)) {
    return true;
  }
  final duplicatedIosName = RegExp(r'^(iPhone|iPad|iPod touch)\s*\(\1\)$');
  return duplicatedIosName.hasMatch(trimmed);
}
