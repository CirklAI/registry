import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:registry/auth.dart' show AuthManager;
import 'package:registry/database.dart' show RegistryDatabase;
import 'package:registry/logger.dart' show Logger;

final class Server {
  final Handler _staticHandler = createStaticHandler(
    'public',
    defaultDocument: 'index.html',
  );

  late final Router _router;
  final int _port;
  final Logger _logger;
  final RegistryDatabase _database;
  final AuthManager _auth;

  Server({
    required final int port,
    required final Logger logger,
    required final RegistryDatabase database,
  }) : _port = port,
       _logger = logger,
       _database = database,
       _auth = AuthManager(logger: logger) {
    _router = Router()
      ..get('/sum/<a|[0-9]+>/<b|[0-9]+>', _sumHandler)
      ..get('/api/programs/search', _searchHandler)
      ..get('/api/programs/get', _getHandler)
      ..get('/admin/setup', _setupPageHandler)
      ..post('/admin/setup', _setupHandler)
      ..get('/admin/login', _loginPageHandler)
      ..post('/admin/login', _loginHandler)
      ..get('/admin/logout', _logoutHandler)
      ..get('/admin', _adminPageHandler)
      ..post('/admin/api/programs', _adminInsertProgramHandler);
  }

  static String _jsonEncode(Object? data) =>
      const JsonEncoder.withIndent(' ').convert(data);

  static const Map<String, String> _jsonHeaders = {
    'content-type': 'application/json',
  };

  static Response _sumHandler(Request request, String a, String b) {
    final aNum = int.parse(a);
    final bNum = int.parse(b);
    return Response.ok(
      _jsonEncode({'a': aNum, 'b': bNum, 'sum': aNum + bNum}),
      headers: {
        ..._jsonHeaders,
        'Cache-Control': 'public, max-age=604800, immutable',
      },
    );
  }

  static final Stopwatch _watch = Stopwatch();

  Response _searchHandler(Request request) {
    final uri = request.url;
    var query = uri.queryParameters['q'] ?? '';
    final isDemo = uri.queryParameters['demo'] == 'true';

    query = query.trim();
    if (query.startsWith('"') && query.endsWith('"')) {
      query = query.substring(1, query.length - 1);
    } else if (query.startsWith("'") && query.endsWith("'")) {
      query = query.substring(1, query.length - 1);
    }

    if (query.isEmpty) {
      return Response(
        400,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Query parameter "q" is required'}),
      );
    }

    try {
      List<Map<String, dynamic>> programs;
      if (isDemo) {
        _logger.info('Demo mode: searching for "$query"');
        programs = _loadDemoSearch(query);
        _logger.info('Demo mode: found ${programs.length} programs');
      } else {
        programs = _database.searchPrograms(query);
      }

      return Response.ok(
        _jsonEncode({'programs': programs}),
        headers: {..._jsonHeaders, 'Cache-Control': 'public, max-age=3600'},
      );
    } catch (e, stackTrace) {
      _logger.error('Error in search handler: $e');
      _logger.error('Stack trace: $stackTrace');
      return Response(
        500,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Internal server error: $e'}),
      );
    }
  }

  Response _getHandler(Request request) {
    final uri = request.url;
    var query = uri.queryParameters['q'] ?? '';
    final isDemo = uri.queryParameters['demo'] == 'true';

    query = query.trim();
    if (query.startsWith('"') && query.endsWith('"')) {
      query = query.substring(1, query.length - 1);
    } else if (query.startsWith("'") && query.endsWith("'")) {
      query = query.substring(1, query.length - 1);
    }

    if (query.isEmpty) {
      return Response(
        400,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Query parameter "q" is required'}),
      );
    }

    try {
      Map<String, dynamic>? program;
      if (isDemo) {
        program = _loadDemoGet(query);
      } else {
        program = _database.getProgram(query);
      }

      if (program == null) {
        return Response(
          404,
          headers: _jsonHeaders,
          body: _jsonEncode({'error': 'Program not found'}),
        );
      }

      return Response.ok(
        _jsonEncode(program),
        headers: {..._jsonHeaders, 'Cache-Control': 'public, max-age=3600'},
      );
    } catch (exception) {
      _logger.error('Error in get handler: $exception');
      return Response(
        500,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  String _resolvePath(String relativePath) {
    final currentDir = Directory.current.path;
    final fullPath = path.join(currentDir, relativePath);
    if (File(fullPath).existsSync()) {
      return fullPath;
    }

    try {
      final scriptPath = Platform.script.toFilePath();
      if (scriptPath.isNotEmpty) {
        final scriptDir = path.dirname(scriptPath);
        final altPath = path.join(scriptDir, '..', relativePath);
        if (File(altPath).existsSync()) {
          return altPath;
        }
      }
    } catch (exception) {
      _logger.error(
        "Exception raised resolving path (lib/server.dart:Server._resolvePath): $exception",
      );
    }
    return relativePath;
  }

  List<Map<String, dynamic>> _loadDemoSearch(String query) {
    final searchPath = _resolvePath('docs/example_search.json');
    final programPath = _resolvePath('docs/example_program.json');
    final searchFile = File(searchPath);
    final programFile = File(programPath);

    _logger.info('Loading demo files: $searchPath, $programPath');

    if (!searchFile.existsSync()) {
      _logger.warning('Demo search file not found: $searchPath');
      return [];
    }
    if (!programFile.existsSync()) {
      _logger.warning('Demo program file not found: $programPath');
      return [];
    }

    final searchData =
        jsonDecode(searchFile.readAsStringSync()) as Map<String, dynamic>;
    final programData =
        jsonDecode(programFile.readAsStringSync()) as Map<String, dynamic>;

    final searchPrograms = searchData['programs'] as List<dynamic>? ?? [];
    final programs = programData['programs'] as List<dynamic>? ?? [];

    final queryLower = query.toLowerCase();
    final matchingPrograms = <Map<String, dynamic>>[];

    for (final programName in searchPrograms) {
      if (programName is String &&
          programName.toLowerCase().contains(queryLower)) {
        Map<String, dynamic>? foundProgram;
        for (final p in programs) {
          if (p is Map<String, dynamic>) {
            final name = p['name'] as String?;
            if (name?.toLowerCase() == programName.toLowerCase()) {
              foundProgram = p;
              break;
            }
          }
        }

        if (foundProgram != null) {
          matchingPrograms.add(_convertProgramToMap(foundProgram));
        } else {
          matchingPrograms.add({
            'name': programName,
            'version': null,
            'site': null,
            'vulnerabilities': <Map<String, dynamic>>[],
            'updates': {'available': false, 'url': null},
          });
        }
      }
    }

    return matchingPrograms;
  }

  Map<String, dynamic>? _loadDemoGet(String query) {
    final programPath = _resolvePath('docs/example_program.json');
    final programFile = File(programPath);

    _logger.info('Loading demo program file: $programPath');

    if (!programFile.existsSync()) {
      _logger.warning('Demo program file not found: $programPath');
      return null;
    }

    final programData =
        jsonDecode(programFile.readAsStringSync()) as Map<String, dynamic>;
    final programs = programData['programs'] as List<dynamic>? ?? [];

    final queryLower = query.toLowerCase();
    for (final program in programs) {
      if (program is Map<String, dynamic>) {
        final name = program['name'] as String?;
        if (name?.toLowerCase() == queryLower) {
          return _convertProgramToMap(program);
        }
      }
    }

    return null;
  }

  Map<String, dynamic> _convertProgramToMap(Map<String, dynamic> program) {
    final updates = program['updates'] as Map<String, dynamic>?;
    final updatesAvailableValue = updates?['available'];
    final updatesAvailable = updatesAvailableValue is bool
        ? updatesAvailableValue
        : updatesAvailableValue is String
        ? updatesAvailableValue.toLowerCase() == 'true'
        : false;

    return {
      'name': program['name'] as String? ?? '',
      'version': program['version'] as String?,
      'site': program['site'] as String?,
      'vulnerabilities':
          (program['vulnerabilities'] as List<dynamic>?)
              ?.map(
                (v) => {
                  'name': v['name'] as String? ?? '',
                  'description': v['description'] as String?,
                  'cve': v['cve'] as String?,
                  'url': v['url'] as String?,
                },
              )
              .toList() ??
          <Map<String, dynamic>>[],
      'updates': {
        'available': updatesAvailable,
        'url': updates?['url'] as String?,
      },
    };
  }

  Future<Response> _setupPageHandler(Request request) async {
    if (_auth.isSetup) {
      return Response.seeOther('/admin/login');
    }

    final newRequest = Request(
      request.method,
      request.requestedUri.replace(path: '/admin_setup.html'),
      headers: request.headers,
      context: request.context,
    );
    return _staticHandler(newRequest);
  }

  Future<Response> _setupHandler(Request request) async {
    if (_auth.isSetup) {
      return Response(
        400,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Admin is already set up'}),
      );
    }

    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final password = data['password'] as String? ?? '';

      if (password.length < 12) {
        return Response(
          400,
          headers: _jsonHeaders,
          body: _jsonEncode({
            'error': 'Password must be at least 12 characters long',
          }),
        );
      }

      if (await _auth.setup(password: password)) {
        return Response.ok(_jsonEncode({'success': true}));
      } else {
        return Response(
          500,
          headers: _jsonHeaders,
          body: _jsonEncode({'error': 'Failed to complete setup'}),
        );
      }
    } catch (exception) {
      _logger.error('Setup error: $exception');
      return Response(
        500,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  Future<Response> _loginPageHandler(Request request) async {
    if (!_auth.isSetup) {
      return Response.seeOther('/admin/setup');
    }

    final newRequest = Request(
      request.method,
      request.requestedUri.replace(path: '/admin_login.html'),
      headers: request.headers,
      context: request.context,
    );
    return _staticHandler(newRequest);
  }

  Future<Response> _loginHandler(Request request) async {
    if (!_auth.isSetup) {
      return Response.seeOther('/admin/setup');
    }

    try {
      final body = await request.readAsString();
      final data = Uri.splitQueryString(body);
      final password = data['password'] ?? '';

      if (_auth.verifyPassword(password)) {
        final sessionToken = _auth.createSession();
        final isSecure = request.requestedUri.scheme == 'https';
        final secureFlag = isSecure ? 'Secure; ' : '';
        return Response.ok(
          _jsonEncode({'success': true}),
          headers: {
            ..._jsonHeaders,
            'Set-Cookie':
                '${AuthManager.sessionCookieName}=$sessionToken; HttpOnly; $secureFlag SameSite=Strict; Path=/; Max-Age=${24 * 3600}',
          },
        );
      } else {
        return Response(
          401,
          headers: _jsonHeaders,
          body: _jsonEncode({'error': 'Invalid password'}),
        );
      }
    } catch (exception) {
      _logger.error('Login error: $exception');
      return Response(
        500,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  Response _logoutHandler(Request request) {
    final isSecure = request.requestedUri.scheme == 'https';
    final secureFlag = isSecure ? 'Secure; ' : '';
    return Response.seeOther('/admin/login').change(
      headers: {
        'Set-Cookie':
            '${AuthManager.sessionCookieName}=; HttpOnly; $secureFlag SameSite=Strict; Path=/; Max-Age=0',
      },
    );
  }

  Future<Response> _adminPageHandler(Request request) async {
    if (!_auth.isSetup) {
      return Response.seeOther('/admin/setup');
    }

    final sessionToken = request.headers['cookie']
        ?.split(';')
        .map((c) => c.trim())
        .firstWhere(
          (c) => c.startsWith('${AuthManager.sessionCookieName}='),
          orElse: () => '',
        )
        .replaceFirst('${AuthManager.sessionCookieName}=', '');

    if (!_auth.verifySession(sessionToken)) {
      return Response.seeOther('/admin/login');
    }

    final newRequest = Request(
      request.method,
      request.requestedUri.replace(path: '/admin.html'),
      headers: request.headers,
      context: request.context,
    );
    return _staticHandler(newRequest);
  }

  Future<Response> _adminInsertProgramHandler(Request request) async {
    if (!_auth.isSetup) {
      return Response(
        401,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Not authenticated'}),
      );
    }

    final sessionToken = request.headers['cookie']
        ?.split(';')
        .map((c) => c.trim())
        .firstWhere(
          (c) => c.startsWith('${AuthManager.sessionCookieName}='),
          orElse: () => '',
        )
        .replaceFirst('${AuthManager.sessionCookieName}=', '');

    if (!_auth.verifySession(sessionToken)) {
      return Response(
        401,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Not authenticated'}),
      );
    }

    try {
      final body = await request.readAsString();
      final programData = jsonDecode(body) as Map<String, dynamic>;

      _database.insertProgram(programData);

      return Response.ok(_jsonEncode({'success': true}));
    } catch (exception) {
      _logger.error('Error inserting program: $exception');
      return Response(
        500,
        headers: _jsonHeaders,
        body: _jsonEncode({'error': 'Failed to insert program: $exception'}),
      );
    }
  }

  Future<void> start() async {
    _logger.info('Starting server on port $_port');
    final cascade = Cascade().add(_staticHandler).add(_router.call);

    final server = await shelf_io.serve(
      logRequests().addHandler(cascade.handler),
      InternetAddress.anyIPv4,
      _port,
    );

    _logger.info('Serving at http://${server.address.host}:${server.port}');
    _watch.start();
  }
}
