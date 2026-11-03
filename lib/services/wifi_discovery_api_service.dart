import 'dart:convert';

import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class WifiDiscoveryApiService {
  static const String baseUrl = ApiConfig.baseUrl;

  final http.Client _client;

  WifiDiscoveryApiService({http.Client? client})
    : _client = client ?? http.Client();

  // Handle API responses.
  Future<Map<String, dynamic>> _handleResponse(http.Response response) async {
    final dynamic decoded;

    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Server returned an invalid response.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['detail']?.toString() : null;

      throw Exception(message ?? 'API request failed: ${response.statusCode}');
    }

    if (decoded is! Map) {
      throw const FormatException('Invalid API response.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  // Reusable GET request.

  Future<Map<String, dynamic>> _get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final response = await _client.get(uri).timeout(timeout);
    return _handleResponse(response);
  }

  // Fetch real-time network traffic from the laptop.
  Future<Map<String, dynamic>> fetchNetworkTraffic({
    String interfaceAlias = 'Wi-Fi',
  }) async {
    final uri = Uri.parse(
      '$baseUrl/api/telemetry/network',
    ).replace(queryParameters: {'interface_alias': interfaceAlias});

    return _get(uri, timeout: const Duration(seconds: 15));
  }

  // Current network monitor status.
  Future<Map<String, dynamic>> fetchMonitorStatus() async {
    final uri = Uri.parse('$baseUrl/api/network-monitor/status');

    return _get(uri, timeout: const Duration(seconds: 15));
  }

  // Discover actual Wi-Fi devices through the laptop.

  Future<Map<String, dynamic>> discoverDevices({
    String interfaceAlias = 'Wi-Fi',
    String scanMode = 'quick',
  }) async {
    final normalizedMode = scanMode.trim().toLowerCase();

    if (normalizedMode != 'quick' && normalizedMode != 'extended') {
      throw ArgumentError('scanMode must be quick or extended.');
    }

    final uri = Uri.parse('$baseUrl/api/discovery/wifi').replace(
      queryParameters: {
        'interface_alias': interfaceAlias,
        'scan_mode': normalizedMode,
      },
    );

    return _get(uri, timeout: const Duration(seconds: 90));
  }

  // Retrieve all known networks.
  Future<Map<String, dynamic>> fetchNetworks() async {
    return _get(Uri.parse('$baseUrl/api/networks'));
  }

  // Retrieve devices belonging to one network.
  Future<Map<String, dynamic>> fetchNetworkDevices({
    required String networkId,
    int limit = 100,
  }) async {
    final id = networkId.trim();

    if (id.isEmpty) {
      throw ArgumentError('Network ID cannot be empty.');
    }

    if (limit < 1 || limit > 500) {
      throw ArgumentError('Limit must be between 1 and 500.');
    }

    final uri = Uri.parse(
      '$baseUrl/api/history/devices',
    ).replace(queryParameters: {'network_id': id, 'limit': limit.toString()});

    return _get(uri);
  }

  // Retrieve events belonging to one network.
  Future<Map<String, dynamic>> fetchNetworkEvents({
    required String networkId,
    int limit = 100,
  }) async {
    final id = networkId.trim();

    if (id.isEmpty) {
      throw ArgumentError('Network ID cannot be empty.');
    }

    if (limit < 1 || limit > 500) {
      throw ArgumentError('Limit must be between 1 and 500.');
    }

    final uri = Uri.parse(
      '$baseUrl/api/history/events',
    ).replace(queryParameters: {'network_id': id, 'limit': limit.toString()});

    return _get(uri);
  }

  // Retrieve locally approved devices for the current network.
  Future<Map<String, dynamic>> fetchTrustedDevices() async {
    return _get(Uri.parse('$baseUrl/api/trusted-devices'));
  }

  // Approve a verified device.
  Future<Map<String, dynamic>> approveDevice({
    required String macAddress,
    required String deviceName,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/trusted-devices'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'mac_address': macAddress,
            'device_name': deviceName,
          }),
        )
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  // Remove a device from trusted inventory.
  Future<Map<String, dynamic>> removeTrustedDevice(String macAddress) async {
    final uri = Uri.parse(
      '$baseUrl/api/trusted-devices/'
      '${Uri.encodeComponent(macAddress)}',
    );

    final response = await _client
        .delete(uri)
        .timeout(const Duration(seconds: 15));

    return _handleResponse(response);
  }

  // Close the HTTP client when no longer needed.
  void dispose() {
    _client.close();
  }
}
