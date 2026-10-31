
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/local_database.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  static const String _sessionKey = 'twinguard_user_id';

  final LocalDatabase _database = LocalDatabase.instance;

  final Pbkdf2 _passwordHasher = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );

  Future<String> _hashPassword(
    String password,
    List<int> salt,
  ) async {
    final secretKey = await _passwordHasher.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    final bytes = await secretKey.extractBytes();
    return base64Encode(bytes);
  }

  Future<int> register({
    required String username,
    required String password,
  }) async {
    final cleanUsername = username.trim();

    if (cleanUsername.length < 3) {
      throw ArgumentError(
        'Username must contain at least 3 characters.',
      );
    }

    if (password.length < 8) {
      throw ArgumentError(
        'Password must contain at least 8 characters.',
      );
    }

    if (await _database.usernameExists(cleanUsername)) {
      throw ArgumentError(
        'This username is already registered.',
      );
    }

    final random = Random.secure();
final salt = List<int>.generate(
  16,
  (_) => random.nextInt(256),
);
    final passwordHash = await _hashPassword(password, salt);

    final userId = await _database.createUser(
      username: cleanUsername,
      passwordHash: passwordHash,
      passwordSalt: base64Encode(salt),
    );

    await _saveSession(userId);
    return userId;
  }

  Future<int> login({
    required String username,
    required String password,
  }) async {
    final user = await _database.getUserByUsername(username);

    if (user == null) {
      throw ArgumentError('Invalid username or password.');
    }

    final salt = base64Decode(
      user['passwordSalt'] as String,
    );

    final enteredHash = await _hashPassword(password, salt);
    final storedHash = user['passwordHash'] as String;

    if (enteredHash != storedHash) {
      throw ArgumentError('Invalid username or password.');
    }

    final userId = user['id'] as int;
    await _saveSession(userId);

    return userId;
  }

  Future<void> _saveSession(int userId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_sessionKey, userId);
  }

  Future<int?> getCurrentUserId() async {
    final preferences = await SharedPreferences.getInstance();
    final userId = preferences.getInt(_sessionKey);

    if (userId == null) {
      return null;
    }

    final user = await _database.getUserById(userId);

    if (user == null) {
      await logout();
      return null;
    }

    return userId;
  }

  Future<Map<String, dynamic>?> getCurrentUser() async {
    final userId = await getCurrentUserId();

    if (userId == null) {
      return null;
    }

    return _database.getUserById(userId);
  }

  Future<void> logout() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionKey);
  }
}
