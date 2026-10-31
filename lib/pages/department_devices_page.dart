import 'package:flutter/material.dart';

class DepartmentDevicesPage extends StatelessWidget {
  final Map<String, dynamic> department;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> connections;

  const DepartmentDevicesPage({
    super.key,
    required this.department,
    required this.devices,
    required this.connections,
  });

  // Determine device status color.
  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'online':
      case 'active':
      case 'healthy':
        return Colors.green;

      case 'offline':
      case 'failed':
      case 'down':
        return Colors.red;

      default:
        return Colors.orange;
    }
  }

  // Select an icon based on device type.
  IconData _deviceIcon(String type) {
    switch (type.toLowerCase()) {
      case 'router':
        return Icons.router;

      case 'switch':
        return Icons.device_hub;

      case 'computer':
        return Icons.computer;

      case 'server':
        return Icons.dns;

      case 'firewall':
        return Icons.security;

      default:
        return Icons.devices;
    }
  }

  // Find devices connected from a particular source device.
  List<Map<String, dynamic>> _childrenOf(String deviceId) {
    final targetIds = connections
        .where(
          (connection) => connection['source_device_id'].toString() == deviceId,
        )
        .map((connection) => connection['target_device_id'].toString())
        .toSet();

    return devices
        .where((device) => targetIds.contains(device['device_id'].toString()))
        .toList();
  }

  // Reusable device information tile.
  Widget _deviceTile(Map<String, dynamic> device) {
    final type = device['device_type'].toString();
    final status = device['status'].toString();
    final color = _statusColor(status);

    return ListTile(
      dense: true,
      leading: Icon(_deviceIcon(type), color: Colors.blue),
      title: Text(device['name'].toString()),
      subtitle: Text('${type.toUpperCase()} • ${device['ip_address']}'),
      trailing: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  // Build the department's logical network topology.
  // BuildContext is passed explicitly so we can access the theme.
  Widget _buildTopology(BuildContext context) {
    final routers = devices
        .where((device) => device['device_type'] == 'router')
        .toList();

    if (routers.isEmpty || connections.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No network connections are available.'),
        ),
      );
    }

    return Column(
      children: routers.map((router) {
        // Find switches connected to this router.
        final firstLevelDevices = _childrenOf(router['device_id'].toString());

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Router.
                _deviceTile(router),

                const Divider(),

                // Devices connected to this router.
                ...firstLevelDevices.map((connectedDevice) {
                  final connectedType = connectedDevice['device_type']
                      .toString()
                      .toLowerCase();

                  // Find devices connected to this device.
                  final childDevices = _childrenOf(
                    connectedDevice['device_id'].toString(),
                  );

                  return Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 18),
                            const Icon(
                              Icons.subdirectory_arrow_right,
                              color: Colors.blue,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Connected $connectedType',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),

                        Card(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: Column(
                            children: [
                              // Switch or directly connected device.
                              _deviceTile(connectedDevice),

                              // Devices connected beneath this switch.
                              if (childDevices.isNotEmpty) ...[
                                const Divider(height: 1),

                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Connected endpoints '
                                        '(${childDevices.length})',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),

                                      const SizedBox(height: 8),

                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: childDevices.map((device) {
                                          return Chip(
                                            avatar: Icon(
                                              _deviceIcon(
                                                device['device_type']
                                                    .toString(),
                                              ),
                                              size: 16,
                                            ),
                                            label: Text(
                                              device['name'].toString(),
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // Reusable count metric.
  Widget _metric(String label, int value) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
        ),
        Text(label),
      ],
    );
  }

  // Display additional device information.
  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 17, color: Colors.grey),
        const SizedBox(width: 9),
        Text('$label: ', style: const TextStyle(color: Colors.grey)),
        Expanded(child: Text(value, textAlign: TextAlign.end)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Count device categories.
    final routers = devices
        .where((device) => device['device_type'] == 'router')
        .length;

    final switches = devices
        .where((device) => device['device_type'] == 'switch')
        .length;

    final computers = devices
        .where((device) => device['device_type'] == 'computer')
        .length;

    return Scaffold(
      appBar: AppBar(title: Text(department['name'].toString())),

      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Department summary.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    department['name'].toString(),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    '${department['building']} • '
                    '${department['floor_count']} floors',
                  ),

                  const SizedBox(height: 16),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _metric('Routers', routers),
                      _metric('Switches', switches),
                      _metric('Computers', computers),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Text(
                    '${devices.length} devices • '
                    '${connections.length} connections',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 4),

                  const Text(
                    'SIMULATED DATA',
                    style: TextStyle(color: Colors.orange, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Department logical topology.
          Text(
            'Network Topology',
            style: Theme.of(context).textTheme.titleLarge,
          ),

          const SizedBox(height: 10),

          _buildTopology(context),

          const SizedBox(height: 20),

          // Complete department device inventory.
          Text(
            'All Network Devices (${devices.length})',
            style: Theme.of(context).textTheme.titleLarge,
          ),

          const SizedBox(height: 10),

          ...devices.map((device) {
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _deviceTile(device),

                    const Divider(),

                    _infoRow(
                      Icons.fingerprint,
                      'MAC Address',
                      device['mac_address'].toString(),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
