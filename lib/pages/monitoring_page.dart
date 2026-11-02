import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../services/telemetry_api_service.dart';
import '../services/wifi_discovery_api_service.dart';

class MonitoringPage extends StatefulWidget {
  const MonitoringPage({super.key});

  @override
  State<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends State<MonitoringPage> {
  late final TelemetryApiService _api;
  late final WifiDiscoveryApiService _trafficApi;

  Timer? _refreshTimer;
  Timer? _trafficRefreshTimer;

  List<Map<String, dynamic>> _records = [];

  Map<String, dynamic> _trafficData = {};

  // Recent traffic measurements restored from SQLite.
  final List<_TrafficSample> _trafficHistory = [];

  static const int _maxTrafficSamples = 60;

  String _selectedDepartment = 'ALL';
  String? _error;
  String? _trafficError;
  String? _trafficStorageError;

  bool _loading = true;
  bool _requestInProgress = false;

  bool _trafficLoading = true;
  bool _trafficRequestInProgress = false;
  bool _trafficHistoryRestored = false;

  DateTime? _lastUpdated;
  DateTime? _trafficLastUpdated;

  // Prevent outdated telemetry responses.
  int _requestVersion = 0;

  static const List<String> _departments = ['ALL', 'CSE', 'ECE', 'IT', 'ADMIN'];

  @override
  void initState() {
    super.initState();

    _api = TelemetryApiService();
    _trafficApi = WifiDiscoveryApiService();

    _loadTelemetry();

    // Restore previously saved traffic before collecting new samples.
    _initializeTrafficHistory();

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadTelemetry(),
    );

    _trafficRefreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _loadNetworkTraffic(),
    );
  }

  // ==========================================
  // CAMPUS TELEMETRY
  // ==========================================

  Future<void> _loadTelemetry({bool force = false}) async {
    if (_requestInProgress && !force) return;

    final currentRequest = ++_requestVersion;
    final requestedDepartment = _selectedDepartment;

    _requestInProgress = true;

    if (mounted) {
      setState(() {});
    }

    try {
      final response = await _api.fetchTelemetry(
        departmentId: requestedDepartment == 'ALL' ? null : requestedDepartment,
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

  // ==========================================
  // RESTORE TRAFFIC HISTORY FROM SQLITE
  // ==========================================

  Future<void> _initializeTrafficHistory() async {
    try {
      final rows = await LocalDatabase.instance.getTrafficHistory(
        interfaceName: 'Wi-Fi',
        limit: _maxTrafficSamples,
      );

      final samples = <_TrafficSample>[];

      for (final row in rows) {
        final time = DateTime.tryParse(row['sampleTime']?.toString() ?? '');

        final download = row['downloadMbps'];
        final upload = row['uploadMbps'];

        if (time != null && download is num && upload is num) {
          samples.add(
            _TrafficSample(
              time: time.toLocal(),
              downloadMbps: download.toDouble(),
              uploadMbps: upload.toDouble(),
            ),
          );
        }
      }

      if (!mounted) return;

      setState(() {
        _trafficHistory
          ..clear()
          ..addAll(samples);

        _trafficStorageError = null;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _trafficStorageError = error.toString();
      });
    }

    if (!mounted) return;

    setState(() {
      _trafficHistoryRestored = true;
    });

    // Start fresh measurements after restoring saved history.
    await _loadNetworkTraffic();
  }

  // ==========================================
  // REAL NETWORK TRAFFIC + SQLITE STORAGE
  // ==========================================

  Future<void> _loadNetworkTraffic() async {
    if (!mounted || !_trafficHistoryRestored || _trafficRequestInProgress) {
      return;
    }

    _trafficRequestInProgress = true;

    try {
      final response = await _trafficApi.fetchNetworkTraffic(
        interfaceAlias: 'Wi-Fi',
      );

      if (!mounted) return;

      final download = response['download_mbps'];
      final upload = response['upload_mbps'];

      _TrafficSample? newSample;
      String? storageError;

      if (response['rate_available'] == true &&
          download is num &&
          upload is num) {
        final sampleTime = DateTime.now();

        newSample = _TrafficSample(
          time: sampleTime,
          downloadMbps: download.toDouble(),
          uploadMbps: upload.toDouble(),
        );

        // Save successful traffic measurements to SQLite.
        try {
          await LocalDatabase.instance.saveTrafficSample(
            interfaceName: response['interface']?.toString() ?? 'Wi-Fi',
            sampleTime: sampleTime,
            downloadMbps: download.toDouble(),
            uploadMbps: upload.toDouble(),
          );
        } catch (error) {
          storageError = error.toString();
        }
      }

      if (!mounted) return;

      setState(() {
        _trafficData = response;
        _trafficError = null;
        _trafficStorageError = storageError;
        _trafficLoading = false;
        _trafficLastUpdated = DateTime.now();

        // Update the graph.
        if (newSample != null) {
          _trafficHistory.add(newSample);

          if (_trafficHistory.length > _maxTrafficSamples) {
            _trafficHistory.removeAt(0);
          }
        }
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _trafficError = error.toString();
        _trafficLoading = false;
      });
    } finally {
      _trafficRequestInProgress = false;
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadTelemetry(force: true), _loadNetworkTraffic()]);
  }

  // ==========================================
  // TELEMETRY CALCULATIONS
  // ==========================================

  double _average(String key) {
    if (_records.isEmpty) return 0;

    final total = _records.fold<double>(
      0,
      (sum, record) => sum + ((record[key] as num?)?.toDouble() ?? 0),
    );

    return total / _records.length;
  }

  void _changeDepartment(String? value) {
    if (value == null || value == _selectedDepartment) return;

    setState(() {
      _selectedDepartment = value;
      _records = [];
      _error = null;
      _loading = true;
      _lastUpdated = null;
    });

    _loadTelemetry(force: true);
  }

  String _formatValue(dynamic value, String suffix) {
    final number = (value as num?)?.toDouble();

    if (number == null) {
      return '--';
    }

    return '${number.toStringAsFixed(2)} $suffix';
  }

  String _readField(Map<String, dynamic> record, String key) {
    final value = record[key]?.toString().trim();

    if (value == null || value.isEmpty || value == 'null') {
      return 'Unavailable';
    }

    return value;
  }

  String _formatTimestamp(DateTime? dateTime) {
    if (dateTime == null) {
      return 'Waiting for measurements';
    }

    return TimeOfDay.fromDateTime(dateTime).format(context);
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

  // ==========================================
  // REUSABLE METRIC CARD
  // ==========================================

  Widget _metricCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
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
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ],
    );
  }

  Widget _chartLegend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ==========================================
  // TRAFFIC HISTORY GRAPH
  // ==========================================

  Widget _buildTrafficHistoryChart() {
    final samples = List<_TrafficSample>.of(_trafficHistory);

    if (!_trafficHistoryRestored || samples.isEmpty) {
      return SizedBox(
        height: 190,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.show_chart, size: 38, color: Colors.grey),
              const SizedBox(height: 10),
              Text(
                _trafficHistoryRestored
                    ? 'Collecting traffic history...'
                    : 'Restoring saved traffic history...',
                style: const TextStyle(color: Colors.grey),
              ),
              if (_trafficStorageError != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Storage: $_trafficStorageError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.orange, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _chartLegend('Download', Colors.blue),
            const SizedBox(width: 20),
            _chartLegend('Upload', Colors.purple),
          ],
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 210,
          width: double.infinity,
          child: CustomPaint(
            painter: _TrafficChartPainter(
              samples: samples,
              gridColor: Colors.grey.withValues(alpha: 0.25),
              labelColor: Colors.grey,
              downloadColor: Colors.blue,
              uploadColor: Colors.purple,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${samples.length} / $_maxTrafficSamples samples',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Text(
              'Refresh interval: 3 seconds',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // LIVE NETWORK TRAFFIC PANEL
  // ==========================================

  Widget _buildLiveTrafficCard() {
    final download = _trafficData['download_mbps'] as num?;
    final upload = _trafficData['upload_mbps'] as num?;

    final rateAvailable = _trafficData['rate_available'] == true;

    final receivedPackets = _trafficData['packets_received_total'] ?? '--';

    final sentPackets = _trafficData['packets_sent_total'] ?? '--';

    final errorsReceived = _trafficData['errors_received'] ?? 0;

    final errorsSent = _trafficData['errors_sent'] ?? 0;

    final droppedIn = _trafficData['packets_dropped_in'] ?? 0;

    final droppedOut = _trafficData['packets_dropped_out'] ?? 0;

    String speed(num? value) {
      if (!rateAvailable || value == null) {
        return 'Sampling...';
      }

      return '${value.toStringAsFixed(4)} Mbps';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi, color: Colors.green, size: 25),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Live Laptop Wi-Fi Traffic',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 6),

            Text(
              'Interface: ${_trafficData['interface'] ?? 'Wi-Fi'}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),

            const SizedBox(height: 4),

            Text(
              'Updated: ${_formatTimestamp(_trafficLastUpdated)}',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: _metricCard(
                    'Download',
                    speed(download),
                    Icons.download,
                    Colors.blue,
                  ),
                ),
                Expanded(
                  child: _metricCard(
                    'Upload',
                    speed(upload),
                    Icons.upload,
                    Colors.purple,
                  ),
                ),
              ],
            ),

            const Divider(height: 28),

            const Text(
              'Traffic History',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 16),

            _buildTrafficHistoryChart(),

            const Divider(height: 28),

            const Text(
              'Packet Statistics',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: _smallMetric(
                    'Received packets',
                    receivedPackets.toString(),
                  ),
                ),
                Expanded(
                  child: _smallMetric('Sent packets', sentPackets.toString()),
                ),
              ],
            ),

            const SizedBox(height: 18),

            const Text(
              'Network Health',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: _smallMetric(
                    'Receive errors',
                    errorsReceived.toString(),
                  ),
                ),
                Expanded(
                  child: _smallMetric('Send errors', errorsSent.toString()),
                ),
              ],
            ),

            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: _smallMetric('Dropped incoming', droppedIn.toString()),
                ),
                Expanded(
                  child: _smallMetric(
                    'Dropped outgoing',
                    droppedOut.toString(),
                  ),
                ),
              ],
            ),

            if (_trafficLoading) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
            ],

            if (_trafficError != null) ...[
              const SizedBox(height: 14),
              Text(
                'Traffic error: $_trafficError',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
              TextButton.icon(
                onPressed: _trafficRequestInProgress
                    ? null
                    : _loadNetworkTraffic,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry traffic request'),
              ),
            ],

            if (_trafficStorageError != null) ...[
              const SizedBox(height: 10),
              Text(
                'History storage error: $_trafficStorageError',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],

            if (!rateAvailable &&
                !_trafficLoading &&
                _trafficError == null) ...[
              const SizedBox(height: 14),
              const Text(
                'Waiting for another sample to calculate speed.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],

            const SizedBox(height: 14),

            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 17, color: Colors.blueGrey),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'These are real measurements from your laptop '
                      'Wi-Fi interface. They do not represent '
                      'individual traffic from every device '
                      'connected to the network.',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // INDIVIDUAL DEVICE TELEMETRY
  // ==========================================

  Widget _deviceCard(Map<String, dynamic> record) {
    final status = _readField(record, 'status');
    final statusColor = _statusColor(status);

    final deviceName = _readField(record, 'device_name');
    final department = _readField(record, 'department_id');
    final deviceType = _readField(record, 'device_type');

    final ipAddress = _readField(record, 'ip_address');
    final macAddress = _readField(record, 'mac_address');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices, color: Colors.blue, size: 24),
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

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.language, size: 16, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text(
                        'IP Address',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
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
                        style: TextStyle(color: Colors.grey, fontSize: 11),
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

            Row(
              children: [
                Expanded(
                  child: _smallMetric(
                    'RX',
                    _formatValue(record['bandwidth_rx_mbps'], 'Mbps'),
                  ),
                ),
                Expanded(
                  child: _smallMetric(
                    'TX',
                    _formatValue(record['bandwidth_tx_mbps'], 'Mbps'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

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
                    _formatValue(record['packet_loss_percent'], '%'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // DISPOSE
  // ==========================================

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _trafficRefreshTimer?.cancel();

    _requestVersion++;

    _api.dispose();
    _trafficApi.dispose();

    super.dispose();
  }

  // ==========================================
  // USER INTERFACE
  // ==========================================

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
            onPressed: _requestInProgress || _trafficRequestInProgress
                ? null
                : _refreshAll,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh measurements',
          ),
        ],
      ),

      body: _loading && _records.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  // Simulated campus telemetry warning.
                  Card(
                    color: Colors.orange.withValues(alpha: 0.10),
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(Icons.science_outlined, color: Colors.orange),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'SIMULATED CAMPUS TELEMETRY • '
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

                  // Real laptop Wi-Fi monitoring.
                  _buildLiveTrafficCard(),

                  const SizedBox(height: 20),

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
                          'Campus data updated: '
                          '${_formatTimestamp(_lastUpdated)}',
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Campus telemetry error: $_error',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],

                  const SizedBox(height: 18),

                  Text(
                    'Campus Network Performance',
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

// ==========================================
// TRAFFIC SAMPLE MODEL
// ==========================================

class _TrafficSample {
  final DateTime time;
  final double downloadMbps;
  final double uploadMbps;

  const _TrafficSample({
    required this.time,
    required this.downloadMbps,
    required this.uploadMbps,
  });
}

// ==========================================
// CUSTOM TRAFFIC GRAPH PAINTER
// ==========================================

class _TrafficChartPainter extends CustomPainter {
  final List<_TrafficSample> samples;

  final Color gridColor;
  final Color labelColor;
  final Color downloadColor;
  final Color uploadColor;

  _TrafficChartPainter({
    required this.samples,
    required this.gridColor,
    required this.labelColor,
    required this.downloadColor,
    required this.uploadColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 60 || size.height < 50) return;

    const left = 43.0;
    const right = 9.0;
    const top = 10.0;
    const bottomMargin = 25.0;

    final plotWidth = size.width - left - right;
    final plotHeight = size.height - top - bottomMargin;
    final plotBottom = top + plotHeight;

    if (plotWidth <= 0 || plotHeight <= 0) return;

    final maxSpeed = samples.fold<double>(
      0,
      (currentMax, sample) => math.max(
        currentMax,
        math.max(sample.downloadMbps, sample.uploadMbps),
      ),
    );

    final scaleMax = maxSpeed <= 0 ? 0.1 : maxSpeed * 1.2;

    // Draw horizontal grid lines and Y-axis labels.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (int i = 0; i <= 3; i++) {
      final fraction = i / 3;
      final y = top + plotHeight * fraction;

      canvas.drawLine(Offset(left, y), Offset(left + plotWidth, y), gridPaint);

      final value = scaleMax * (1 - fraction);

      final textPainter = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(2),
          style: TextStyle(color: labelColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      );

      textPainter.layout(maxWidth: left - 5);

      textPainter.paint(
        canvas,
        Offset(left - textPainter.width - 7, y - textPainter.height / 2),
      );
    }

    // Oldest label.
    final oldestLabel = TextPainter(
      text: TextSpan(
        text: 'Oldest',
        style: TextStyle(color: labelColor, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    );

    oldestLabel.layout();

    oldestLabel.paint(canvas, Offset(left, plotBottom + 7));

    // Latest label.
    final latestLabel = TextPainter(
      text: TextSpan(
        text: 'Latest',
        style: TextStyle(color: labelColor, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    );

    latestLabel.layout();

    latestLabel.paint(
      canvas,
      Offset(left + plotWidth - latestLabel.width, plotBottom + 7),
    );

    // Convert a traffic speed into graph coordinates.
    Offset pointFor(int index, double value) {
      final x = samples.length == 1
          ? left + plotWidth / 2
          : left + (index / (samples.length - 1)) * plotWidth;

      final safeValue = value < 0 ? 0.0 : value;

      final y = plotBottom - (safeValue / scaleMax) * plotHeight;

      return Offset(x, y);
    }

    final downloadPaint = Paint()
      ..color = downloadColor
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final uploadPaint = Paint()
      ..color = uploadColor
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final downloadPath = Path();
    final uploadPath = Path();

    for (int i = 0; i < samples.length; i++) {
      final downloadPoint = pointFor(i, samples[i].downloadMbps);

      final uploadPoint = pointFor(i, samples[i].uploadMbps);

      if (i == 0) {
        downloadPath.moveTo(downloadPoint.dx, downloadPoint.dy);

        uploadPath.moveTo(uploadPoint.dx, uploadPoint.dy);
      } else {
        downloadPath.lineTo(downloadPoint.dx, downloadPoint.dy);

        uploadPath.lineTo(uploadPoint.dx, uploadPoint.dy);
      }
    }

    if (samples.length > 1) {
      canvas.drawPath(downloadPath, downloadPaint);
      canvas.drawPath(uploadPath, uploadPaint);
    }

    // Draw the latest sample points.
    if (samples.isNotEmpty) {
      final lastIndex = samples.length - 1;

      final latestDownload = pointFor(
        lastIndex,
        samples[lastIndex].downloadMbps,
      );

      final latestUpload = pointFor(lastIndex, samples[lastIndex].uploadMbps);

      canvas.drawCircle(latestDownload, 4, Paint()..color = downloadColor);

      canvas.drawCircle(latestUpload, 4, Paint()..color = uploadColor);
    }
  }

  @override
  bool shouldRepaint(covariant _TrafficChartPainter oldDelegate) {
    return true;
  }
}
