import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'developer_model.dart';

class CrashDeveloperDao {
  static Database? _db;
  static const _tableName = 'crash_developers';

  Future<Database> get _database async => _db ??= await _open();

  static Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      join(dir.path, 'danzig_crash_reporter.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE $_tableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          full_name TEXT NOT NULL DEFAULT '',
          phone TEXT NOT NULL DEFAULT '',
          email TEXT NOT NULL DEFAULT '',
          app_name TEXT NOT NULL DEFAULT '',
          app_code TEXT NOT NULL DEFAULT '',
          client_name TEXT NOT NULL DEFAULT '',
          telegram_chat_id TEXT NOT NULL DEFAULT '',
          sync_status TEXT NOT NULL DEFAULT 'synced'
        )
      '''),
    );
  }

  Future<List<CrashDeveloper>> getAll() async {
    final maps = await (await _database).query(_tableName);
    return maps.map(CrashDeveloper.fromMap).toList();
  }

  Future<void> replaceAll(List<CrashDeveloper> developers) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(_tableName);
      for (final dev in developers) {
        await txn.insert(_tableName, dev.toMap());
      }
    });
  }

  Future<void> updateTelegramChatId(int id, String chatId) async {
    await (await _database).update(
      _tableName,
      {'telegram_chat_id': chatId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}