
import 'dart:convert';

import 'package:http/http.dart' as http;

class DeviceHistoryApiService {
  static const String baseUrl = 'http://127.0.0.1:8000';

  final http.Client _client;

  DeviceHistoryApiService({http.Client? client})
      : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _get(
    String endpoint,
  ) async {
    final response = await _client
        .get(Uri.parse('$baseUrl$endpoint'))
        .timeout(const Duration(seconds: 20));

    final dynamic decoded;

    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Server returned invalid JSON.');
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['detail']?.toString()
          : null;

      throw Exception(
        message ?? 'Request failed: ${response.statusCode}',
      );
    }

    if (decoded is! Map) {
      throw const FormatException('Invalid API response.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  // Retrieve previously observed devices.
  Future<Map<String, dynamic>> fetchDeviceHistory({
    int limit = 100,
  }) {
    return _get('/api/history/devices?limit=$limit');
  }

  // Retrieve device discovery and change events.
  Future<Map<String, dynamic>> fetchDeviceEvents({
    int limit = 100,
  }) {
    return _get('/api/history/events?limit=$limit');
  }

  void dispose() {
    _client.close();
  }
}
