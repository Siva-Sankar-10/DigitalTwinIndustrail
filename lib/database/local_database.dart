
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._internal();

  static final LocalDatabase instance = LocalDatabase._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initializeDatabase();
    return _database!;
  }

  Future<Database> _initializeDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'twinguard_edge.db');

    return openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await _createDevicesTable(db);
        await _createConnectionsTable(db);
        await _createUsersTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _migrateToVersion2(db);
        }

        if (oldVersion < 3) {
          await _createConnectionsTable(db);
        }

        if (oldVersion < 4) {
          await _createUsersTable(db);
        }
      },
    );
  }

  // --------------------------------------------------
  // DEVICES TABLE
  // --------------------------------------------------

  Future<void> _createDevicesTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        ipAddress TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'offline',
        lastUpdated TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS
      idx_devices_ipAddress
      ON devices(ipAddress)
    ''');
  }

  // --------------------------------------------------
  // CONNECTIONS TABLE
  // --------------------------------------------------

  Future<void> _createConnectionsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS connections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deviceAId INTEGER NOT NULL,
        deviceBId INTEGER NOT NULL,
        createdAt TEXT NOT NULL,

        CHECK (deviceAId < deviceBId),

        UNIQUE (deviceAId, deviceBId),

        FOREIGN KEY (deviceAId)
          REFERENCES devices(id)
          ON DELETE CASCADE,

        FOREIGN KEY (deviceBId)
          REFERENCES devices(id)
          ON DELETE CASCADE
      )
    ''');
  }

  // --------------------------------------------------
  // USERS TABLE
  // --------------------------------------------------

  Future<void> _createUsersTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL COLLATE NOCASE UNIQUE,
        passwordHash TEXT NOT NULL,
        passwordSalt TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');
  }

  // --------------------------------------------------
  // DATABASE MIGRATION
  // --------------------------------------------------

  Future<void> _migrateToVersion2(DatabaseExecutor db) async {
    // Remove blank IP addresses.
    await db.execute('''
      DELETE FROM devices
      WHERE ipAddress IS NULL
         OR TRIM(ipAddress) = ''
    ''');

    // Normalize IP address whitespace.
    await db.execute('''
      UPDATE devices
      SET ipAddress = TRIM(ipAddress)
    ''');

    // Keep the first device for duplicate IP addresses.
    await db.execute('''
      DELETE FROM devices
      WHERE id NOT IN (
        SELECT MIN(id)
        FROM devices
        GROUP BY LOWER(TRIM(ipAddress))
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS
      idx_devices_ipAddress
      ON devices(ipAddress)
    ''');
  }

  // --------------------------------------------------
  // DEVICE OPERATIONS
  // --------------------------------------------------

  Future<int> addDevice({
    required String name,
    required String type,
    required String ipAddress,
    String status = 'offline',
  }) async {
    final db = await database;

    return db.insert('devices', {
      'name': name.trim(),
      'type': type.trim(),
      'ipAddress': ipAddress.trim(),
      'status': status,
      'lastUpdated': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    final db = await database;

    return db.query(
      'devices',
      orderBy: 'id DESC',
    );
  }

  Future<Map<String, dynamic>?> getDeviceById(int id) async {
    final db = await database;

    final results = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    return results.isEmpty ? null : results.first;
  }

  Future<int> updateDeviceStatus(
    int id,
    String status,
  ) async {
    final db = await database;

    return db.update(
      'devices',
      {
        'status': status,
        'lastUpdated': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteDevice(int id) async {
    final db = await database;

    return db.transaction((txn) async {
      await txn.execute('PRAGMA foreign_keys = ON');

      await txn.delete(
        'connections',
        where: 'deviceAId = ? OR deviceBId = ?',
        whereArgs: [id, id],
      );

      return txn.delete(
        'devices',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  // --------------------------------------------------
  // CONNECTION OPERATIONS
  // --------------------------------------------------

  Future<int> addConnection({
    required int deviceAId,
    required int deviceBId,
  }) async {
    if (deviceAId == deviceBId) {
      throw ArgumentError('A device cannot connect to itself.');
    }

    final db = await database;

    final firstId = deviceAId < deviceBId
        ? deviceAId
        : deviceBId;

    final secondId = deviceAId < deviceBId
        ? deviceBId
        : deviceAId;

    return db.insert('connections', {
      'deviceAId': firstId,
      'deviceBId': secondId,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getConnections() async {
    final db = await database;

    return db.query(
      'connections',
      orderBy: 'id DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getConnectedDevices(
    int deviceId,
  ) async {
    final db = await database;

    return db.rawQuery(
      '''
      SELECT devices.*
      FROM devices
      INNER JOIN connections
        ON (
          devices.id = connections.deviceAId
          OR devices.id = connections.deviceBId
        )
      WHERE (
        connections.deviceAId = ?
        OR connections.deviceBId = ?
      )
      AND devices.id != ?
      ORDER BY devices.name COLLATE NOCASE
      ''',
      [deviceId, deviceId, deviceId],
    );
  }

  Future<int> deleteConnection(int connectionId) async {
    final db = await database;

    return db.delete(
      'connections',
      where: 'id = ?',
      whereArgs: [connectionId],
    );
  }

  Future<int> deleteConnectionsForDevice(int deviceId) async {
    final db = await database;

    return db.delete(
      'connections',
      where: 'deviceAId = ? OR deviceBId = ?',
      whereArgs: [deviceId, deviceId],
    );
  }

  // --------------------------------------------------
  // LOCAL USER OPERATIONS
  // Password hashes and salts are supplied by AuthService.
  // Never pass or store a plaintext password in this table.
  // --------------------------------------------------

  Future<int> createUser({
    required String username,
    required String passwordHash,
    required String passwordSalt,
  }) async {
    final db = await database;

    return db.insert('users', {
      'username': username.trim(),
      'passwordHash': passwordHash,
      'passwordSalt': passwordSalt,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>?> getUserByUsername(
    String username,
  ) async {
    final db = await database;

    final results = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: [username.trim()],
      limit: 1,
    );

    return results.isEmpty ? null : results.first;
  }

  Future<Map<String, dynamic>?> getUserById(int id) async {
    final db = await database;

    final results = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    return results.isEmpty ? null : results.first;
  }

  Future<bool> usernameExists(String username) async {
    final db = await database;

    final result = await db.query(
      'users',
      columns: ['id'],
      where: 'username = ?',
      whereArgs: [username.trim()],
      limit: 1,
    );

    return result.isNotEmpty;
  }

  // --------------------------------------------------
  // CLOSE DATABASE
  // --------------------------------------------------

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
