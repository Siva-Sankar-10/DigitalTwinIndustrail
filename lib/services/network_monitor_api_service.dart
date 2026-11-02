
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class NetworkMonitorApiService {
  final http.Client _client;

  NetworkMonitorApiService({http.Client? client})
      : _client = client ?? http.Client();

  Future<Map<String, dynamic>> fetchStatus() async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/api/network-monitor/status',
    );

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 15));

    final dynamic decoded;

    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Invalid monitor response from server.');
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final detail = decoded is Map
          ? decoded['detail']?.toString()
          : null;

      throw Exception(
        detail ?? 'Monitor API error: ${response.statusCode}',
      );
    }

    if (decoded is! Map) {
      throw const FormatException(
        'Invalid network monitor status.',
      );
    }

    return Map<String, dynamic>.from(decoded);
  }

  void dispose() {
    _client.close();
  }
}
