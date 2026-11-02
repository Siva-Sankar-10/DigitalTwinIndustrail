import 'dart:convert';
import '../config/api_config.dart';
import 'package:http/http.dart' as http;

class TelemetryApiService {
  // USB ADB reverse connects the physical phone to the laptop.
  static const String baseUrl = ApiConfig.baseUrl;

  final http.Client _client;

  TelemetryApiService({http.Client? client})
    : _client = client ?? http.Client();

  Future<Map<String, dynamic>> fetchTelemetry({String? departmentId}) async {
    final uri = Uri.parse('$baseUrl/api/telemetry').replace(
      queryParameters: departmentId == null
          ? null
          : {'department_id': departmentId},
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Telemetry API failed: HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid telemetry response format');
      }

      return decoded;
    } catch (error) {
      throw Exception('Unable to fetch telemetry: $error');
    }
  }

  void dispose() {
    _client.close();
  }
}
