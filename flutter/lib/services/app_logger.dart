import 'dart:async';
import 'dart:io';

/// Small file logger used by the portable desktop build.
///
/// The preferred location is beside the executable so the diagnostic file is
/// easy to find and send. A per-user directory and the temporary directory are
/// used as fallbacks when the executable directory is read-only.
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  File? _file;
  Future<void> _pendingWrite = Future<void>.value();

  String? get logPath => _file?.path;

  Future<void> initialize() async {
    if (_file != null) return;

    final now = DateTime.now();
    final fileName = 'ESP32-C5-Controller-${_fileTimestamp(now)}.log';
    final candidates = <Directory>[
      File(Platform.resolvedExecutable).parent,
      if (Platform.environment['LOCALAPPDATA'] case final localAppData?)
        Directory(
          '$localAppData${Platform.pathSeparator}ESP32-C5-Controller'
          '${Platform.pathSeparator}Logs',
        ),
      Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ESP32-C5-Controller-Logs',
      ),
    ];

    for (final directory in candidates) {
      try {
        await directory.create(recursive: true);
        final file = File(
          '${directory.path}${Platform.pathSeparator}$fileName',
        );
        await file.writeAsString(
          <String>[
            'ESP32-C5 Controller diagnostic log',
            'Started: ${now.toIso8601String()}',
            'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            'Executable: ${Platform.resolvedExecutable}',
            'PID: $pid',
            '',
          ].join(_newline),
          flush: true,
        );
        _file = file;
        info('Diagnostic log initialized: ${file.path}');
        return;
      } catch (_) {
        // Try the next writable location. Logging must never prevent startup.
      }
    }
  }

  void info(String message) => _append('INFO', message);

  void warning(String message) => _append('WARN', message);

  void error(
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final detail = StringBuffer(message);
    if (error != null) detail.write('\n$error');
    if (stackTrace != null) detail.write('\n$stackTrace');
    _append('ERROR', detail.toString());
  }

  Future<void> flush() => _pendingWrite;

  Future<String> revealLog() async {
    await initialize();
    final file = _file;
    if (file == null) {
      throw const FileSystemException('No writable log location was found');
    }
    await flush();

    ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run('explorer.exe', <String>['/select,', file.path]);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', <String>[file.parent.path]);
    } else if (Platform.isMacOS) {
      result = await Process.run('open', <String>['-R', file.path]);
    } else {
      throw UnsupportedError('Opening the log folder is desktop-only');
    }

    if (result.exitCode != 0) {
      throw ProcessException(
        'file manager',
        const <String>[],
        '${result.stderr}',
        result.exitCode,
      );
    }
    return file.path;
  }

  void _append(String level, String message) {
    final file = _file;
    if (file == null) return;

    final timestamp = DateTime.now().toIso8601String();
    final normalized = message.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final output = lines
        .map((line) => '[$timestamp] [$level] $line$_newline')
        .join();

    _pendingWrite = _pendingWrite
        .then<void>(
          (_) async {
            await file.writeAsString(
              output,
              mode: FileMode.append,
              flush: true,
            );
          },
        )
        .onError((Object _, StackTrace __) {});
  }

  static String get _newline => Platform.isWindows ? '\r\n' : '\n';

  static String _fileTimestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }
}
