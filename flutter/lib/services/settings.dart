import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class Settings extends ChangeNotifier {
  static const _defaultPort = 7331;

  int _apiPort = _defaultPort;
  bool _apiEnabled;

  int get apiPort => _apiPort;
  bool get apiEnabled => _apiEnabled;

  final File _file;

  Settings({File? file})
    : _apiEnabled = true,
      _file = file ?? File(_defaultSettingsPath()) {
    unawaited(_load());
  }

  @visibleForTesting
  Settings.forTesting({bool apiEnabled = false})
    : _apiEnabled = apiEnabled,
      _file = File('settings.test.json');

  static String _defaultSettingsPath() {
    final environment = Platform.environment;
    final separator = Platform.pathSeparator;

    if (Platform.isWindows) {
      final base = environment['APPDATA'] ?? environment['LOCALAPPDATA'] ?? '.';
      return '$base${separator}ESP32-C5 Deauther'
          '${separator}settings.json';
    }

    final home = environment['HOME'];
    final base =
        environment['XDG_CONFIG_HOME'] ??
        (home == null || home.isEmpty ? '.' : '$home$separator.config');
    return '$base${separator}deauther${separator}settings.json';
  }

  Future<void> _load() async {
    try {
      final text = await _file.readAsString();
      final map = jsonDecode(text) as Map<String, dynamic>;
      _apiPort = (map['apiPort'] as int?) ?? _defaultPort;
      _apiEnabled = (map['apiEnabled'] as bool?) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'apiPort': _apiPort, 'apiEnabled': _apiEnabled}),
    );
  }

  Future<void> setApiPort(int port) async {
    _apiPort = port;
    notifyListeners();
    await _save();
  }

  Future<void> setApiEnabled(bool enabled) async {
    _apiEnabled = enabled;
    notifyListeners();
    await _save();
  }
}
