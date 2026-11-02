import 'package:flutter/material.dart';
import '../database/local_database.dart';

class VlanManagementPage extends StatefulWidget {
  const VlanManagementPage({super.key});

  @override
  State<VlanManagementPage> createState() => _VlanManagementPageState();
}

class _VlanManagementPageState extends State<VlanManagementPage> {
  final LocalDatabase db = LocalDatabase.instance;

  List<Map<String, dynamic>> vlans = [];
  List<Map<String, dynamic>> devices = [];

  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  // --------------------------------------------------
  // LOAD VLANs AND DEVICES
  // --------------------------------------------------

  Future<void> refresh() async {
    try {
      final results = await Future.wait([db.getVlans(), db.getDevices()]);

      if (!mounted) return;

      setState(() {
        vlans = List<Map<String, dynamic>>.from(results[0]);
        devices = List<Map<String, dynamic>>.from(results[1]);
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() => loading = false);
      showMessage('Unable to load VLANs: $error');
    }
  }

  void showMessage(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  // --------------------------------------------------
  // CREATE / EDIT VLAN
  // --------------------------------------------------

  Future<void> showVlanEditor({Map<String, dynamic>? vlan}) async {
    final formKey = GlobalKey<FormState>();

    final numberController = TextEditingController(
      text: vlan == null ? '' : '${vlan['vlanNumber']}',
    );

    final nameController = TextEditingController(
      text: '${vlan?['name'] ?? ''}',
    );

    final subnetController = TextEditingController(
      text: '${vlan?['subnet'] ?? ''}',
    );

    final descriptionController = TextEditingController(
      text: '${vlan?['description'] ?? ''}',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(vlan == null ? 'Create VLAN' : 'Edit VLAN'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: numberController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'VLAN ID',
                      hintText: 'Example: 10',
                      prefixIcon: Icon(Icons.tag),
                    ),
                    validator: (value) {
                      final number = int.tryParse(value ?? '');

                      if (number == null || number < 1 || number > 4094) {
                        return 'Enter VLAN ID from 1 to 4094';
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'VLAN name',
                      hintText: 'Example: Administration',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Enter VLAN name'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: subnetController,
                    decoration: const InputDecoration(
                      labelText: 'Subnet',
                      hintText: 'Example: 192.168.10.0/24',
                      prefixIcon: Icon(Icons.lan_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: descriptionController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      prefixIcon: Icon(Icons.description_outlined),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: Text(vlan == null ? 'Create' : 'Save'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      final vlanNumber = int.parse(numberController.text.trim());

      setState(() => saving = true);

      try {
        if (vlan == null) {
          await db.createVlan(
            vlanNumber: vlanNumber,
            name: nameController.text.trim(),
            subnet: subnetController.text.trim(),
            description: descriptionController.text.trim(),
          );

          showMessage('VLAN $vlanNumber created successfully.');
        } else {
          await db.updateVlan(
            id: vlan['id'] as int,
            vlanNumber: vlanNumber,
            name: nameController.text.trim(),
            subnet: subnetController.text.trim(),
            description: descriptionController.text.trim(),
          );

          showMessage('VLAN updated successfully.');
        }

        await refresh();
      } catch (error) {
        showMessage('VLAN operation failed: $error');
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }

    numberController.dispose();
    nameController.dispose();
    subnetController.dispose();
    descriptionController.dispose();
  }

  // --------------------------------------------------
  // ASSIGN DEVICE TO VLAN
  // --------------------------------------------------

  Future<void> assignDevice(int vlanId) async {
    if (devices.isEmpty) {
      showMessage('Add devices to your inventory first.');
      return;
    }

    int? selectedDeviceId;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Assign device to VLAN'),
              content: DropdownButtonFormField<int>(
                initialValue: selectedDeviceId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Select device'),
                items: devices.map((device) {
                  final id = device['id'] as int;

                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(
                      '${device['name']} (${device['ipAddress']})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setDialogState(() {
                    selectedDeviceId = value;
                  });
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selectedDeviceId == null
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text('Assign'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true || selectedDeviceId == null) return;

    try {
      await db.assignDeviceToVlan(deviceId: selectedDeviceId!, vlanId: vlanId);

      await refresh();

      showMessage('Device assigned successfully.');
    } catch (error) {
      showMessage('Assignment failed: $error');
    }
  }

  // --------------------------------------------------
  // REMOVE DEVICE FROM VLAN
  // --------------------------------------------------

  Future<void> unassignDevice(int deviceId) async {
    try {
      await db.unassignDeviceFromVlan(deviceId);

      await refresh();

      showMessage('Device removed from VLAN.');
    } catch (error) {
      showMessage('Could not remove assignment: $error');
    }
  }

  // --------------------------------------------------
  // DELETE VLAN
  // --------------------------------------------------

  Future<void> deleteVlan(Map<String, dynamic> vlan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete VLAN?'),
        content: Text(
          'Delete VLAN ${vlan['vlanNumber']} (${vlan['name']})? '
          'Assigned devices will remain in inventory but become unassigned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await db.deleteVlan(vlan['id'] as int);
      await refresh();

      showMessage('VLAN deleted successfully.');
    } catch (error) {
      showMessage('Could not delete VLAN: $error');
    }
  }

  // --------------------------------------------------
  // VLAN CARD
  // --------------------------------------------------

  Widget buildVlanCard(Map<String, dynamic> vlan) {
    final vlanId = vlan['id'] as int;
    final vlanNumber = vlan['vlanNumber'];

    final assignedDevices = devices
        .where((device) => device['vlanId'] == vlanId)
        .toList();

    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(14),
            leading: CircleAvatar(
              radius: 25,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                '$vlanNumber',
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(
              '${vlan['name']}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                'VLAN $vlanNumber · '
                '${vlan['subnet'] ?? 'No subnet configured'}',
              ),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  showVlanEditor(vlan: vlan);
                } else if (value == 'delete') {
                  deleteVlan(vlan);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit VLAN')),
                PopupMenuItem(value: 'delete', child: Text('Delete VLAN')),
              ],
            ),
          ),

          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Assigned devices',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '${assignedDevices.length}',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),

                if (vlan['description'] != null &&
                    '${vlan['description']}'.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    '${vlan['description']}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],

                const SizedBox(height: 10),

                if (assignedDevices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No devices assigned to this VLAN.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ...assignedDevices.map(
                    (device) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.devices_other),
                      title: Text('${device['name']}'),
                      subtitle: Text(
                        '${device['type']} · ${device['ipAddress']}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Unassign device',
                        onPressed: () => unassignDevice(device['id'] as int),
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 8),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => assignDevice(vlanId),
                    icon: const Icon(Icons.add_link),
                    label: const Text('Assign device'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // MAIN UI
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VLAN Management',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Configure logical network segments.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(onPressed: refresh, icon: const Icon(Icons.refresh)),
            ],
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: saving ? null : () => showVlanEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Create VLAN'),
            ),
          ),

          const SizedBox(height: 20),

          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(35),
                child: CircularProgressIndicator(),
              ),
            )
          else if (vlans.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      Icons.account_tree_outlined,
                      size: 45,
                      color: Colors.grey,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No VLANs configured yet.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Create your first VLAN to organize your infrastructure.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Text(
              '${vlans.length} configured VLANs',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...vlans.map(buildVlanCard),
          ],

          const SizedBox(height: 20),

          const Text(
            'Note: VLAN assignments here are locally configured logical '
            'groupings. They are not automatically detected from Wi-Fi scans.',
            style: TextStyle(color: Colors.grey, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }
}
