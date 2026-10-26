
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'database/local_database.dart';

void main() {
  runApp(const TwinGuardApp());
}

const primaryBlue = Color(0xFF246BFD);
const backgroundColor = Color(0xFFF4F7FC);
const darkText = Color(0xFF18243A);
const mutedText = Color(0xFF778399);
const successColor = Color(0xFF15966B);
const dangerColor = Color(0xFFD9485F);
const warningColor = Color(0xFFE59B25);

class TwinGuardApp extends StatelessWidget {
  const TwinGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TwinGuard Edge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(seedColor: primaryBlue),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: darkText,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE8EDF5)),
          ),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int selectedTab = 0;
  late Future<List<Map<String, dynamic>>> devicesFuture;
  final Set<int> checkingDevices = {};

  @override
  void initState() {
    super.initState();
    _reloadDevices();
  }

  void _reloadDevices() {
    devicesFuture = LocalDatabase.instance.getDevices();
  }

  Future<void> _refreshDevices() async {
    setState(_reloadDevices);
    await devicesFuture;
  }

  void _message(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String> _checkReachability(String host) async {
    const ports = [80, 443, 22];
    var connectionRefused = false;

    if (host.trim().isEmpty) return 'Unknown';

    for (final port in ports) {
      Socket? socket;

      try {
        socket = await Socket.connect(
          host.trim(),
          port,
          timeout: const Duration(seconds: 2),
        );
        return 'Online';
      } on SocketException catch (error) {
        final code = error.osError?.errorCode;
        if (code == 111 || code == 10061) {
          connectionRefused = true;
        }
      } on ArgumentError {
        return 'Unknown';
      } catch (_) {
        // Try the next port.
      } finally {
        socket?.destroy();
      }
    }

    return connectionRefused ? 'Service Unavailable' : 'Unknown';
  }

  Future<void> _checkDevice(Map<String, dynamic> device) async {
    final id = device['id'] as int;
    final host = '${device['ipAddress'] ?? ''}'.trim();

    if (host.isEmpty) {
      _message('Enter an IP address or hostname first.');
      return;
    }

    setState(() => checkingDevices.add(id));

    try {
      final status = await _checkReachability(host);
      await LocalDatabase.instance.updateDeviceStatus(id, status);

      if (!mounted) return;

      setState(_reloadDevices);
      _message('${device['name']}: $status');
    } catch (error) {
      _message('Check failed: $error');
    } finally {
      if (mounted) {
        setState(() => checkingDevices.remove(id));
      }
    }
  }

  Future<void> _checkAll(List<Map<String, dynamic>> devices) async {
    if (devices.isEmpty) {
      _message('Add a device first.');
      return;
    }

    for (final device in devices) {
      if (!mounted) return;
      await _checkDevice(device);
    }
  }

  Future<void> _addDevice() async {
    final nameController = TextEditingController();
    final ipController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    String type = 'Router';
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Network Device'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
                      hintText: 'Core Router',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty
                            ? 'Enter a device name'
                            : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: 'Device type',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      'Router',
                      'Switch',
                      'PC',
                      'Server',
                      'Database',
                      'Firewall',
                      'Access Point',
                      'Other',
                    ]
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item,
                            child: Text(item),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => type = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: ipController,
                    decoration: const InputDecoration(
                      labelText: 'IP address or hostname',
                      hintText: '192.168.1.1',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty
                            ? 'Enter an address'
                            : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;

                      setDialogState(() => saving = true);

                      try {
                        await LocalDatabase.instance.addDevice(
                          name: nameController.text.trim(),
                          type: type,
                          ipAddress: ipController.text.trim(),
                        );

                        if (!mounted || !dialogContext.mounted) return;

                        Navigator.pop(dialogContext);
                        setState(_reloadDevices);
                        _message('Device saved locally.');
                      } catch (error) {
                        if (!dialogContext.mounted) return;

                        setDialogState(() => saving = false);
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(
                            content: Text('Could not save device: $error'),
                          ),
                        );
                      }
                    },
              child: saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save Device'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    ipController.dispose();
  }

  Future<void> _deleteDevice(Map<String, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete device?'),
        content: Text('Remove ${device['name']} from your inventory?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    try {
      await LocalDatabase.instance.deleteDevice(device['id'] as int);
      if (!mounted) return;

      setState(_reloadDevices);
      _message('Device deleted.');
    } catch (error) {
      _message('Could not delete device: $error');
    }
  }

  Future<void> _manualStatus(Map<String, dynamic> device) async {
    final status = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Set status manually'),
        children: [
          'Online',
          'Offline',
          'Unknown',
          'Unreachable',
          'Service Unavailable',
        ]
            .map(
              (item) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item),
                child: Text(item),
              ),
            )
            .toList(),
      ),
    );

    if (!mounted || status == null) return;

    try {
      await LocalDatabase.instance.updateDeviceStatus(
        device['id'] as int,
        status,
      );

      if (!mounted) return;

      setState(_reloadDevices);
      _message('Status updated.');
    } catch (error) {
      _message('Could not update status: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _dashboard(),
      _network(),
      _simulation(),
      _settings(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: primaryBlue, size: 32),
            SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TwinGuard Edge',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'INFRASTRUCTURE INTELLIGENCE',
                  style: TextStyle(fontSize: 9, color: mutedText),
                ),
              ],
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: selectedTab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: (index) {
          setState(() {
            selectedTab = index;
            _reloadDevices();
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: 'Network',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt),
            label: 'Simulate',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _dashboard() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: devicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Database error: ${snapshot.error}'));
        }

        final devices = snapshot.data ?? [];
        final online = devices.where((d) => d['status'] == 'Online').length;
        final unavailable = devices
            .where((d) => d['status'] == 'Service Unavailable')
            .length;
        final unconfirmed = devices.where((d) {
          final status = d['status'];
          return status != 'Online' &&
              status != 'Offline' &&
              status != 'Service Unavailable';
        }).length;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFF246BFD), Color(0xFF6247E5)],
                ),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_moon_outlined,
                    color: Colors.white,
                    size: 34,
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Your infrastructure, understood.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Manage inventory, check services, and simulate '
                    'potential infrastructure failures.',
                    style: TextStyle(color: Colors.white70, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const _Heading('Infrastructure Overview'),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: [
                _Metric(
                  'Total Devices',
                  '${devices.length}',
                  Icons.devices,
                  primaryBlue,
                ),
                _Metric(
                  'Reachable',
                  '$online',
                  Icons.check_circle_outline,
                  successColor,
                ),
                _Metric(
                  'Service Unavailable',
                  '$unavailable',
                  Icons.portable_wifi_off,
                  dangerColor,
                ),
                _Metric(
                  'Unconfirmed',
                  '$unconfirmed',
                  Icons.help_outline,
                  warningColor,
                ),
              ],
            ),
            const SizedBox(height: 22),
            _Heading(
              'Saved Infrastructure',
              trailing: TextButton(
                onPressed: () => setState(() => selectedTab = 1),
                child: const Text('View devices'),
              ),
            ),
            const SizedBox(height: 10),
            if (devices.isEmpty)
              const _Notice(
                text: 'No devices have been added. Open Network to add '
                    'routers, switches, PCs, servers, and databases.',
              )
            else
              ...devices.take(5).map(
                    (device) => Card(
                      child: ListTile(
                        leading: Icon(
                          _deviceIcon('${device['type']}'),
                          color: primaryBlue,
                        ),
                        title: Text('${device['name']}'),
                        subtitle: Text(
                          '${device['type']} • ${device['ipAddress']}',
                        ),
                        trailing: _StatusBadge(
                          status: '${device['status'] ?? 'Unknown'}',
                        ),
                      ),
                    ),
                  ),
            const _Notice(
              text: 'TCP checks test ports 80, 443, and 22 only. An '
                  'inconclusive check does not prove that a device is offline.',
            ),
          ],
        );
      },
    );
  }

  Widget _network() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: devicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Could not load devices: ${snapshot.error}'));
        }

        final devices = snapshot.data ?? [];

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Network Inventory',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.bold,
                      color: darkText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Manage and check your saved devices',
                    style: TextStyle(color: mutedText),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _addDevice,
                          icon: const Icon(Icons.add),
                          label: const Text('Add Device'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Refresh inventory',
                        onPressed: _refreshDevices,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          devices.isEmpty ? null : () => _checkAll(devices),
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Check All Devices'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: devices.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No devices added yet.\nAdd a router, switch, PC, '
                          'server, or database to begin.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      itemCount: devices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final id = device['id'] as int;
                        final checking = checkingDevices.contains(id);
                        final status =
                            '${device['status'] ?? 'Unknown'}';

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _deviceIcon('${device['type']}'),
                                      color: primaryBlue,
                                      size: 30,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${device['name']}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${device['type']} • '
                                            '${device['ipAddress']}',
                                            style: const TextStyle(
                                              color: mutedText,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      onSelected: (value) {
                                        if (value == 'status') {
                                          _manualStatus(device);
                                        } else if (value == 'delete') {
                                          _deleteDevice(device);
                                        }
                                      },
                                      itemBuilder: (context) => const [
                                        PopupMenuItem(
                                          value: 'status',
                                          child: Text('Set status manually'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete device'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Flexible(
                                      child: _StatusBadge(status: status),
                                    ),
                                    const Spacer(),
                                    if (checking)
                                      const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else
                                      TextButton.icon(
                                        onPressed: () => _checkDevice(device),
                                        icon: const Icon(
                                          Icons.wifi_tethering,
                                          size: 18,
                                        ),
                                        label: const Text('Check status'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _simulation() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: devicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Could not load devices: ${snapshot.error}'));
        }

        return _FailureSimulation(
          devices: snapshot.data ?? [],
        );
      },
    );
  }

  Widget _settings() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.bold,
            color: darkText,
          ),
        ),
        const SizedBox(height: 14),
        const Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.storage_outlined, color: successColor),
                title: Text('Local database'),
                subtitle: Text('SQLite device inventory'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.network_check, color: primaryBlue),
                title: Text('TCP service checks'),
                subtitle: Text('Ports 80, 443, and 22'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.cloud_off_outlined, color: warningColor),
                title: Text('Offline-first'),
                subtitle: Text('Inventory is stored locally'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.hub_outlined),
                title: Text('Topology awareness'),
                subtitle: Text(
                  'Actual device-to-device connections are not configured',
                ),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.psychology_outlined),
                title: Text('Prediction engine'),
                subtitle: Text(
                  'Rule-based simulation; machine learning is not implemented',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _Notice(
          text: 'Physical link-state verification requires suitable network '
              'telemetry. Advanced prediction and automatic monitoring are '
              'not implemented yet.',
        ),
      ],
    );
  }
}

class _FailureSimulation extends StatefulWidget {
  final List<Map<String, dynamic>> devices;

  const _FailureSimulation({
    required this.devices,
  });

  @override
  State<_FailureSimulation> createState() => _FailureSimulationState();
}

class _FailureSimulationState extends State<_FailureSimulation> {
  int? selectedDeviceId;
  bool simulated = false;
  String scenario = 'Device failure';
  String? report;
  DateTime? reportTime;

  Map<String, dynamic>? get selectedDevice {
    for (final device in widget.devices) {
      if (device['id'] == selectedDeviceId) return device;
    }
    return null;
  }

  List<Map<String, dynamic>> get potentiallyAffected {
    final selected = selectedDevice;
    if (selected == null) return [];

    return widget.devices
        .where((device) => device['id'] != selected['id'])
        .toList();
  }

  String get severity {
    final type = '${selectedDevice?['type'] ?? ''}'.toLowerCase();

    if (type.contains('router') ||
        type.contains('switch') ||
        type.contains('firewall')) {
      return 'Potentially High';
    }

    if (type.contains('server') || type.contains('database')) {
      return 'Potentially Medium to High';
    }

    return 'Potentially Localized';
  }

  IconData get scenarioIcon {
    switch (scenario) {
      case 'Service failure':
        return Icons.portable_wifi_off;
      case 'Performance degradation':
        return Icons.speed;
      default:
        return Icons.power_settings_new;
    }
  }

  void _startSimulation() {
    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first.')),
      );
      return;
    }

    setState(() {
      simulated = true;
      report = null;
      reportTime = null;
    });
  }

  void _resetSimulation() {
    setState(() {
      simulated = false;
      report = null;
      reportTime = null;
    });
  }

  String _buildReport() {
    final device = selectedDevice;
    if (device == null) return 'No device selected.';

    final buffer = StringBuffer();

    buffer.writeln('TWINGUARD EDGE');
    buffer.writeln('INFRASTRUCTURE FAILURE SIMULATION REPORT');
    buffer.writeln('');
    buffer.writeln('Generated: ${DateTime.now().toLocal()}');
    buffer.writeln('Scenario: $scenario');
    buffer.writeln('Selected device: ${device['name']}');
    buffer.writeln('Device type: ${device['type']}');
    buffer.writeln('Address: ${device['ipAddress']}');
    buffer.writeln('Recorded status: ${device['status'] ?? 'Unknown'}');
    buffer.writeln('Estimated severity: $severity');
    buffer.writeln('');
    buffer.writeln('SIMULATED OUTCOME');
    buffer.writeln(
      'The selected device is treated as failed or degraded in this '
      'simulation only. No physical equipment was changed.',
    );
    buffer.writeln('');
    buffer.writeln('POTENTIALLY AFFECTED INVENTORY');

    if (potentiallyAffected.isEmpty) {
      buffer.writeln('No other saved devices were found.');
    } else {
      for (final affected in potentiallyAffected) {
        buffer.writeln(
          '- ${affected['name']} (${affected['type']}, '
          '${affected['ipAddress']}): potential impact unknown',
        );
      }
    }

    buffer.writeln('');
    buffer.writeln('LIMITATIONS');
    buffer.writeln(
      'Device relationships are not configured. Other inventory records '
      'are not verified downstream dependencies. Severity is a heuristic, '
      'not measured risk.',
    );
    buffer.writeln('');
    buffer.writeln('RECOMMENDED ACTIONS');
    buffer.writeln(
      '1. Verify the actual device and interface status using authorized '
      'network management tools.',
    );
    buffer.writeln(
      '2. Check adjacent device reachability, routing, and service logs.',
    );
    buffer.writeln('3. Confirm redundant paths and failover configuration.');
    buffer.writeln(
      '4. Restore the device or service, then recheck connectivity.',
    );
    buffer.writeln(
      '5. Compare post-recovery checks with the recorded baseline.',
    );

    return buffer.toString();
  }

  Future<void> _generateReport() async {
    if (!simulated || selectedDevice == null) return;

    final generated = _buildReport();

    setState(() {
      report = generated;
      reportTime = DateTime.now();
    });

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.description_outlined, color: primaryBlue),
            SizedBox(width: 8),
            Expanded(child: Text('Simulation Report')),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: SelectableText(generated),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: generated));
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Report copied to clipboard.'),
                ),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy report'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text(
            'Failure Simulation',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.bold,
              color: darkText,
            ),
          ),
          SizedBox(height: 16),
          _Notice(
            text: 'No saved devices are available. Open Network, add devices, '
                'and return here.',
          ),
        ],
      );
    }

    final validIds = widget.devices.map((d) => d['id'] as int).toSet();

    if (selectedDeviceId == null || !validIds.contains(selectedDeviceId)) {
      selectedDeviceId = widget.devices.first['id'] as int;
    }

    final device = selectedDevice!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Failure Simulation',
          style: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.bold,
            color: darkText,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Select a saved device and model a possible failure.',
          style: TextStyle(color: mutedText, height: 1.5),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '1. Select a device',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: selectedDeviceId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Infrastructure device',
                    border: OutlineInputBorder(),
                  ),
                  items: widget.devices.map((item) {
                    return DropdownMenuItem<int>(
                      value: item['id'] as int,
                      child: Text(
                        '${item['name']} (${item['type']})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: simulated
                      ? null
                      : (value) {
                          setState(() {
                            selectedDeviceId = value;
                            report = null;
                          });
                        },
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _deviceIcon('${device['type']}'),
                    size: 32,
                    color: primaryBlue,
                  ),
                  title: Text(
                    '${device['name']}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${device['type']} • ${device['ipAddress']}\n'
                    'Last recorded status: ${device['status'] ?? 'Unknown'}',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '2. Choose a scenario',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),

                // FIXED: RadioGroup requires a non-null callback.
                // Changes are ignored while the simulation is running.
                RadioGroup<String>(
                  groupValue: scenario,
                  onChanged: (value) {
                    if (!simulated && value != null) {
                      setState(() {
                        scenario = value;
                        report = null;
                      });
                    }
                  },
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        value: 'Device failure',
                        title: Text('Complete device failure'),
                        subtitle: Text('Model the selected device as down'),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<String>(
                        value: 'Service failure',
                        title: Text('Service failure'),
                        subtitle: Text('Model a service as unavailable'),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<String>(
                        value: 'Performance degradation',
                        title: Text('Performance degradation'),
                        subtitle: Text('Model reduced device performance'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const _Notice(
                  text: 'This is a local simulation. It will not shut down '
                      'or modify the selected physical device.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: simulated ? null : _startSimulation,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Run Failure Simulation'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (simulated) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(scenarioIcon, color: dangerColor, size: 28),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Simulation Results',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const _StatusBadge(status: 'Simulated'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _ResultRow(
                    label: 'Selected device',
                    value: '${device['name']}',
                  ),
                  _ResultRow(
                    label: 'Scenario',
                    value: scenario,
                  ),
                  _ResultRow(
                    label: 'Estimated severity',
                    value: severity,
                  ),
                  _ResultRow(
                    label: 'Other saved devices',
                    value: '${potentiallyAffected.length}',
                  ),
                  const Divider(height: 24),
                  const Text(
                    'Potential impact',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (potentiallyAffected.isEmpty)
                    const Text(
                      'No other saved devices are available to list.',
                      style: TextStyle(color: mutedText),
                    )
                  else
                    ...potentiallyAffected.map(
                      (affected) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(
                          Icons.device_hub_outlined,
                          color: warningColor,
                        ),
                        title: Text('${affected['name']}'),
                        subtitle: Text(
                          '${affected['type']} • ${affected['ipAddress']}',
                        ),
                        trailing: const Icon(
                          Icons.help_outline,
                          color: warningColor,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const _Notice(
                    text: 'These are possible impact candidates, not verified '
                        'dependent devices. Configure real network links '
                        'before drawing topology-based conclusions.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _generateReport,
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('Generate Simulation Report'),
                    ),
                  ),
                  if (report != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Report generated at ${reportTime?.toLocal()}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: successColor,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: report!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Report copied to clipboard.'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy report again'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _resetSimulation,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset and Recover'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;

  const _ResultRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: mutedText),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: darkText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _deviceIcon(String type) {
  switch (type.toLowerCase()) {
    case 'router':
      return Icons.router_outlined;
    case 'switch':
      return Icons.device_hub_outlined;
    case 'pc':
      return Icons.computer_outlined;
    case 'server':
      return Icons.dns_outlined;
    case 'database':
      return Icons.storage_outlined;
    case 'firewall':
      return Icons.security_outlined;
    case 'access point':
      return Icons.wifi_outlined;
    default:
      return Icons.devices_other_outlined;
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _Heading(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: darkText,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _Metric(this.title, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: color, size: 25),
            Text(
              value,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: darkText,
              ),
            ),
            Text(
              title,
              style: const TextStyle(color: mutedText, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color = switch (status) {
      'Online' => successColor,
      'Offline' || 'Unreachable' => dangerColor,
      'Service Unavailable' => warningColor,
      'Simulated' => dangerColor,
      _ => warningColor,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: color, size: 8),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              status,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;

  const _Notice({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF1FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: primaryBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF36527D),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
