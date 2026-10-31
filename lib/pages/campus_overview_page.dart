import 'package:flutter/material.dart';

import '../services/campus_api_service.dart';
import 'department_devices_page.dart';

class CampusOverviewPage extends StatefulWidget {
  const CampusOverviewPage({super.key});

  @override
  State<CampusOverviewPage> createState() => _CampusOverviewPageState();
}

class _CampusOverviewPageState extends State<CampusOverviewPage> {
  late final CampusApiService _api;
  late Future<Map<String, dynamic>> _campusFuture;

  @override
  void initState() {
    super.initState();

    _api = CampusApiService();
    _campusFuture = _api.fetchCampus();
  }

  // Fetch fresh campus information from the Python API.
  Future<void> _refresh() async {
    final future = _api.fetchCampus();

    setState(() {
      _campusFuture = future;
    });

    try {
      await future;
    } catch (_) {
      // FutureBuilder displays the API error.
    }
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  // Convert API JSON lists into Dart maps.
  List<Map<String, dynamic>> _parseList(dynamic value) {
    if (value is! List) {
      return [];
    }

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus Network'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh campus data',
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _campusFuture,
        builder: (context, snapshot) {
          // Loading state.
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          // API error state.
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    const Text(
                      'Unable to load campus data',
                      style: TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error.toString(),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _refresh,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: Text('No campus data available.'));
          }

          final response = snapshot.data!;

          final summary = Map<String, dynamic>.from(response['summary'] as Map);

          final campus = Map<String, dynamic>.from(response['campus'] as Map);

          // Departments received from FastAPI.
          final departments = _parseList(campus['departments']);

          // Devices received from FastAPI.
          final devices = _parseList(campus['devices']);

          // Network connections received from FastAPI.
          final connections = _parseList(campus['connections']);

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                // Campus summary.
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          campus['name'].toString(),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Prototype data • SIMULATED',
                          style: TextStyle(
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _metric(
                              'Departments',
                              summary['departments'].toString(),
                            ),
                            _metric('Devices', summary['devices'].toString()),
                            _metric(
                              'Connections',
                              summary['connections'].toString(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                Text(
                  'Departments',
                  style: Theme.of(context).textTheme.titleLarge,
                ),

                const SizedBox(height: 8),

                // Generate a card for each department.
                ...departments.map((department) {
                  final departmentId = department['department_id'].toString();

                  // Select only devices belonging to this department.
                  final departmentDevices = devices
                      .where(
                        (device) =>
                            device['department_id'].toString() == departmentId,
                      )
                      .toList();

                  // Collect the device IDs in this department.
                  final departmentDeviceIds = departmentDevices
                      .map((device) => device['device_id'].toString())
                      .toSet();

                  // Select only connections where both endpoints
                  // belong to the selected department.
                  final departmentConnections = connections.where((connection) {
                    final sourceId = connection['source_device_id'].toString();

                    final targetId = connection['target_device_id'].toString();

                    return departmentDeviceIds.contains(sourceId) &&
                        departmentDeviceIds.contains(targetId);
                  }).toList();

                  // Count device types.
                  final routers = departmentDevices
                      .where((device) => device['device_type'] == 'router')
                      .length;

                  final switches = departmentDevices
                      .where((device) => device['device_type'] == 'switch')
                      .length;

                  final computers = departmentDevices
                      .where((device) => device['device_type'] == 'computer')
                      .length;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      // Open the selected department's detail page.
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DepartmentDevicesPage(
                              department: department,
                              devices: departmentDevices,
                              connections: departmentConnections,
                            ),
                          ),
                        );
                      },

                      leading: const CircleAvatar(
                        child: Icon(Icons.account_tree),
                      ),

                      title: Text(department['name'].toString()),

                      subtitle: Text(
                        '${department['building']} • '
                        '${department['floor_count']} floors\n'
                        '$routers Routers • '
                        '$switches Switches • '
                        '$computers Computers',
                      ),

                      isThreeLine: true,

                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${departmentDevices.length}\nDevices',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          );
        },
      ),
    );
  }

  // Reusable campus metric widget.
  Widget _metric(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        Text(label),
      ],
    );
  }
}
