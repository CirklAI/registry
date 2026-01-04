import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:registry/logger.dart';

final class AuthManager {
  AuthManager({required final Logger logger}) : _logger = logger {
    _loadConfig();
  }

  final Logger _logger;
  String? _passwordHash;
  String? _sessionSecret;
  bool _isSetup = false;

  static const String _configFile = '.registry_admin_config';
  static const String _sessionCookieName = 'registry_admin_session';
  static const int _sessionDurationHours = 24;

  void _loadConfig() {
    final file = File(_configFile);
    if (!file.existsSync()) {
      _logger.info('No admin configuration found. One-time setup required.');
      return;
    }

    try {
      final content = file.readAsStringSync();
      final config = jsonDecode(content) as Map<String, dynamic>;
      _passwordHash = config['password_hash'] as String?;
      _sessionSecret = config['session_secret'] as String?;
      _isSetup = _passwordHash != null && _sessionSecret != null;

      if (_isSetup) {
        _logger.info('Admin configuration loaded successfully.');
      } else {
        _logger.warning('Admin configuration incomplete. Setup required.');
      }
    } catch (exception) {
      _logger.error('Failed to load admin configuration: $exception');
    }
  }

  bool get isSetup => _isSetup;

  Future<bool> setup({
    required final String password,
    String? existingHash,
    String? existingSecret,
  }) async {
    if (_isSetup) {
      _logger.warning('Admin is already set up. Use changePassword to update.');
      return false;
    }

    if (password.length < 12) {
      _logger.error('Password must be at least 12 characters long.');
      return false;
    }

    try {
      final passwordHash =
          existingHash ?? BCrypt.hashpw(password, BCrypt.gensalt());
      final sessionSecret = existingSecret ?? _generateSecureSecret();

      final config = {
        'password_hash': passwordHash,
        'session_secret': sessionSecret,
        'created_at': DateTime.now().toIso8601String(),
      };

      final file = File(_configFile);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(config),
      );

      try {
        await Process.run('chmod', ['600', _configFile]);
      } catch (exception) {
        _logger.warning('Failed to set file permissions: $exception');
      }

      _passwordHash = passwordHash;
      _sessionSecret = sessionSecret;
      _isSetup = true;

      _logger.info('Admin setup completed successfully.');
      return true;
    } catch (exception) {
      _logger.error('Failed to save admin configuration: $exception');
      return false;
    }
  }

  bool verifyPassword(final String password) {
    if (!_isSetup || _passwordHash == null) {
      return false;
    }

    try {
      return BCrypt.checkpw(password, _passwordHash!);
    } catch (exception) {
      _logger.error('Password verification failed: $exception');
      return false;
    }
  }

  Future<bool> changePassword({
    required final String oldPassword,
    required final String newPassword,
  }) async {
    if (!_isSetup) {
      _logger.error('Admin not set up. Use setup() first.');
      return false;
    }

    if (!verifyPassword(oldPassword)) {
      _logger.warning('Old password verification failed.');
      return false;
    }

    if (newPassword.length < 12) {
      _logger.error('New password must be at least 12 characters long.');
      return false;
    }

    try {
      final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
      final file = File(_configFile);
      final content = file.readAsStringSync();
      final config = jsonDecode(content) as Map<String, dynamic>;
      config['password_hash'] = newHash;
      config['updated_at'] = DateTime.now().toIso8601String();

      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(config),
      );
      _logger.info(
        'Config file updated. Ensure permissions are set to 600: chmod 600 $_configFile',
      );

      _passwordHash = newHash;
      _logger.info('Password changed successfully.');
      return true;
    } catch (exception) {
      _logger.error('Failed to change password: $exception');
      return false;
    }
  }

  String createSession() {
    if (!_isSetup || _sessionSecret == null) {
      throw StateError('Auth not initialized');
    }

    final sessionId = _generateSecureSecret();
    final expiresAt = DateTime.now()
        .add(Duration(hours: _sessionDurationHours))
        .toIso8601String();

    final sessionData = {'session_id': sessionId, 'expires_at': expiresAt};

    final signature = _signSession(sessionData);
    final sessionToken = base64Url.encode(
      utf8.encode('${jsonEncode(sessionData)}.$signature'),
    );

    return sessionToken;
  }

  bool verifySession(final String? sessionToken) {
    if (!_isSetup || _sessionSecret == null || sessionToken == null) {
      return false;
    }

    try {
      final decoded = utf8.decode(base64Url.decode(sessionToken));
      final lastDotIndex = decoded.lastIndexOf('.');
      if (lastDotIndex == -1) {
        return false;
      }

      final sessionData =
          jsonDecode(decoded.substring(0, lastDotIndex))
              as Map<String, dynamic>;
      final signature = decoded.substring(lastDotIndex + 1);

      if (_signSession(sessionData) != signature) {
        _logger.warning('Session signature verification failed.');
        return false;
      }

      final expiresAt = DateTime.parse(sessionData['expires_at'] as String);
      if (expiresAt.isBefore(DateTime.now())) {
        _logger.warning('Session expired.');
        return false;
      }

      return true;
    } catch (exception) {
      _logger.warning('Session verification failed: $exception');
      return false;
    }
  }

  String _signSession(final Map<String, dynamic> sessionData) {
    if (_sessionSecret == null) {
      throw StateError('Session secret not initialized');
    }

    final message = jsonEncode(sessionData);
    final key = utf8.encode(_sessionSecret!);
    final bytes = utf8.encode(message);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);
    return base64Url.encode(digest.bytes);
  }

  String _generateSecureSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String get sessionCookieName => _sessionCookieName;
}
