class GroupStorageMigrator {
  static const int currentVersion = 1;

  static Map<String, dynamic> migrate(Map<String, dynamic> data) {
    var version = data['version'];
    var current = version is int ? version : 0;
    while (current < currentVersion) {
      switch (current) {
        case 0:
          data = _migrateV0ToV1(data);
          break;
      }
      current += 1;
    }
    data['version'] = currentVersion;
    return data;
  }

  static Map<String, dynamic> _migrateV0ToV1(Map<String, dynamic> data) {
    data.putIfAbsent('groups', () => <dynamic>[]);
    return data;
  }
}
