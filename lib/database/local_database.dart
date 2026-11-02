import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._internal();

  static final LocalDatabase instance = LocalDatabase._internal();

  static Database? _database;

  static int _trafficCleanupCounter = 0;

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }

    _database = await _initializeDatabase();
    return _database!;
  }

  // --------------------------------------------------
  // DATABASE INITIALIZATION
  // VERSION 7: PERSISTENT TRAFFIC HISTORY
  // --------------------------------------------------

  Future<Database> _initializeDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'twinguard_edge.db');

    return openDatabase(
      path,
      version: 7,

      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },

      onCreate: (db, version) async {
        await _createVlansTable(db);
        await _createDevicesTable(db);
        await _createConnectionsTable(db);
        await _createUsersTable(db);
        await _createTrafficHistoryTable(db);
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

        if (oldVersion < 5) {
          await _migrateToVersion5(db);
        }

        if (oldVersion < 6) {
          await _migrateToVersion6(db);
        }

        if (oldVersion < 7) {
          await _migrateToVersion7(db);
        }
      },
    );
  }

  // --------------------------------------------------
  // VLAN TABLE
  // --------------------------------------------------

  Future<void> _createVlansTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vlans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,

        vlanNumber INTEGER NOT NULL UNIQUE
          CHECK (vlanNumber BETWEEN 1 AND 4094),

        name TEXT NOT NULL,
        subnet TEXT,
        description TEXT,

        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');
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
        lastUpdated TEXT NOT NULL,

        vlanId INTEGER,

        FOREIGN KEY (vlanId)
          REFERENCES vlans(id)
          ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS
      idx_devices_ipAddress
      ON devices(ipAddress)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS
      idx_devices_vlanId
      ON devices(vlanId)
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
  // TRAFFIC HISTORY TABLE
  // VERSION 7
  // --------------------------------------------------

  Future<void> _createTrafficHistoryTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS traffic_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,

        interfaceName TEXT NOT NULL,
        sampleTime TEXT NOT NULL,

        downloadMbps REAL NOT NULL,
        uploadMbps REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS
      idx_traffic_history_interface_time
      ON traffic_history(interfaceName, sampleTime)
    ''');
  }

  // --------------------------------------------------
  // DATABASE MIGRATIONS
  // --------------------------------------------------

  // Version 2 migration.
  Future<void> _migrateToVersion2(DatabaseExecutor db) async {
    await db.execute('''
      DELETE FROM devices
      WHERE ipAddress IS NULL
         OR TRIM(ipAddress) = ''
    ''');

    await db.execute('''
      UPDATE devices
      SET ipAddress = TRIM(ipAddress)
    ''');

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

  // Version 5 migration.
  Future<void> _migrateToVersion5(DatabaseExecutor db) async {
    await _ensureVlanSchema(db);
  }

  // Version 6 migration.
  Future<void> _migrateToVersion6(DatabaseExecutor db) async {
    await _ensureVlanSchema(db);
  }

  // Version 7 migration.
  // Adds traffic history without deleting existing records.
  Future<void> _migrateToVersion7(DatabaseExecutor db) async {
    await _createTrafficHistoryTable(db);
  }

  // --------------------------------------------------
  // SHARED VLAN SCHEMA MIGRATION
  // --------------------------------------------------

  Future<void> _ensureVlanSchema(DatabaseExecutor db) async {
    await _createVlansTable(db);

    final columns = await db.rawQuery('PRAGMA table_info(devices)');

    final hasVlanId = columns.any((column) => column['name'] == 'vlanId');

    if (!hasVlanId) {
      await db.execute('''
        ALTER TABLE devices
        ADD COLUMN vlanId INTEGER
        REFERENCES vlans(id)
        ON DELETE SET NULL
      ''');
    }

    await db.execute('''
      CREATE INDEX IF NOT EXISTS
      idx_devices_vlanId
      ON devices(vlanId)
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
    int? vlanId,
  }) async {
    final cleanName = name.trim();
    final cleanType = type.trim();
    final cleanIp = ipAddress.trim();

    if (cleanName.isEmpty) {
      throw ArgumentError('Device name cannot be empty.');
    }

    if (cleanType.isEmpty) {
      throw ArgumentError('Device type cannot be empty.');
    }

    if (cleanIp.isEmpty) {
      throw ArgumentError('IP address cannot be empty.');
    }

    final db = await database;

    return db.insert('devices', {
      'name': cleanName,
      'type': cleanType,
      'ipAddress': cleanIp,
      'status': status,
      'lastUpdated': DateTime.now().toIso8601String(),
      'vlanId': vlanId,
    });
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    final db = await database;

    return db.query('devices', orderBy: 'id DESC');
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

  Future<int> updateDeviceStatus(int id, String status) async {
    final db = await database;

    return db.update(
      'devices',
      {'status': status, 'lastUpdated': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteDevice(int id) async {
    final db = await database;

    return db.transaction((txn) async {
      await txn.delete(
        'connections',
        where: 'deviceAId = ? OR deviceBId = ?',
        whereArgs: [id, id],
      );

      return txn.delete('devices', where: 'id = ?', whereArgs: [id]);
    });
  }

  // --------------------------------------------------
  // DEVICE VLAN ASSIGNMENT
  // --------------------------------------------------

  Future<int> assignDeviceToVlan({
    required int deviceId,
    required int vlanId,
  }) async {
    final db = await database;

    return db.update(
      'devices',
      {'vlanId': vlanId, 'lastUpdated': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<int> unassignDeviceFromVlan(int deviceId) async {
    final db = await database;

    return db.update(
      'devices',
      {'vlanId': null, 'lastUpdated': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<List<Map<String, dynamic>>> getDevicesByVlan(int vlanId) async {
    final db = await database;

    return db.query(
      'devices',
      where: 'vlanId = ?',
      whereArgs: [vlanId],
      orderBy: 'name COLLATE NOCASE',
    );
  }

  // --------------------------------------------------
  // VLAN OPERATIONS
  // --------------------------------------------------

  void _validateVlan({required int vlanNumber, required String name}) {
    if (vlanNumber < 1 || vlanNumber > 4094) {
      throw ArgumentError('VLAN ID must be between 1 and 4094.');
    }

    if (name.trim().isEmpty) {
      throw ArgumentError('VLAN name cannot be empty.');
    }
  }

  String? _cleanOptional(String? value) {
    final cleaned = value?.trim();

    if (cleaned == null || cleaned.isEmpty) {
      return null;
    }

    return cleaned;
  }

  Future<int> createVlan({
    required int vlanNumber,
    required String name,
    String? subnet,
    String? description,
  }) async {
    _validateVlan(vlanNumber: vlanNumber, name: name);

    final db = await database;
    final now = DateTime.now().toIso8601String();

    return db.insert('vlans', {
      'vlanNumber': vlanNumber,
      'name': name.trim(),
      'subnet': _cleanOptional(subnet),
      'description': _cleanOptional(description),
      'createdAt': now,
      'updatedAt': now,
    });
  }

  Future<int> updateVlan({
    required int id,
    required int vlanNumber,
    required String name,
    String? subnet,
    String? description,
  }) async {
    _validateVlan(vlanNumber: vlanNumber, name: name);

    final db = await database;

    return db.update(
      'vlans',
      {
        'vlanNumber': vlanNumber,
        'name': name.trim(),
        'subnet': _cleanOptional(subnet),
        'description': _cleanOptional(description),
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getVlans() async {
    final db = await database;

    return db.rawQuery('''
      SELECT
        vlans.*,
        COUNT(devices.id) AS deviceCount
      FROM vlans
      LEFT JOIN devices
        ON devices.vlanId = vlans.id
      GROUP BY vlans.id
      ORDER BY vlans.vlanNumber ASC
    ''');
  }

  Future<Map<String, dynamic>?> getVlanById(int id) async {
    final db = await database;

    final rows = await db.query(
      'vlans',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<int> deleteVlan(int id) async {
    final db = await database;

    return db.transaction((txn) async {
      await txn.update(
        'devices',
        {'vlanId': null, 'lastUpdated': DateTime.now().toIso8601String()},
        where: 'vlanId = ?',
        whereArgs: [id],
      );

      return txn.delete('vlans', where: 'id = ?', whereArgs: [id]);
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

    final firstId = deviceAId < deviceBId ? deviceAId : deviceBId;

    final secondId = deviceAId < deviceBId ? deviceBId : deviceAId;

    return db.insert('connections', {
      'deviceAId': firstId,
      'deviceBId': secondId,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getConnections() async {
    final db = await database;

    return db.query('connections', orderBy: 'id DESC');
  }

  Future<List<Map<String, dynamic>>> getConnectedDevices(int deviceId) async {
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

    return db.delete('connections', where: 'id = ?', whereArgs: [connectionId]);
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
  // TRAFFIC HISTORY OPERATIONS
  // --------------------------------------------------

  // Save a successful real traffic sample.
  Future<int> saveTrafficSample({
    required String interfaceName,
    required DateTime sampleTime,
    required double downloadMbps,
    required double uploadMbps,
  }) async {
    final cleanInterface = interfaceName.trim();

    if (cleanInterface.isEmpty) {
      throw ArgumentError('Interface name cannot be empty.');
    }

    if (!downloadMbps.isFinite ||
        !uploadMbps.isFinite ||
        downloadMbps < 0 ||
        uploadMbps < 0) {
      throw ArgumentError('Invalid traffic speed.');
    }

    final db = await database;

    final id = await db.insert('traffic_history', {
      'interfaceName': cleanInterface,
      'sampleTime': sampleTime.toUtc().toIso8601String(),
      'downloadMbps': downloadMbps,
      'uploadMbps': uploadMbps,
    });

    // Clean expired records every 100 inserts.
    _trafficCleanupCounter++;

    if (_trafficCleanupCounter >= 100) {
      _trafficCleanupCounter = 0;

      final cutoff = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 7))
          .toIso8601String();

      await db.delete(
        'traffic_history',
        where: 'sampleTime < ?',
        whereArgs: [cutoff],
      );
    }

    return id;
  }

  // Retrieve the latest traffic samples.
  // Results are returned oldest first.
  Future<List<Map<String, dynamic>>> getTrafficHistory({
    String interfaceName = 'Wi-Fi',
    int limit = 60,
  }) async {
    final cleanInterface = interfaceName.trim();

    if (cleanInterface.isEmpty) {
      throw ArgumentError('Interface name cannot be empty.');
    }

    if (limit < 1 || limit > 50000) {
      throw ArgumentError('Limit must be between 1 and 20000.');
    }

    final db = await database;

    final results = await db.query(
      'traffic_history',
      where: 'interfaceName = ?',
      whereArgs: [cleanInterface],
      orderBy: 'sampleTime DESC, id DESC',
      limit: limit,
    );

    return results.reversed.toList();
  }

  // Delete all traffic records or one interface's records.
  Future<int> clearTrafficHistory({String? interfaceName}) async {
    final db = await database;

    final cleanInterface = interfaceName?.trim();

    if (cleanInterface != null && cleanInterface.isEmpty) {
      throw ArgumentError('Interface name cannot be empty.');
    }

    if (cleanInterface == null) {
      return db.delete('traffic_history');
    }

    return db.delete(
      'traffic_history',
      where: 'interfaceName = ?',
      whereArgs: [cleanInterface],
    );
  }

  // --------------------------------------------------
  // LOCAL USER OPERATIONS
  // --------------------------------------------------

  // Password hashes and salts are supplied by AuthService.
  // Never store plaintext passwords.

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

  Future<Map<String, dynamic>?> getUserByUsername(String username) async {
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
