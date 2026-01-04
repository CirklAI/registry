import 'package:registry/logger.dart' show Logger;
import 'package:registry/server.dart' show Server;
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:registry/database.dart' show RegistryDatabase;

Future<void> main() async {
  final Logger logger = Logger();
  logger.info("Starting Cirkl Labs/Registry");
  logger.info(" Dart: v${Platform.version}");
  logger.info(" SQLite: ${sqlite3.version.libVersion}");

  final registryDatabase = RegistryDatabase(logger: logger);
  registryDatabase.init();

  registryDatabase.loadFromJsonFile('docs/schema_search.json');
  registryDatabase.loadFromJsonFile('docs/schema_program.json');

  final server = Server(port: 8080, logger: logger, database: registryDatabase);
  await server.start();
}
