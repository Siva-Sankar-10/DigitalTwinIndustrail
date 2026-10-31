
import 'dart:convert';

import 'package:http/http.dart' as http;

class WifiDiscoveryApiService {
  static const String baseUrl = 'http://127.0.0.1:8000';

  final http.Client _client;

  WifiDiscoveryApiService({http.Client? client})
      : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _handleResponse(
    http.Response response,
  ) async {
    final dynamic decoded;

    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Server returned an invalid response.');
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['detail']?.toString()
          : null;

      throw Exception(
        message ?? 'API request failed: ${response.statusCode}',
      );
    }

    if (decoded is! Map) {
      throw const FormatException('Invalid API response.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  // 1. Discover actual Wi-Fi devices.
  Future<Map<String, dynamic>> discoverDevices({
    String interfaceAlias = 'Wi-Fi',
  }) async {
    final uri = Uri.parse('$baseUrl/api/discovery/wifi').replace(
      queryParameters: {
        'interface_alias': interfaceAlias,
      },
    );

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 30));

    return _handleResponse(response);
  }

  // 2. Retrieve approved devices.
  Future<Map<String, dynamic>> fetchTrustedDevices() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/trusted-devices'))
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  // 3. Approve a verified device.
  Future<Map<String, dynamic>> approveDevice({
    required String macAddress,
    required String deviceName,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/trusted-devices'),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'mac_address': macAddress,
            'device_name': deviceName,
          }),
        )
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  // 4. Remove a device from trusted inventory.
  Future<Map<String, dynamic>> removeTrustedDevice(
    String macAddress,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/api/trusted-devices/${Uri.encodeComponent(macAddress)}',
    );

    final response = await _client
        .delete(uri)
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  void dispose() {
    _client.close();
  }
}
