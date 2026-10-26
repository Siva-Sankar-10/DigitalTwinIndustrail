
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._internal();

  static final LocalDatabase instance = LocalDatabase._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;

    _database = await _initializeDatabase();
    return _database!;
  }

  Future<Database> _initializeDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'twinguard_edge.db');

    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            ipAddress TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'Unknown',
            lastUpdated TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE UNIQUE INDEX idx_devices_ip_address
          ON devices(ipAddress)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Keep the existing devices. Remove duplicate IP entries,
          // preserving the newest entry for each IP address.
          await db.execute('''
            DELETE FROM devices
            WHERE id NOT IN (
              SELECT MAX(id)
              FROM devices
              GROUP BY LOWER(TRIM(ipAddress))
            )
          ''');

          // Normalize existing IP addresses.
          await db.execute('''
            UPDATE devices
            SET ipAddress = LOWER(TRIM(ipAddress))
          ''');

          await db.execute('''
            CREATE UNIQUE INDEX idx_devices_ip_address
            ON devices(ipAddress)
          ''');
        }
      },
    );
  }

  Future<int> addDevice({
    required String name,
    required String type,
    required String ipAddress,
    String status = 'Unknown',
  }) async {
    final db = await database;
    final normalizedIp = ipAddress.trim().toLowerCase();

    if (normalizedIp.isEmpty) {
      throw ArgumentError('IP address cannot be empty.');
    }

    final existing = await db.query(
      'devices',
      where: 'LOWER(TRIM(ipAddress)) = ?',
      whereArgs: [normalizedIp],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      throw StateError(
        'A device with IP address $normalizedIp already exists.',
      );
    }

    return db.insert('devices', {
      'name': name.trim(),
      'type': type,
      'ipAddress': normalizedIp,
      'status': status,
      'lastUpdated': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    final db = await database;

    return db.query(
      'devices',
      orderBy: 'id DESC',
    );
  }

  Future<int> updateDeviceStatus(int id, String status) async {
    final db = await database;

    return db.update(
      'devices',
      {
        'status': status,
        'lastUpdated': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteDevice(int id) async {
    final db = await database;

    return db.delete(
      'devices',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
