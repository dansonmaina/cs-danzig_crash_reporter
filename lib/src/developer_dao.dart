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
      version: 2,
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
          sync_status TEXT NOT NULL DEFAULT 'pending'
        )
      '''),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
              "ALTER TABLE $_tableName ADD COLUMN sync_status TEXT NOT NULL DEFAULT 'pending'",
            );
          } catch (_) {
            // Column already exists — safe to ignore
          }
          // Mark any existing records that have a telegram ID as pending so they get synced
          await db.execute(
            "UPDATE $_tableName SET sync_status = 'pending' WHERE telegram_chat_id != ''",
          );
        }
      },
    );
  }

  Future<List<CrashDeveloper>> getAll() async {
    final maps = await (await _database).query(_tableName);
    return maps.map(CrashDeveloper.fromMap).toList();
  }

  Future<List<CrashDeveloper>> getUnsyncedTelegramDevelopers() async {
    final maps = await (await _database).query(
      _tableName,
      where: "sync_status = 'pending' AND telegram_chat_id != ''",
    );
    return maps.map(CrashDeveloper.fromMap).toList();
  }

  Future<void> replaceAll(List<CrashDeveloper> developers) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(_tableName);
      for (final dev in developers) {
        final map = dev.toMap();
        map['sync_status'] = dev.telegramChatId.isNotEmpty ? 'pending' : 'synced';
        await txn.insert(_tableName, map);
      }
    });
  }

  Future<void> updateTelegramChatId(int id, String chatId) async {
    await (await _database).update(
      _tableName,
      {
        'telegram_chat_id': chatId,
        'sync_status': chatId.isNotEmpty ? 'pending' : 'synced',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markTelegramSynced(int id) async {
    await (await _database).update(
      _tableName,
      {'sync_status': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}