
import 'dart:io';

import 'package:flutter/material.dart';
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
  bool failureSimulated = false;
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

  Future<String> checkDeviceReachability(String host) async {
    const ports = [80, 443, 22];

    for (final port in ports) {
      Socket? socket;

      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 2),
        );
        return 'Online';
      } on SocketException {
        // The service may be closed, filtered, or unreachable.
      } on ArgumentError {
        return 'Unknown';
      } catch (_) {
        // Try another port.
      } finally {
        socket?.destroy();
      }
    }

    return 'Unreachable';
  }

  Future<void> _checkDevice(Map<String, dynamic> device) async {
    final id = device['id'] as int;
    final host = (device['ipAddress'] ?? '').toString().trim();

    if (host.isEmpty) {
      _message('Enter an IP address or hostname first.');
      return;
    }

    setState(() => checkingDevices.add(id));

    try {
      final status = await checkDeviceReachability(host);

      await LocalDatabase.instance.updateDeviceStatus(id, status);

      if (!mounted) return;

      setState(_reloadDevices);
      _message('${device['name']}: $status');
    } catch (error) {
      if (!mounted) return;
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
                      'Server',
                      'Database',
                      'Firewall',
                      'Other',
                    ]
                        .map(
                          (item) => DropdownMenuItem(
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
                        // Correct API: named parameters, not a Map.
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
      if (!mounted) return;
      _message('Could not delete device: $error');
    }
  }

  Future<void> _manualStatus(Map<String, dynamic> device) async {
    final status = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Set status manually'),
        children: ['Online', 'Offline', 'Unknown', 'Unreachable']
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
      if (!mounted) return;
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
      body: IndexedStack(index: selectedTab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: (index) {
          setState(() {
            selectedTab = index;
            if (index == 1 || index == 0) _reloadDevices();
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
        final unreachable =
            devices.where((d) => d['status'] == 'Unreachable').length;
        final unknown = devices.where((d) {
          final s = d['status'];
          return s != 'Online' && s != 'Offline' && s != 'Unreachable';
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
                  Icon(Icons.shield_moon_outlined,
                      color: Colors.white, size: 34),
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
                    'Manage your local inventory and check network '
                    'service reachability.',
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
                _Metric('Total Devices', '${devices.length}',
                    Icons.devices, primaryBlue),
                _Metric('Reachable', '$online',
                    Icons.check_circle_outline, successColor),
                _Metric('Unreachable', '$unreachable',
                    Icons.portable_wifi_off, dangerColor),
                _Metric('Not Checked', '$unknown',
                    Icons.help_outline, warningColor),
              ],
            ),
            const SizedBox(height: 22),
            _Heading(
              'Network Topology',
              trailing: TextButton(
                onPressed: () => setState(() => selectedTab = 1),
                child: const Text('View devices'),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _Node(
                      icon: Icons.router_outlined,
                      title: 'Network Devices',
                      subtitle: '${devices.length} saved device(s)',
                    ),
                    const _Connector(),
                    const _Node(
                      icon: Icons.storage_outlined,
                      title: 'Local SQLite',
                      subtitle: 'Device inventory',
                    ),
                    const _Connector(),
                    const _Node(
                      icon: Icons.analytics_outlined,
                      title: 'TCP Reachability',
                      subtitle: 'On-demand service checks',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _Notice(
              text: 'A failed TCP check does not always mean the entire '
                  'device is offline. Firewalls may block the tested ports.',
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
                    'Manage and check your devices',
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
                        tooltip: 'Refresh',
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.devices_other_outlined,
                                size: 60, color: mutedText),
                            SizedBox(height: 14),
                            Text(
                              'No devices added yet',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Add a router, switch, or server to begin.',
                              textAlign: TextAlign.center,
                            ),
                          ],
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
                            (device['status'] ?? 'Unknown').toString();

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.devices,
                                        color: primaryBlue, size: 30),
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
                                    _StatusBadge(status: status),
                                    const Spacer(),
                                    if (checking)
                                      const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
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
        const SizedBox(height: 8),
        const Text(
          'Demonstrate the potential impact of a core switch failure.',
          style: TextStyle(color: mutedText, height: 1.5),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _Node(
                  icon: Icons.hub_outlined,
                  title: 'Core Switch S1',
                  subtitle: failureSimulated
                      ? 'Simulated failure'
                      : 'Normal in demonstration',
                  color: failureSimulated ? dangerColor : successColor,
                ),
                const _Connector(),
                _Node(
                  icon: Icons.dns_outlined,
                  title: 'Web Server W1',
                  subtitle: failureSimulated
                      ? 'Potentially affected'
                      : 'No simulated impact',
                  color: failureSimulated ? warningColor : primaryBlue,
                ),
                const _Connector(),
                _Node(
                  icon: Icons.storage_outlined,
                  title: 'Database D1',
                  subtitle: failureSimulated
                      ? 'Potentially affected'
                      : 'No simulated impact',
                  color: failureSimulated ? warningColor : primaryBlue,
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => setState(
                      () => failureSimulated = !failureSimulated,
                    ),
                    icon: Icon(
                      failureSimulated ? Icons.restart_alt : Icons.bolt,
                    ),
                    label: Text(
                      failureSimulated
                          ? 'Reset Scenario'
                          : 'Simulate Switch Failure',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const _Notice(
          text: 'This is a rule-based demonstration only. It does not '
              'modify or shut down physical network equipment.',
        ),
      ],
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
                title: Text('TCP reachability'),
                subtitle: Text('Ports 80, 443 and 22'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.cloud_off_outlined, color: warningColor),
                title: Text('Offline-first'),
                subtitle: Text('Inventory remains stored locally'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.psychology_outlined),
                title: Text('Predictive model'),
                subtitle: Text('Advanced prediction is not implemented yet'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _Notice(
          text: 'Authentication, encrypted storage, background collection, '
              'and advanced prediction remain future development tasks.',
        ),
      ],
    );
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
            Text(title, style: const TextStyle(color: mutedText, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Node extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _Node({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color = primaryBlue,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: mutedText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      width: 2,
      color: const Color(0xFFD7E0EF),
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
          Text(
            status,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 11,
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
