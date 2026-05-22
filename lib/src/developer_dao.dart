import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'developer_model.dart';
import 'telegram_user_model.dart';

class CrashDeveloperDao {
  static Database? _db;
  static const _tableName = 'crash_developers';
  static const _telegramUsersTable = 'telegram_users';

  Future<Database> get _database async => _db ??= await _open();

  static Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      join(dir.path, 'danzig_crash_reporter.db'),
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
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
        ''');
        await db.execute('''
          CREATE TABLE $_telegramUsersTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_chat_id TEXT NOT NULL UNIQUE DEFAULT '',
            first_name TEXT NOT NULL DEFAULT '',
            last_name TEXT NOT NULL DEFAULT '',
            username TEXT NOT NULL DEFAULT '',
            language_code TEXT NOT NULL DEFAULT 'en',
            sync_status TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
              "ALTER TABLE $_tableName ADD COLUMN sync_status TEXT NOT NULL DEFAULT 'pending'",
            );
          } catch (_) {}
          await db.execute(
            "UPDATE $_tableName SET sync_status = 'pending' WHERE telegram_chat_id != ''",
          );
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $_telegramUsersTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              telegram_chat_id TEXT NOT NULL UNIQUE DEFAULT '',
              first_name TEXT NOT NULL DEFAULT '',
              last_name TEXT NOT NULL DEFAULT '',
              username TEXT NOT NULL DEFAULT '',
              language_code TEXT NOT NULL DEFAULT 'en',
              sync_status TEXT NOT NULL DEFAULT 'pending'
            )
          ''');
        }
      },
    );
  }

  // ── crash_developers ──────────────────────────────────────────────────────

  Future<List<CrashDeveloper>> getAll() async {
    final maps = await (await _database).query(_tableName);
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

  // ── telegram_users ────────────────────────────────────────────────────────

  Future<void> insertOrIgnoreTelegramUser(TelegramUser user) async {
    await (await _database).insert(
      _telegramUsersTable,
      user.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<TelegramUser>> getUnsyncedTelegramUsers() async {
    final maps = await (await _database).query(
      _telegramUsersTable,
      where: "sync_status = 'pending'",
    );
    return maps.map(TelegramUser.fromMap).toList();
  }

  Future<void> markTelegramUserSynced(int id) async {
    await (await _database).update(
      _telegramUsersTable,
      {'sync_status': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}