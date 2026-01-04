import 'dart:io';

mixin TimestampMixin {
  String getTimestamp() {
    return DateTime.now().toIso8601String();
  }
}

mixin ColorMixin {
  static const String reset = '\x1B[0m';
  static const String red = '\x1B[31m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String magenta = '\x1B[35m';
  static const String cyan = '\x1B[36m';
  static const String gray = '\x1B[90m';

  String colorMessage(String message, String color) => '$color$message$reset';
}

mixin LevelMixin on ColorMixin {
  String formatLevel(String level) {
    switch (level) {
      case 'INFO':
        return colorMessage('[INFO] ', ColorMixin.blue);
      case 'WARNING':
        return colorMessage('[WARNING] ', ColorMixin.yellow);
      case 'ERROR':
        return colorMessage('[ERROR] ', ColorMixin.red);
      case 'DEBUG':
        return colorMessage('[DEBUG] ', ColorMixin.cyan);
      case 'SUCCESS':
        return colorMessage('[SUCCESS] ', ColorMixin.green);
      default:
        return colorMessage('[$level] ', ColorMixin.gray);
    }
  }
}

class Logger with TimestampMixin, ColorMixin, LevelMixin {
  final bool enableTimestamp;
  final bool enableDebug;
  final IOSink out;

  Logger({
    this.enableTimestamp = true,
    this.enableDebug = false,
    IOSink? output,
  }) : out = output ?? stdout;

  void info(String message) => _log('INFO', message);

  void warning(String message) => _log('WARNING', message);

  void error(String message) => _log('ERROR', message);

  void debug(String message) {
    if (enableDebug) {
      _log('DEBUG', message);
    }
  }

  void success(String message) => _log('SUCCESS', message);

  void _log(String level, String message) {
    final buffer = StringBuffer();
    if (enableTimestamp) {
      buffer.write('${colorMessage(getTimestamp(), ColorMixin.gray)} ');
    }
    buffer.write(formatLevel(level));
    buffer.write(message);
    out.writeln(buffer.toString());
  }
}
