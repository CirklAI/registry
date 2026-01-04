import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:registry/logger.dart';
import 'package:sqlite3/sqlite3.dart';

final class RegistryDatabase {
  RegistryDatabase({required final Logger logger, String? dbPath})
    : _logger = logger,
      _dbPath = dbPath ?? 'data/registry.db' {
    final dbDir = path.dirname(_dbPath);
    if (dbDir.isNotEmpty) {
      Directory(dbDir).createSync(recursive: true);
    }
    _db = sqlite3.open(_dbPath);
    _configureDatabase();
  }

  final Logger _logger;
  final String _dbPath;
  late final Database _db;

  void _configureDatabase() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA cache_size = -64000');
    _db.execute('PRAGMA foreign_keys = ON');
    _logger.info('Database configured with WAL mode and memory caching');
  }

  void init() {
    final dbExists = File(_dbPath).existsSync();
    _logger.info(
      dbExists
          ? 'Initializing database from existing file: $_dbPath'
          : 'Initializing new database: $_dbPath',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS programs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        version TEXT,
        site TEXT,
        updates_available INTEGER DEFAULT 0,
        updates_url TEXT
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS vulnerabilities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        program_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        cve TEXT,
        url TEXT,
        FOREIGN KEY (program_id) REFERENCES programs(id) ON DELETE CASCADE
      )
    ''');

    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_programs_name ON programs(name)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vulnerabilities_program_id ON vulnerabilities(program_id)',
    );

    _logger.info('Database initialized successfully');
  }

  void sync() {
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _logger.debug('Database synced to disk');
  }

  void writePrograms(Map<String, dynamic> data) {
    _logger.info('Writing programs to database...');

    final programs = data['programs'] as List<dynamic>?;
    if (programs == null) {
      _logger.warning('No programs found in data');
      return;
    }

    final stmt = _db.prepare('''
      INSERT OR REPLACE INTO programs (name, version, site, updates_available, updates_url)
      VALUES (?, ?, ?, ?, ?)
    ''');

    final vulnStmt = _db.prepare('''
      INSERT INTO vulnerabilities (program_id, name, description, cve, url)
      VALUES (?, ?, ?, ?, ?)
    ''');

    try {
      for (final programData in programs) {
        final program = programData as Map<String, dynamic>;
        final name = program['name'] as String? ?? '';
        final version = program['version'] as String?;
        final site = program['site'] as String?;
        final updates = program['updates'] as Map<String, dynamic>?;
        final updatesAvailableValue = updates?['available'];
        final updatesAvailable = updatesAvailableValue is bool
            ? updatesAvailableValue
            : updatesAvailableValue is String
            ? updatesAvailableValue.toLowerCase() == 'true'
            : false;
        final updatesUrl = updates?['url'] as String?;

        stmt.execute([
          name,
          version,
          site,
          updatesAvailable ? 1 : 0,
          updatesUrl,
        ]);

        final programIdResult = _db.select(
          'SELECT id FROM programs WHERE name = ?',
          [name],
        );
        if (programIdResult.isEmpty) {
          _logger.warning('Failed to get program ID for $name');
          continue;
        }
        final programId = programIdResult.first['id'] as int;

        _db.execute('DELETE FROM vulnerabilities WHERE program_id = ?', [
          programId,
        ]);

        final vulnerabilities = program['vulnerabilities'] as List<dynamic>?;
        if (vulnerabilities != null) {
          for (final vulnData in vulnerabilities) {
            final vuln = vulnData as Map<String, dynamic>;
            vulnStmt.execute([
              programId,
              vuln['name'] as String? ?? '',
              vuln['description'] as String?,
              vuln['cve'] as String?,
              vuln['url'] as String?,
            ]);
          }
        }
      }

      _logger.info(
        'Successfully wrote ${programs.length} programs to database',
      );

      sync();
    } finally {
      stmt.close();
      vulnStmt.close();
    }
  }

  void writeSearch(Map<String, dynamic> data) {
    _logger.info('Writing search data to database...');

    final programs = data['programs'] as Map<String, dynamic>?;
    if (programs == null) {
      _logger.warning('No programs found in search data');
      return;
    }

    final programList = programs['program'] as List<dynamic>?;
    if (programList == null) {
      _logger.warning('No program list found in search data');
      return;
    }

    final stmt = _db.prepare('''
      INSERT OR IGNORE INTO programs (name)
      VALUES (?)
    ''');

    try {
      for (final programName in programList) {
        if (programName is String) {
          stmt.execute([programName]);
        }
      }

      _logger.info(
        'Successfully wrote ${programList.length} program names to database',
      );

      sync();
    } finally {
      stmt.close();
    }
  }

  void loadFromJsonFile(String filePath) {
    _logger.info('Loading data from $filePath');
    final file = File(filePath);
    if (!file.existsSync()) {
      _logger.error('File not found: $filePath');
      return;
    }

    final content = file.readAsStringSync();
    final data = jsonDecode(content) as Map<String, dynamic>;

    if (filePath.contains('schema_search.json') ||
        (data.containsKey('programs') && data['programs'] is Map)) {
      writeSearch(data);
    } else if (filePath.contains('schema_program.json') ||
        (data.containsKey('programs') && data['programs'] is List)) {
      writePrograms(data);
    } else {
      _logger.warning('Unknown schema format in $filePath');
    }
  }

  List<Map<String, dynamic>> searchPrograms(String query) {
    final results = _db.select(
      '''
      SELECT DISTINCT p.id, p.name, p.version, p.site, 
             p.updates_available, p.updates_url
      FROM programs p
      WHERE p.name LIKE ? COLLATE NOCASE
      ORDER BY p.name
      ''',
      ['%$query%'],
    );

    final programs = <Map<String, dynamic>>[];
    for (final row in results) {
      final programId = row['id'] as int;
      final vulnerabilities = _db.select(
        '''
        SELECT name, description, cve, url
        FROM vulnerabilities
        WHERE program_id = ?
        ''',
        [programId],
      );

      programs.add({
        'name': row['name'] as String,
        'version': row['version'] as String?,
        'site': row['site'] as String?,
        'vulnerabilities': vulnerabilities
            .map(
              (v) => {
                'name': v['name'] as String,
                'description': v['description'] as String?,
                'cve': v['cve'] as String?,
                'url': v['url'] as String?,
              },
            )
            .toList(),
        'updates': {
          'available': (row['updates_available'] as int? ?? 0) == 1,
          'url': row['updates_url'] as String?,
        },
      });
    }

    return programs;
  }

  Map<String, dynamic>? getProgram(String name) {
    final results = _db.select(
      '''
      SELECT id, name, version, site, updates_available, updates_url
      FROM programs
      WHERE name = ? COLLATE NOCASE
      LIMIT 1
      ''',
      [name],
    );

    if (results.isEmpty) {
      return null;
    }

    final row = results.first;
    final programId = row['id'] as int;
    final vulnerabilities = _db.select(
      '''
      SELECT name, description, cve, url
      FROM vulnerabilities
      WHERE program_id = ?
      ''',
      [programId],
    );

    return {
      'name': row['name'] as String,
      'version': row['version'] as String?,
      'site': row['site'] as String?,
      'vulnerabilities': vulnerabilities
          .map(
            (v) => {
              'name': v['name'] as String,
              'description': v['description'] as String?,
              'cve': v['cve'] as String?,
              'url': v['url'] as String?,
            },
          )
          .toList(),
      'updates': {
        'available': (row['updates_available'] as int? ?? 0) == 1,
        'url': row['updates_url'] as String?,
      },
    };
  }

  void insertProgram(Map<String, dynamic> programData) {
    _logger.info('Inserting program: ${programData['name']}');

    final name = programData['name'] as String? ?? '';
    if (name.isEmpty) {
      throw ArgumentError('Program name is required');
    }

    final version = programData['version'] as String?;
    final site = programData['site'] as String?;
    final updates = programData['updates'] as Map<String, dynamic>?;
    final updatesAvailableValue = updates?['available'];
    final updatesAvailable = updatesAvailableValue is bool
        ? updatesAvailableValue
        : updatesAvailableValue is String
        ? updatesAvailableValue.toLowerCase() == 'true'
        : false;
    final updatesUrl = updates?['url'] as String?;

    final stmt = _db.prepare('''
      INSERT OR REPLACE INTO programs (name, version, site, updates_available, updates_url)
      VALUES (?, ?, ?, ?, ?)
    ''');

    final vulnStmt = _db.prepare('''
      INSERT INTO vulnerabilities (program_id, name, description, cve, url)
      VALUES (?, ?, ?, ?, ?)
    ''');

    try {
      stmt.execute([name, version, site, updatesAvailable ? 1 : 0, updatesUrl]);

      final programIdResult = _db.select(
        'SELECT id FROM programs WHERE name = ?',
        [name],
      );
      if (programIdResult.isEmpty) {
        throw StateError('Failed to get program ID after insert');
      }
      final programId = programIdResult.first['id'] as int;

      _db.execute('DELETE FROM vulnerabilities WHERE program_id = ?', [
        programId,
      ]);

      final vulnerabilities = programData['vulnerabilities'] as List<dynamic>?;
      if (vulnerabilities != null) {
        for (final vulnData in vulnerabilities) {
          final vuln = vulnData as Map<String, dynamic>;
          vulnStmt.execute([
            programId,
            vuln['name'] as String? ?? '',
            vuln['description'] as String?,
            vuln['cve'] as String?,
            vuln['url'] as String?,
          ]);
        }
      }

      _logger.info('Successfully inserted program: $name');

      sync();
    } finally {
      stmt.close();
      vulnStmt.close();
    }
  }

  void close() {
    sync();
    _db.close();
    _logger.info('Database closed and synced to disk');
  }
}
