
import 'package:flutter/material.dart';

import '../services/wifi_discovery_api_service.dart';

class WifiDiscoveryPage extends StatefulWidget {
  const WifiDiscoveryPage({super.key});

  @override
  State<WifiDiscoveryPage> createState() => _WifiDiscoveryPageState();
}

class _WifiDiscoveryPageState extends State<WifiDiscoveryPage> {
  late final WifiDiscoveryApiService _api;

  Map<String, dynamic>? _interface;
  Map<String, dynamic>? _summary;

  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _trustedDevices = [];

  // Network inventory and selection.
  List<Map<String, dynamic>> _networks = [];
  List<Map<String, dynamic>> _networkDevices = [];
  List<Map<String, dynamic>> _networkEvents = [];

  Map<String, dynamic>? _currentNetwork;
  Map<String, dynamic>? _selectedNetworkInfo;

  String? _selectedNetworkId;
  String? _networkError;

  DateTime? _lastScan;

  bool _scanning = false;
  bool _loadingTrusted = false;
  bool _loadingNetworks = false;
  bool _loadingNetworkHistory = false;

  int _historyRequestToken = 0;

  String? _error;
  String? _inventoryError;

  final Set<String> _busyMacs = {};

  @override
  void initState() {
    super.initState();

    _api = WifiDiscoveryApiService();

    _refreshAll();
  }

  // Scan the laptop's current network first,
  // then load saved networks and trusted devices.
  Future<void> _refreshAll() async {
    await _scanNetwork();

    if (!mounted) return;

    await Future.wait([
      _loadTrustedDevices(),
      _loadNetworks(),
    ]);
  }

  // Discover devices on the laptop's currently connected network.
  Future<void> _scanNetwork() async {
    if (_scanning) return;

    final previousNetworkId =
        _currentNetwork?['network_id']?.toString();

    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final response = await _api.discoverDevices();

      final rawInterface = response['interface'];
      final rawSummary = response['summary'];
      final rawDevices = response['devices'];
      final rawNetwork = response['network'];

      if (rawInterface is! Map ||
          rawSummary is! Map ||
          rawDevices is! List ||
          rawNetwork is! Map) {
        throw const FormatException(
          'Invalid Wi-Fi discovery response.',
        );
      }

      final interface =
          Map<String, dynamic>.from(rawInterface);

      final summary =
          Map<String, dynamic>.from(rawSummary);

      final currentNetwork =
          Map<String, dynamic>.from(rawNetwork);

      final devices = rawDevices
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      final newNetworkId =
          currentNetwork['network_id']?.toString();

      // If the laptop changes networks, automatically
      // move selection from the old current network
      // to the newly connected network.
      final networkChanged =
          previousNetworkId != null &&
          previousNetworkId != newNetworkId;

      if (!mounted) return;

      setState(() {
        _interface = interface;
        _summary = summary;
        _devices = devices;
        _currentNetwork = currentNetwork;
        _lastScan = DateTime.now();

        if (_selectedNetworkId == null ||
            (networkChanged &&
                _selectedNetworkId == previousNetworkId)) {
          _selectedNetworkId = newNetworkId;
        }
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  // Load locally approved devices.
  Future<void> _loadTrustedDevices() async {
    if (_loadingTrusted) return;

    setState(() {
      _loadingTrusted = true;
      _inventoryError = null;
    });

    try {
      final response = await _api.fetchTrustedDevices();
      final rawDevices = response['devices'];

      if (rawDevices is! List) {
        throw const FormatException(
          'Invalid trusted-device inventory.',
        );
      }

      final devices = rawDevices
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (!mounted) return;

      setState(() {
        _trustedDevices = devices;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _inventoryError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingTrusted = false;
        });
      }
    }
  }

  // Load all previously identified networks.
  Future<void> _loadNetworks() async {
    if (_loadingNetworks) return;

    setState(() {
      _loadingNetworks = true;
      _networkError = null;
    });

    try {
      final response = await _api.fetchNetworks();
      final rawNetworks = response['networks'];

      if (rawNetworks is! List) {
        throw const FormatException(
          'Invalid network inventory response.',
        );
      }

      final networks = rawNetworks
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      final currentId =
          _currentNetwork?['network_id']?.toString();

      final selectedExists = networks.any(
        (network) =>
            network['network_id']?.toString() ==
            _selectedNetworkId,
      );

      final currentExists = networks.any(
        (network) =>
            network['network_id']?.toString() == currentId,
      );

      final String? nextId = selectedExists
          ? _selectedNetworkId
          : currentExists
              ? currentId
              : networks.isNotEmpty
                  ? networks.first['network_id']?.toString()
                  : null;

      if (!mounted) return;

      setState(() {
        _networks = networks;
        _selectedNetworkId = nextId;
      });

      if (nextId != null) {
        await _loadNetworkHistory(nextId);
      } else {
        setState(() {
          _selectedNetworkInfo = null;
          _networkDevices = [];
          _networkEvents = [];
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _networkError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingNetworks = false;
        });
      }
    }
  }

  // Retrieve devices and events for one selected network.
  Future<void> _loadNetworkHistory(String networkId) async {
    if (!mounted) return;

    final requestToken = ++_historyRequestToken;

    setState(() {
      _loadingNetworkHistory = true;
      _networkError = null;
      _selectedNetworkId = networkId;

      // Avoid showing the previous network's history
      // while a new network is loading.
      _selectedNetworkInfo = null;
      _networkDevices = [];
      _networkEvents = [];
    });

    try {
      final results = await Future.wait([
        _api.fetchNetworkDevices(
          networkId: networkId,
        ),
        _api.fetchNetworkEvents(
          networkId: networkId,
        ),
      ]);

      final deviceResponse = results[0];
      final eventResponse = results[1];

      final rawNetwork = deviceResponse['network'];
      final rawDevices = deviceResponse['devices'];
      final rawEvents = eventResponse['events'];

      if (rawNetwork is! Map ||
          rawDevices is! List ||
          rawEvents is! List) {
        throw const FormatException(
          'Invalid network history response.',
        );
      }

      final networkInfo =
          Map<String, dynamic>.from(rawNetwork);

      final devices = rawDevices
          .whereType<Map>()
          .map((item) {
            final record = Map<String, dynamic>.from(item);

            final classification =
                record['last_classification']?.toString() ??
                    'unknown';

            return <String, dynamic>{
              'ip_address':
                  record['last_ip_address'] ?? 'Unavailable',
              'mac_address':
                  record['mac_address'] ?? 'Unavailable',
              'status':
                  record['last_status'] ?? 'unknown',
              'classification': classification,
              'is_gateway': classification == 'gateway',
              'is_trusted': classification == 'trusted',
              'first_seen': record['first_seen'],
              'last_seen': record['last_seen'],
              'sightings': record['sightings'] ?? 0,
              'network_id': networkId,
              'network_name': networkInfo['network_name'],
              'source': 'network_device_history',
            };
          })
          .toList();

      final events = rawEvents
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (!mounted || requestToken != _historyRequestToken) {
        return;
      }

      setState(() {
        _selectedNetworkInfo = networkInfo;
        _networkDevices = devices;
        _networkEvents = events;
      });
    } catch (error) {
      if (!mounted || requestToken != _historyRequestToken) {
        return;
      }

      setState(() {
        _networkError = error.toString();
        _selectedNetworkInfo = null;
        _networkDevices = [];
        _networkEvents = [];
      });
    } finally {
      if (mounted && requestToken == _historyRequestToken) {
        setState(() {
          _loadingNetworkHistory = false;
        });
      }
    }
  }

  // Change the network selected in the dropdown.
  Future<void> _selectNetwork(String? networkId) async {
    if (networkId == null || networkId.isEmpty) return;
    if (networkId == _selectedNetworkId &&
        _selectedNetworkInfo != null) {
      return;
    }

    await _loadNetworkHistory(networkId);
  }

  String _value(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return 'Unavailable';
    }

    return value.toString();
  }

  // Convert backend ISO timestamps to the phone's local time.
  String _formatTimestamp(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return 'Not recorded';
    }

    try {
      final parsed = DateTime.parse(value.toString());
      final local = parsed.toLocal();

      const months = [
        'Jan', 'Feb', 'Mar', 'Apr',
        'May', 'Jun', 'Jul', 'Aug',
        'Sep', 'Oct', 'Nov', 'Dec',
      ];

      final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final period = local.hour >= 12 ? 'PM' : 'AM';

      final day = local.day.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      final second = local.second.toString().padLeft(2, '0');
      final formattedHour = hour.toString().padLeft(2, '0');

      return '$day ${months[local.month - 1]} ${local.year}, '
          '$formattedHour:$minute:$second $period';
    } catch (_) {
      return 'Invalid timestamp';
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'responsive':
        return Colors.green;
      case 'neighbor_cache_only':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Color _classificationColor(String classification) {
    switch (classification.toLowerCase()) {
      case 'gateway':
        return Colors.blue;
      case 'trusted':
        return Colors.green;
      case 'unknown':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'critical':
        return Colors.red;
      case 'warning':
      case 'review':
        return Colors.orange;
      case 'info':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  Future<String?> _requestDeviceName(String ipAddress) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _DeviceNameDialog(
          ipAddress: ipAddress,
        );
      },
    );
  }

  Future<void> _approveDevice(
    Map<String, dynamic> device,
  ) async {
    final mac = _value(device['mac_address']);
    final ip = _value(device['ip_address']);

    if (mac == 'Unavailable') {
      _showMessage('Device MAC address is unavailable.');
      return;
    }

    final name = await _requestDeviceName(ip);

    if (name == null || !mounted) return;

    setState(() {
      _busyMacs.add(mac);
    });

    try {
      final response = await _api.approveDevice(
        macAddress: mac,
        deviceName: name,
      );

      if (!mounted) return;

      _showMessage(
        response['message']?.toString() ??
            'Device approved successfully.',
      );

      await _refreshAll();
    } catch (error) {
      if (!mounted) return;

      _showMessage('Approval failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busyMacs.remove(mac);
        });
      }
    }
  }

  Future<void> _removeTrustedDevice(
    Map<String, dynamic> device,
  ) async {
    final mac = _value(device['mac_address']);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Remove approval?'),
          content: Text(
            'Remove ${device['device_name'] ?? 'this device'} '
            'from the trusted inventory?\n\n'
            'MAC: $mac',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _busyMacs.add(mac);
    });

    try {
      final response = await _api.removeTrustedDevice(mac);

      if (!mounted) return;

      _showMessage(
        response['message']?.toString() ??
            'Device approval removed.',
      );

      await _refreshAll();
    } catch (error) {
      if (!mounted) return;

      _showMessage('Removal failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busyMacs.remove(mac);
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _infoCard(
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
            const SizedBox(height: 10),
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

  Widget _deviceDetail(
    String title,
    String value,
    IconData icon,
  ) {
    return Row(
      children: [
        Icon(icon, size: 17, color: Colors.blueGrey),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // Network selector and selected-network details.
  Widget _networkSelectorSection() {
    final currentId =
        _currentNetwork?['network_id']?.toString();

    final selectedId = _selectedNetworkId;

    final selectedExists = _networks.any(
      (network) =>
          network['network_id']?.toString() == selectedId,
    );

    final isCurrentNetwork =
        selectedId != null && selectedId == currentId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.storage_outlined,
                  color: Colors.blue,
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Network Inventory',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (_loadingNetworks ||
                    _loadingNetworkHistory)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 14),

            DropdownButtonFormField<String>(
              key: ValueKey(selectedId),
              initialValue:
                  selectedExists ? selectedId : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Select a network',
                prefixIcon: Icon(Icons.wifi_find),
                border: OutlineInputBorder(),
              ),
              hint: const Text('Choose a saved network'),
              items: _networks.map((network) {
                final id =
                    network['network_id']?.toString() ?? '';

                final name =
                    network['network_name']?.toString() ??
                        'Unnamed network';

                return DropdownMenuItem<String>(
                  value: id,
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: _loadingNetworkHistory
                  ? null
                  : _selectNetwork,
            ),

            const SizedBox(height: 12),

            if (_networks.isEmpty &&
                !_loadingNetworks)
              const Text(
                'No saved networks found. Scan your current Wi-Fi network first.',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),

            if (_selectedNetworkInfo != null) ...[
              const Divider(height: 24),

              Row(
                children: [
                  Expanded(
                    child: Text(
                      _value(
                        _selectedNetworkInfo!['network_name'],
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isCurrentNetwork
                          ? Colors.green.withValues(alpha: 0.12)
                          : Colors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isCurrentNetwork ? 'CURRENT' : 'SAVED',
                      style: TextStyle(
                        color: isCurrentNetwork
                            ? Colors.green
                            : Colors.blue,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 13),

              _deviceDetail(
                'SSID',
                _value(_selectedNetworkInfo!['ssid']),
                Icons.wifi,
              ),

              const SizedBox(height: 10),

              _deviceDetail(
                'Gateway',
                _value(_selectedNetworkInfo!['gateway']),
                Icons.router_outlined,
              ),

              const SizedBox(height: 10),

              _deviceDetail(
                'Subnet',
                _value(_selectedNetworkInfo!['subnet']),
                Icons.lan_outlined,
              ),

              const SizedBox(height: 10),

              _deviceDetail(
                'Total scans',
                _value(_selectedNetworkInfo!['scan_count']),
                Icons.radar,
              ),
            ],

            if (_networkError != null) ...[
              const SizedBox(height: 12),
              Text(
                _networkError!,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Individual discovered or historically observed device card.
  Widget _deviceCard(
    Map<String, dynamic> device, {
    required bool allowApproval,
  }) {
    final ip = _value(device['ip_address']);
    final mac = _value(device['mac_address']);
    final status = _value(device['status']);
    final classification = _value(device['classification']);

    final firstSeen = _formatTimestamp(device['first_seen']);
    final lastSeen = _formatTimestamp(device['last_seen']);
    final sightings = _value(device['sightings']);

    final isGateway = device['is_gateway'] == true;
    final isTrusted = device['is_trusted'] == true;
    final isBusy = _busyMacs.contains(mac);

    final statusColor = _statusColor(status);
    final classColor = _classificationColor(classification);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      classColor.withValues(alpha: 0.12),
                  child: Icon(
                    isGateway
                        ? Icons.router_outlined
                        : Icons.devices,
                    color: classColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isGateway
                            ? 'Wi-Fi Gateway'
                            : 'Network Device',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        ip,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        classification.toUpperCase(),
                        style: TextStyle(
                          color: classColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        status == 'neighbor_cache_only'
                            ? 'Cache only'
                            : status,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const Divider(height: 25),

            _deviceDetail(
              'IP Address',
              ip,
              Icons.language,
            ),

            const SizedBox(height: 12),

            _deviceDetail(
              'MAC Address',
              mac,
              Icons.fingerprint,
            ),

            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.history,
                        size: 18,
                        color: Colors.blueGrey,
                      ),
                      SizedBox(width: 7),
                      Text(
                        'DEVICE HISTORY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),

                  _deviceDetail(
                    'First Seen',
                    firstSeen,
                    Icons.first_page,
                  ),

                  const SizedBox(height: 11),

                  _deviceDetail(
                    'Last Seen',
                    lastSeen,
                    Icons.access_time,
                  ),

                  const SizedBox(height: 11),

                  _deviceDetail(
                    'Total Sightings',
                    sightings,
                    Icons.visibility_outlined,
                  ),
                ],
              ),
            ),

            if (!allowApproval &&
                !isGateway &&
                classification == 'unknown') ...[
              const SizedBox(height: 10),
              const Text(
                'Historical network: approval is available only while viewing the current network.',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ],

            if (allowApproval &&
                !isGateway &&
                classification == 'unknown') ...[
              const SizedBox(height: 15),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => _approveDevice(device),
                  icon: isBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.verified_user_outlined,
                        ),
                  label: Text(
                    isBusy ? 'Processing...' : 'Approve Device',
                  ),
                ),
              ),
            ],

            if (isTrusted) ...[
              const SizedBox(height: 10),
              const Row(
                children: [
                  Icon(
                    Icons.verified,
                    color: Colors.green,
                    size: 17,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Present in trusted inventory',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Discovery and security event timeline.
  Widget _networkEventsSection() {
    return Card(
      child: ExpansionTile(
        leading: const Icon(
          Icons.notifications_active_outlined,
          color: Colors.blue,
        ),
        title: const Text(
          'Network Events',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${_networkEvents.length} recorded events',
        ),
        children: [
          if (_loadingNetworkHistory)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else if (_networkEvents.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No events recorded for this network.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._networkEvents.map((event) {
              final severity =
                  event['severity']?.toString() ?? 'info';

              final color = _severityColor(severity);

              final message =
                  event['message']?.toString() ??
                      event['event_type']?.toString() ??
                      'Network event';

              final timestamp = _formatTimestamp(
                event['timestamp'] ?? event['occurred_at'],
              );

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      color.withValues(alpha: 0.12),
                  child: Icon(
                    severity == 'critical'
                        ? Icons.error_outline
                        : severity == 'review' ||
                                severity == 'warning'
                            ? Icons.warning_amber_outlined
                            : Icons.info_outline,
                    color: color,
                  ),
                ),
                title: Text(
                  message,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '$severity • $timestamp',
                  style: const TextStyle(fontSize: 11),
                ),
              );
            }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // Locally approved device inventory.
  Widget _trustedInventorySection() {
    return Card(
      child: ExpansionTile(
        leading: const Icon(
          Icons.shield_outlined,
          color: Colors.green,
        ),
        title: const Text(
          'Trusted Device Inventory',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${_trustedDevices.length} approved devices',
        ),
        trailing: const Icon(Icons.expand_more),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            child: Text(
              'This approval inventory is currently shared across networks.',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 11,
              ),
            ),
          ),

          if (_loadingTrusted)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else if (_inventoryError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _inventoryError!,
                style: const TextStyle(color: Colors.red),
              ),
            )
          else if (_trustedDevices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No approved devices yet.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._trustedDevices.map((device) {
              final mac = _value(device['mac_address']);
              final isBusy = _busyMacs.contains(mac);

              return ListTile(
                leading: const CircleAvatar(
                  child: Icon(
                    Icons.verified_user,
                    color: Colors.green,
                  ),
                ),
                title: Text(
                  _value(device['device_name']),
                ),
                subtitle: Text(mac),
                trailing: IconButton(
                  tooltip: 'Remove approval',
                  onPressed: isBusy
                      ? null
                      : () => _removeTrustedDevice(device),
                  icon: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                ),
              );
            }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _summary?['discovered_devices'] ?? 0;
    final responsive = _summary?['responsive_devices'] ?? 0;
    final unknown = _summary?['unknown_devices'] ?? 0;

    final currentId =
        _currentNetwork?['network_id']?.toString();

    final isCurrentSelection =
        _selectedNetworkId != null &&
        _selectedNetworkId == currentId;

    final displayedDevices = _selectedNetworkInfo != null
        ? _networkDevices
        : isCurrentSelection
            ? _devices
            : <Map<String, dynamic>>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi Discovery'),
        actions: [
          IconButton(
            onPressed: _scanning ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh network',
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // Discovery mode banner.
            Card(
              color: Colors.green.withValues(alpha: 0.09),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi,
                      color: Colors.green,
                      size: 25,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'REAL WI-FI DISCOVERY',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Read-only discovery performed by your laptop.',
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Current laptop network.
            Text(
              'Laptop Connection',
              style: Theme.of(context).textTheme.titleLarge,
            ),

            const SizedBox(height: 10),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: Column(
                  children: [
                    _deviceDetail(
                      'Wi-Fi adapter',
                      _value(_interface?['name']),
                      Icons.wifi,
                    ),
                    const SizedBox(height: 12),
                    _deviceDetail(
                      'Connected SSID',
                      _value(_interface?['ssid']),
                      Icons.wifi_tethering,
                    ),
                    const SizedBox(height: 12),
                    _deviceDetail(
                      'Laptop IP',
                      _value(_interface?['ip_address']),
                      Icons.computer,
                    ),
                    const SizedBox(height: 12),
                    _deviceDetail(
                      'Subnet',
                      _value(_interface?['network']),
                      Icons.lan,
                    ),
                    const SizedBox(height: 12),
                    _deviceDetail(
                      'Gateway',
                      _value(_interface?['gateway']),
                      Icons.router,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 18),

            // Saved network selector.
            Text(
              'Select Network',
              style: Theme.of(context).textTheme.titleLarge,
            ),

            const SizedBox(height: 10),

            _networkSelectorSection(),

            const SizedBox(height: 18),

            // Current scan summary.
            Text(
              'Latest Scan Summary',
              style: Theme.of(context).textTheme.titleLarge,
            ),

            const SizedBox(height: 4),

            const Text(
              'These counts refer to the laptop\'s currently connected network.',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 11,
              ),
            ),

            const SizedBox(height: 8),

            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.45,
              children: [
                _infoCard(
                  'Discovered entries',
                  '$total',
                  Icons.devices,
                  Colors.blue,
                ),
                _infoCard(
                  'ICMP responsive',
                  '$responsive',
                  Icons.check_circle_outline,
                  Colors.green,
                ),
                _infoCard(
                  'Unknown devices',
                  '$unknown',
                  Icons.help_outline,
                  Colors.orange,
                ),
                _infoCard(
                  'Trusted devices',
                  '${_trustedDevices.length}',
                  Icons.verified_user,
                  Colors.green,
                ),
              ],
            ),

            const SizedBox(height: 15),

            // Scan only the currently connected network.
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _scanning ? null : _refreshAll,
                icon: _scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.radar),
                label: Text(
                  _scanning
                      ? 'Scanning current network...'
                      : 'Scan Current Wi-Fi Network',
                ),
              ),
            ),

            if (_lastScan != null) ...[
              const SizedBox(height: 10),
              Text(
                'Last scan: '
                '${TimeOfDay.fromDateTime(_lastScan!).format(context)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 11,
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Card(
                color: Colors.red.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Discovery error: $_error',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),
            ],

            if (_networkError != null) ...[
              const SizedBox(height: 12),
              Card(
                color: Colors.red.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Network history error: $_networkError',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Devices belonging to the selected network.
            Text(
              'Devices in Selected Network '
              '(${displayedDevices.length})',
              style: Theme.of(context).textTheme.titleLarge,
            ),

            const SizedBox(height: 10),

            if (_loadingNetworkHistory)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(22),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
              )
            else if (_selectedNetworkInfo == null &&
                _networkDevices.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    _networks.isEmpty
                        ? 'Scan a network to create its inventory.'
                        : 'Select a network to view its history.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (displayedDevices.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'No devices recorded for this network.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ...displayedDevices.map(
                (device) => _deviceCard(
                  device,
                  allowApproval: isCurrentSelection,
                ),
              ),

            const SizedBox(height: 12),

            _networkEventsSection(),

            const SizedBox(height: 12),

            _trustedInventorySection(),

            const SizedBox(height: 12),

            Card(
              color: Colors.orange.withValues(alpha: 0.08),
              child: const Padding(
                padding: EdgeInsets.all(13),
                child: Text(
                  'Security note: Unknown devices are not automatically '
                  'intruders. Verify ownership before approval. Historical '
                  'network data represents previous observations, not '
                  'current device connectivity. This screen does not '
                  'block or disconnect Wi-Fi clients.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// =====================================================
// DEVICE NAME DIALOG
// =====================================================

class _DeviceNameDialog extends StatefulWidget {
  final String ipAddress;

  const _DeviceNameDialog({
    required this.ipAddress,
  });

  @override
  State<_DeviceNameDialog> createState() =>
      _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();

    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Approve device?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Only approve this device after verifying '
              'that it belongs to an authorized user.',
            ),
            const SizedBox(height: 14),
            Text(
              'IP address: ${widget.ipAddress}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Device name',
                hintText: 'Example: Authorized Laptop',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();

            if (name.isEmpty) return;

            Navigator.of(context).pop(name);
          },
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
