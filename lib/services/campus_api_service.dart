import 'dart:convert';

import 'package:http/http.dart' as http;

class CampusApiService {
  static const String baseUrl = 'http://127.0.0.1:8000';

  final http.Client _client;

  CampusApiService({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> fetchCampus() async {
    final uri = Uri.parse('$baseUrl/api/campus');

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Campus API failed: HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid campus API response');
    }

    return decoded;
  }

  void dispose() {
    _client.close();
  }
}
