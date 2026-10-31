
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/telemetry_api_service.dart';

class MonitoringPage extends StatefulWidget {
  const MonitoringPage({super.key});

  @override
  State<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends State<MonitoringPage> {
  late final TelemetryApiService _api;

  Timer? _refreshTimer;

  List<Map<String, dynamic>> _records = [];

  String _selectedDepartment = 'ALL';
  String? _error;

  bool _loading = true;
  bool _requestInProgress = false;

  DateTime? _lastUpdated;

  // Used to prevent outdated API responses from replacing newer data.
  int _requestVersion = 0;

  static const List<String> _departments = [
    'ALL',
    'CSE',
    'ECE',
    'IT',
    'ADMIN',
  ];

  @override
  void initState() {
    super.initState();

    _api = TelemetryApiService();

    _loadTelemetry();

    // Refresh simulated telemetry every five seconds.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadTelemetry(),
    );
  }

  // Fetch telemetry from FastAPI.
  Future<void> _loadTelemetry({bool force = false}) async {
    // Skip automatic refresh if another request is running.
    // Forced requests are used for department changes and manual refresh.
    if (_requestInProgress && !force) return;

    final currentRequest = ++_requestVersion;
    final requestedDepartment = _selectedDepartment;

    _requestInProgress = true;

    if (mounted) {
      setState(() {});
    }

    try {
      final response = await _api.fetchTelemetry(
        departmentId: requestedDepartment == 'ALL'
            ? null
            : requestedDepartment,
      );

      final rawRecords = response['telemetry'];

      if (rawRecords is! List) {
        throw const FormatException(
          'Invalid telemetry records received from server.',
        );
      }

      final records = rawRecords
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      // Ignore outdated requests.
      if (!mounted ||
          currentRequest != _requestVersion ||
          requestedDepartment != _selectedDepartment) {
        return;
      }

      setState(() {
        _records = records;
        _error = null;
        _loading = false;
        _lastUpdated = DateTime.now();
      });
    } catch (error) {
      if (!mounted || currentRequest != _requestVersion) {
        return;
      }

      setState(() {
        _error = error.toString();
        _loading = false;
      });
    } finally {
      if (mounted && currentRequest == _requestVersion) {
        setState(() {
          _requestInProgress = false;
        });
      }
    }
  }

  // Calculate average telemetry values.
  double _average(String key) {
    if (_records.isEmpty) return 0;

    final total = _records.fold<double>(
      0,
      (sum, record) =>
          sum + ((record[key] as num?)?.toDouble() ?? 0),
    );

    return total / _records.length;
  }

  // Change the selected department.
  void _changeDepartment(String? value) {
    if (value == null || value == _selectedDepartment) return;

    setState(() {
      _selectedDepartment = value;
      _records = [];
      _error = null;
      _loading = true;
      _lastUpdated = null;
    });

    // Force a new request even if the previous request is running.
    _loadTelemetry(force: true);
  }

  // Safely format numeric values.
  String _formatValue(dynamic value, String suffix) {
    final number = (value as num?)?.toDouble();

    if (number == null) {
      return '--';
    }

    return '${number.toStringAsFixed(2)} $suffix';
  }

  // Safely read device information.
  String _readField(
    Map<String, dynamic> record,
    String key,
  ) {
    final value = record[key]?.toString().trim();

    if (value == null || value.isEmpty || value == 'null') {
      return 'Unavailable';
    }

    return value;
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'online':
      case 'healthy':
        return Colors.green;

      case 'offline':
      case 'failed':
        return Colors.red;

      default:
        return Colors.orange;
    }
  }

  // Reusable performance metric card.
  Widget _metricCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Individual device telemetry card.
  Widget _deviceCard(Map<String, dynamic> record) {
    final status = _readField(record, 'status');
    final statusColor = _statusColor(status);

    final deviceName = _readField(record, 'device_name');
    final department = _readField(record, 'department_id');
    final deviceType = _readField(record, 'device_type');

    // These are the campus device addresses, not the API address.
    final ipAddress = _readField(record, 'ip_address');
    final macAddress = _readField(record, 'mac_address');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device heading.
            Row(
              children: [
                const Icon(
                  Icons.devices,
                  color: Colors.blue,
                  size: 24,
                ),
                const SizedBox(width: 10),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),

                      const SizedBox(height: 3),

                      Text(
                        '$department • $deviceType',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),

                Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Device IP and MAC address.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
              ),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.language,
                        size: 16,
                        color: Colors.blue,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'IP Address',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          ipAddress,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  Row(
                    children: [
                      const Icon(
                        Icons.fingerprint,
                        size: 16,
                        color: Colors.blueGrey,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'MAC Address',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          macAddress,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            // RX and TX.
            Row(
              children: [
                Expanded(
                  child: _smallMetric(
                    'RX',
                    _formatValue(
                      record['bandwidth_rx_mbps'],
                      'Mbps',
                    ),
                  ),
                ),
                Expanded(
                  child: _smallMetric(
                    'TX',
                    _formatValue(
                      record['bandwidth_tx_mbps'],
                      'Mbps',
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Latency and packet loss.
            Row(
              children: [
                Expanded(
                  child: _smallMetric(
                    'Latency',
                    _formatValue(record['latency_ms'], 'ms'),
                  ),
                ),
                Expanded(
                  child: _smallMetric(
                    'Packet loss',
                    _formatValue(
                      record['packet_loss_percent'],
                      '%',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _requestVersion++;

    _api.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final averageRx = _average('bandwidth_rx_mbps');
    final averageTx = _average('bandwidth_tx_mbps');
    final averageLatency = _average('latency_ms');
    final averagePacketLoss = _average('packet_loss_percent');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Network Monitoring'),
        actions: [
          IconButton(
            onPressed: _requestInProgress
                ? null
                : () => _loadTelemetry(force: true),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh measurements',
          ),
        ],
      ),

      body: _loading && _records.isEmpty
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: () => _loadTelemetry(force: true),

              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),

                children: [
                  // Simulated data warning.
                  Card(
                    color: Colors.orange.withValues(alpha: 0.10),
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(
                            Icons.science_outlined,
                            color: Colors.orange,
                          ),
                          SizedBox(width: 10),

                          Expanded(
                            child: Text(
                              'SIMULATED TELEMETRY • '
                              'Not live network measurements',
                              style: TextStyle(
                                color: Colors.orange,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Department dropdown.
                  DropdownButtonFormField<String>(
                    initialValue: _selectedDepartment,

                    decoration: const InputDecoration(
                      labelText: 'Select department',
                      prefixIcon: Icon(Icons.apartment),
                      border: OutlineInputBorder(),
                    ),

                    items: _departments.map((department) {
                      final label = department == 'ALL'
                          ? 'All Departments'
                          : department;

                      return DropdownMenuItem<String>(
                        value: department,
                        child: Text(label),
                      );
                    }).toList(),

                    onChanged: _changeDepartment,
                  ),

                  const SizedBox(height: 16),

                  // Last update information.
                  Row(
                    children: [
                      const Icon(
                        Icons.autorenew,
                        size: 16,
                        color: Colors.green,
                      ),

                      const SizedBox(width: 6),

                      Expanded(
                        child: Text(
                          _lastUpdated == null
                              ? 'Waiting for measurements'
                              : 'Last updated: '
                                  '${TimeOfDay.fromDateTime(
                                    _lastUpdated!,
                                  ).format(context)}',

                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ),

                      if (_requestInProgress)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                    ],
                  ),

                  // API error.
                  if (_error != null) ...[
                    const SizedBox(height: 12),

                    Text(
                      'Refresh error: $_error',
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ],

                  const SizedBox(height: 18),

                  // Performance summary.
                  Text(
                    'Network Performance',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),

                  const SizedBox(height: 8),

                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 1.35,

                    children: [
                      _metricCard(
                        'Average RX',
                        '${averageRx.toStringAsFixed(2)} Mbps',
                        Icons.download,
                        Colors.blue,
                      ),

                      _metricCard(
                        'Average TX',
                        '${averageTx.toStringAsFixed(2)} Mbps',
                        Icons.upload,
                        Colors.purple,
                      ),

                      _metricCard(
                        'Average latency',
                        '${averageLatency.toStringAsFixed(2)} ms',
                        Icons.timer_outlined,
                        Colors.green,
                      ),

                      _metricCard(
                        'Average packet loss',
                        '${averagePacketLoss.toStringAsFixed(2)}%',
                        Icons.warning_amber,
                        Colors.orange,
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // Device count.
                  Text(
                    'Monitored Devices (${_records.length})',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),

                  const SizedBox(height: 10),

                  if (_records.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'No telemetry records available.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    ..._records.map(_deviceCard),
                ],
              ),
            ),
    );
  }
}
