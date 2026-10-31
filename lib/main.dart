import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'pages/campus_overview_page.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pages/monitoring_page.dart';
import 'database/local_database.dart';
import 'pages/wifi_discovery_page.dart';
const primaryColor = Color(0xFF5267E8);
const mutedColor = Color(0xFF788399);
const successColor = Color(0xFF16A779);
const dangerColor = Color(0xFFE34D59);
const warningColor = Color(0xFFE8A23B);
const themeKey = 'twinguard_dark_mode';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TwinGuardApp());
}

// -----------------------------------------------------------------------------
// APPLICATION AND THEME
// -----------------------------------------------------------------------------

class TwinGuardApp extends StatefulWidget {
  const TwinGuardApp({super.key});

  @override
  State<TwinGuardApp> createState() => _TwinGuardAppState();
}

class _TwinGuardAppState extends State<TwinGuardApp> {
  bool loading = true;
  bool authenticated = false;
  bool darkMode = false;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = await AuthService.instance.currentUserId();

      if (!mounted) return;
      setState(() {
        darkMode = prefs.getBool(themeKey) ?? false;
        authenticated = userId != null;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> changeTheme(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(themeKey, value);
    if (mounted) setState(() => darkMode = value);
  }

  Future<void> logout() async {
    await AuthService.instance.logout();
    if (mounted) setState(() => authenticated = false);
  }

  ThemeData buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF101522)
          : const Color(0xFFF5F7FC),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark
            ? const Color(0xFF101522)
            : const Color(0xFFF5F7FC),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF1B2333) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: isDark ? const Color(0xFF30394B) : const Color(0xFFE9EDF5),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF20293A) : const Color(0xFFF7F8FC),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    return base.copyWith(textTheme: GoogleFonts.interTextTheme(base.textTheme));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TwinGuard Edge',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : authenticated
          ? MainNavigation(
              darkMode: darkMode,
              onThemeChanged: changeTheme,
              onLogout: logout,
            )
          : AuthPage(
              onAuthenticated: () {
                setState(() => authenticated = true);
              },
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// LOCAL AUTHENTICATION
// Requires the users table and methods in local_database.dart:
// createUser, usernameExists, getUserByUsername, getUserById.
// -----------------------------------------------------------------------------

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const sessionKey = 'twinguard_user_id';

  final LocalDatabase db = LocalDatabase.instance;

  final Pbkdf2 hasher = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );

  Future<String> hashPassword(String password, List<int> salt) async {
    final key = await hasher.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return base64Encode(await key.extractBytes());
  }

  Future<int> register({
    required String username,
    required String password,
  }) async {
    final name = username.trim();

    if (name.length < 3) {
      throw ArgumentError('Username must contain at least 3 characters.');
    }
    if (password.length < 8) {
      throw ArgumentError('Password must contain at least 8 characters.');
    }
    if (await db.usernameExists(name)) {
      throw ArgumentError('This username is already registered.');
    }

    final random = math.Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await hashPassword(password, salt);

    final id = await db.createUser(
      username: name,
      passwordHash: hash,
      passwordSalt: base64Encode(salt),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(sessionKey, id);
    return id;
  }

  Future<int> login({
    required String username,
    required String password,
  }) async {
    final user = await db.getUserByUsername(username.trim());

    if (user == null) {
      throw ArgumentError('Invalid username or password.');
    }

    final salt = base64Decode(user['passwordSalt'] as String);
    final hash = await hashPassword(password, salt);

    if (hash != user['passwordHash']) {
      throw ArgumentError('Invalid username or password.');
    }

    final id = user['id'] as int;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(sessionKey, id);
    return id;
  }

  Future<int?> currentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(sessionKey);

    if (id == null) return null;

    final user = await db.getUserById(id);
    if (user == null) {
      await logout();
      return null;
    }

    return id;
  }

  Future<Map<String, dynamic>?> currentUser() async {
    final id = await currentUserId();
    if (id == null) return null;
    return db.getUserById(id);
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(sessionKey);
  }
}

// -----------------------------------------------------------------------------
// LOGIN AND REGISTER
// -----------------------------------------------------------------------------

class AuthPage extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const AuthPage({super.key, required this.onAuthenticated});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final formKey = GlobalKey<FormState>();
  final username = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();

  bool registering = false;
  bool busy = false;
  bool hidePassword = true;

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!formKey.currentState!.validate()) return;

    if (registering && password.text != confirmation.text) {
      message(context, 'Passwords do not match.');
      return;
    }

    setState(() => busy = true);

    try {
      if (registering) {
        await AuthService.instance.register(
          username: username.text,
          password: password.text,
        );
      } else {
        await AuthService.instance.login(
          username: username.text,
          password: password.text,
        );
      }

      if (mounted) widget.onAuthenticated();
    } catch (error) {
      if (mounted) {
        message(
          context,
          error is ArgumentError
              ? error.message.toString()
              : 'Authentication failed: $error',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.hub_rounded,
                      color: primaryColor,
                      size: 76,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'TwinGuard Edge',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      registering
                          ? 'Create your local account'
                          : 'Sign in to your workspace',
                      style: const TextStyle(color: mutedColor),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: username,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) =>
                          value == null || value.trim().length < 3
                          ? 'Enter at least 3 characters.'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: password,
                      obscureText: hidePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => hidePassword = !hidePassword),
                          icon: Icon(
                            hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => value == null || value.length < 8
                          ? 'Use at least 8 characters.'
                          : null,
                    ),
                    if (registering) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: confirmation,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Confirm password',
                          prefixIcon: Icon(Icons.lock_reset),
                        ),
                        validator: (value) => value != password.text
                            ? 'Passwords do not match.'
                            : null,
                      ),
                    ],
                    const SizedBox(height: 22),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: busy ? null : submit,
                        child: busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(registering ? 'Create account' : 'Sign in'),
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              registering = !registering;
                              confirmation.clear();
                            }),
                      child: Text(
                        registering
                            ? 'Already registered? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Local authentication · No cloud required',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// BOTTOM NAVIGATION
// -----------------------------------------------------------------------------

class MainNavigation extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onThemeChanged;
  final Future<void> Function() onLogout;

  const MainNavigation({
    super.key,
    required this.darkMode,
    required this.onThemeChanged,
    required this.onLogout,
  });

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DashboardPage(),
      const NetworkPage(),
      const TopologyPage(),
      const SimulationPage(),
      const CampusOverviewPage(),
      const MonitoringPage(),
      const WifiDiscoveryPage(),
      SettingsPage(
        darkMode: widget.darkMode,
        onThemeChanged: widget.onThemeChanged,
        onLogout: widget.onLogout,
      ),
    ];

    return Scaffold(
      appBar: (index == 4 || index == 5 || index == 6 )
          ? null
          : AppBar(
              title: const Row(
                children: [
                  Icon(Icons.hub_rounded, color: primaryColor, size: 32),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TwinGuard Edge',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                        Text(
                          'OFFLINE INFRASTRUCTURE TWIN',
                          style: TextStyle(
                            fontSize: 9,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: const [
                Padding(
                  padding: EdgeInsets.only(right: 14),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 8, color: successColor),
                      SizedBox(width: 5),
                      Text(
                        'LOCAL',
                        style: TextStyle(
                          color: successColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: 'Network',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: 'Topology',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Simulate',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Monitor',
          ),
          NavigationDestination(
  icon: Icon(Icons.wifi_find_outlined),
  selectedIcon: Icon(Icons.wifi_find),
  label: 'Wi-Fi',
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
}

// -----------------------------------------------------------------------------
// REUSABLE WIDGETS
// -----------------------------------------------------------------------------

class PageContainer extends StatelessWidget {
  final Widget child;

  const PageContainer({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(padding: const EdgeInsets.all(16), child: child);
}

class Heading extends StatelessWidget {
  final String title;
  final String? subtitle;

  const Heading(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 5),
          Text(
            subtitle!,
            style: const TextStyle(color: mutedColor, fontSize: 12),
          ),
        ],
      ],
    ),
  );
}

class SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: padding, child: child),
  );
}

class MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String description;
  final IconData icon;
  final Color color;

  const MetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.description,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: mutedColor, fontSize: 12),
                ),
              ),
              Icon(icon, color: color),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 27,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            description,
            style: const TextStyle(color: mutedColor, fontSize: 10),
          ),
        ],
      ),
    ),
  );
}

void message(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
}

Color statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'online':
    case 'healthy':
      return successColor;
    case 'offline':
    case 'failed':
    case 'critical':
      return dangerColor;
    default:
      return warningColor;
  }
}

Widget statusBadge(String status) {
  final color = statusColor(status);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      status,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
    ),
  );
}

IconData deviceIcon(String type) {
  switch (type.toLowerCase()) {
    case 'router':
      return Icons.router_rounded;
    case 'switch':
      return Icons.device_hub_rounded;
    case 'server':
      return Icons.dns_rounded;
    case 'database':
      return Icons.storage_rounded;
    case 'firewall':
      return Icons.security_rounded;
    case 'computer':
      return Icons.computer_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color color;

  const InfoRow(this.icon, this.title, this.value, this.color, {super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: color),
      const SizedBox(width: 12),
      Expanded(child: Text(title)),
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

// -----------------------------------------------------------------------------
// DASHBOARD
// -----------------------------------------------------------------------------

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<Map<String, dynamic>> devices = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final rows = await LocalDatabase.instance.getDevices();
      if (!mounted) return;
      setState(() {
        devices = List<Map<String, dynamic>>.from(rows);
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      message(context, 'Unable to load dashboard: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = devices
        .where((d) => '${d['status']}'.toLowerCase() == 'online')
        .length;
    final offline = devices
        .where((d) => '${d['status']}'.toLowerCase() == 'offline')
        .length;

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Infrastructure overview',
            subtitle: 'Monitor your locally modeled IT environment.',
          ),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Total devices',
                        value: '${devices.length}',
                        description: 'Registered locally',
                        icon: Icons.devices,
                        color: primaryColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Online',
                        value: '$online',
                        description: 'Marked online',
                        icon: Icons.check_circle_outline,
                        color: successColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Offline',
                        value: '$offline',
                        description: 'Marked offline',
                        icon: Icons.warning_amber,
                        color: dangerColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: const MetricCard(
                        title: 'Scenarios',
                        value: '3',
                        description: 'Available simulations',
                        icon: Icons.science_outlined,
                        color: warningColor,
                      ),
                    ),
                  ],
                );
              },
            ),
          const SizedBox(height: 22),
          const Heading('System status'),
          const SectionCard(
            child: Column(
              children: [
                InfoRow(
                  Icons.storage,
                  'Local database',
                  'SQLite',
                  successColor,
                ),
                Divider(height: 24),
                InfoRow(
                  Icons.cloud_off,
                  'Cloud dependency',
                  'Not required',
                  successColor,
                ),
                Divider(height: 24),
                InfoRow(
                  Icons.hub,
                  'Digital twin',
                  'Local inventory',
                  primaryColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Heading('Recent devices (${devices.length})'),
          if (devices.isEmpty)
            const SectionCard(
              child: Text(
                'No devices yet. Open Network to add your first device.',
                style: TextStyle(color: mutedColor),
              ),
            )
          else
            ...devices
                .take(5)
                .map(
                  (device) => SectionCard(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          deviceIcon('${device['type']}'),
                          color: primaryColor,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${device['name']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${device['type']} · ${device['ipAddress']}',
                                style: const TextStyle(
                                  color: mutedColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        statusBadge('${device['status']}'),
                      ],
                    ),
                  ),
                ),
          TextButton.icon(
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// NETWORK INVENTORY
// -----------------------------------------------------------------------------

class NetworkPage extends StatefulWidget {
  const NetworkPage({super.key});

  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  List<Map<String, dynamic>> devices = [];
  bool loading = true;
  bool scanning = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final rows = await LocalDatabase.instance.getDevices();
      if (!mounted) return;
      setState(() {
        devices = List<Map<String, dynamic>>.from(rows);
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      message(context, 'Unable to load devices: $error');
    }
  }

  Future<void> addDevice() async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController();
    final address = TextEditingController();
    String type = 'Router';

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Add device'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Device name'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a device name'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Device type'),
                  items:
                      const [
                            'Router',
                            'Switch',
                            'Server',
                            'Database',
                            'Firewall',
                            'Computer',
                            'Monitor',
                          ]
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) setDialogState(() => type = value);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: address,
                  decoration: const InputDecoration(
                    labelText: 'IP address / hostname',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter an address'
                      : null,
                ),
              ],
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
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      try {
        await LocalDatabase.instance.addDevice(
          name: name.text.trim(),
          type: type,
          ipAddress: address.text.trim(),
          status: 'Unknown',
        );
        await refresh();
        if (mounted) message(context, 'Device added.');
      } catch (error) {
        if (mounted) message(context, 'Could not add device: $error');
      }
    }

    name.dispose();
    address.dispose();
  }

  Future<void> changeStatus(Map<String, dynamic> device) async {
    final id = device['id'];
    if (id is! int) return;

    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final status in ['Online', 'Offline', 'Unknown'])
              ListTile(
                leading: Icon(
                  Icons.circle,
                  size: 12,
                  color: statusColor(status),
                ),
                title: Text(status),
                onTap: () => Navigator.pop(context, status),
              ),
          ],
        ),
      ),
    );

    if (value == null) return;

    try {
      await LocalDatabase.instance.updateDeviceStatus(id, value);
      await refresh();
    } catch (error) {
      if (mounted) message(context, 'Could not update status: $error');
    }
  }

  Future<void> deleteDevice(Map<String, dynamic> device) async {
    final id = device['id'];
    if (id is! int) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete device?'),
        content: Text('Remove "${device['name']}" from the inventory?'),
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

    if (confirmed != true) return;

    try {
      await LocalDatabase.instance.deleteConnectionsForDevice(id);
      await LocalDatabase.instance.deleteDevice(id);
      await refresh();
    } catch (error) {
      if (mounted) message(context, 'Could not delete device: $error');
    }
  }

  Future<void> checkReachability(Map<String, dynamic> device) async {
    final host = '${device['ipAddress'] ?? ''}'.trim();
    if (host.isEmpty) return;

    setState(() => scanning = true);
    int? openPort;

    for (final port in [80, 443, 22]) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 2),
        );
        openPort = port;
        break;
      } on SocketException {
        // Check the next port.
      } finally {
        socket?.destroy();
      }
    }

    if (!mounted) return;
    setState(() => scanning = false);

    message(
      context,
      openPort != null
          ? '$host accepted a TCP connection on port $openPort.'
          : 'No TCP response on ports 80, 443 or 22. This does not prove the device is offline.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Infrastructure inventory',
            subtitle: 'Manage locally stored network devices.',
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: addDevice,
              icon: const Icon(Icons.add),
              label: const Text('Add device'),
            ),
          ),
          const SizedBox(height: 14),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (devices.isEmpty)
            const SectionCard(
              child: Text(
                'No devices yet. Add a router, switch, or server.',
                style: TextStyle(color: mutedColor),
              ),
            )
          else
            ...devices.map(
              (device) => SectionCard(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          deviceIcon('${device['type']}'),
                          color: primaryColor,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${device['name']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${device['type']} · ${device['ipAddress']}',
                                style: const TextStyle(
                                  color: mutedColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'status') changeStatus(device);
                            if (value == 'check') checkReachability(device);
                            if (value == 'delete') deleteDevice(device);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'status',
                              child: Text('Change status'),
                            ),
                            PopupMenuItem(
                              value: 'check',
                              child: Text('Check TCP reachability'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete device'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        statusBadge('${device['status']}'),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: scanning
                              ? null
                              : () => checkReachability(device),
                          icon: const Icon(Icons.network_check, size: 17),
                          label: const Text('Check'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (scanning) const LinearProgressIndicator(),
          TextButton.icon(
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// NETWORK TOPOLOGY
// -----------------------------------------------------------------------------

class TopologyPage extends StatefulWidget {
  const TopologyPage({super.key});

  @override
  State<TopologyPage> createState() => _TopologyPageState();
}

class _TopologyPageState extends State<TopologyPage> {
  List<Map<String, dynamic>> devices = [];
  List<Map<String, dynamic>> connections = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  int deviceId(Map<String, dynamic> device) => device['id'] as int;

  Future<void> refresh() async {
    try {
      final d = await LocalDatabase.instance.getDevices();
      final c = await LocalDatabase.instance.getConnections();
      if (!mounted) return;

      setState(() {
        devices = List<Map<String, dynamic>>.from(d);
        connections = List<Map<String, dynamic>>.from(c);
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      message(context, 'Could not load topology: $error');
    }
  }

  Future<void> connectDevices() async {
    if (devices.length < 2) {
      message(context, 'Add at least two devices first.');
      return;
    }

    int? first;
    int? second;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Connect devices'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: first,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'First device'),
                items: devices
                    .map(
                      (d) => DropdownMenuItem<int>(
                        value: deviceId(d),
                        child: Text('${d['name']}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setDialogState(() {
                  first = value;
                  if (first == second) second = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: second,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Second device'),
                items: devices
                    .where((d) => deviceId(d) != first)
                    .map(
                      (d) => DropdownMenuItem<int>(
                        value: deviceId(d),
                        child: Text('${d['name']}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setDialogState(() => second = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                first != null && second != null && first != second,
              ),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || first == null || second == null) return;

    try {
      await LocalDatabase.instance.addConnection(
        deviceAId: first!,
        deviceBId: second!,
      );
      await refresh();
      if (mounted) message(context, 'Connection saved.');
    } catch (error) {
      if (mounted) message(context, 'Could not connect devices: $error');
    }
  }

  Future<void> removeConnection(Map<String, dynamic> connection) async {
    final id = connection['id'];
    if (id is! int) return;

    try {
      await LocalDatabase.instance.deleteConnection(id);
      await refresh();
    } catch (error) {
      if (mounted) message(context, 'Could not remove connection: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Network topology',
            subtitle: 'View and manage device connections.',
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: connectDevices,
              icon: const Icon(Icons.add_link),
              label: const Text('Connect devices'),
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Infrastructure map',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                if (loading)
                  const SizedBox(
                    height: 220,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (devices.isEmpty)
                  const SizedBox(
                    height: 150,
                    child: Center(
                      child: Text(
                        'Add devices to create a topology.',
                        style: TextStyle(color: mutedColor),
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 290,
                    width: double.infinity,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final count = math.min(devices.length, 10);
                        final points = List.generate(count, (i) {
                          final angle = -math.pi / 2 + 2 * math.pi * i / count;
                          return Offset(
                            constraints.maxWidth / 2 +
                                constraints.maxWidth * .34 * math.cos(angle),
                            145 + 100 * math.sin(angle),
                          );
                        });

                        return Stack(
                          children: [
                            CustomPaint(
                              size: Size(constraints.maxWidth, 290),
                              painter: ConnectionPainter(
                                devices: devices.take(count).toList(),
                                connections: connections,
                                points: points,
                              ),
                            ),
                            for (var i = 0; i < count; i++)
                              Positioned(
                                left: points[i].dx - 34,
                                top: points[i].dy - 28,
                                width: 68,
                                child: Column(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: primaryColor.withValues(
                                        alpha: .12,
                                      ),
                                      child: Icon(
                                        deviceIcon('${devices[i]['type']}'),
                                        color: primaryColor,
                                        size: 21,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${devices[i]['name']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Heading('Saved connections (${connections.length})'),
          if (connections.isEmpty)
            const SectionCard(
              child: Text(
                'No connections saved yet.',
                style: TextStyle(color: mutedColor),
              ),
            )
          else
            ...connections.map((connection) {
              final aId = connection['deviceAId'] ?? connection['device_a_id'];
              final bId = connection['deviceBId'] ?? connection['device_b_id'];

              final a = devices.where((d) => '${d['id']}' == '$aId');
              final b = devices.where((d) => '${d['id']}' == '$bId');

              final aName = a.isEmpty ? 'Device $aId' : '${a.first['name']}';
              final bName = b.isEmpty ? 'Device $bId' : '${b.first['name']}';

              return SectionCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link, color: primaryColor),
                    const SizedBox(width: 10),
                    Expanded(child: Text('$aName ↔ $bName')),
                    IconButton(
                      onPressed: () => removeConnection(connection),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: dangerColor,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class ConnectionPainter extends CustomPainter {
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> connections;
  final List<Offset> points;

  ConnectionPainter({
    required this.devices,
    required this.connections,
    required this.points,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = primaryColor.withValues(alpha: .5)
      ..strokeWidth = 2;

    for (final connection in connections) {
      final aId = connection['deviceAId'] ?? connection['device_a_id'];
      final bId = connection['deviceBId'] ?? connection['device_b_id'];

      final a = devices.indexWhere((d) => '${d['id']}' == '$aId');
      final b = devices.indexWhere((d) => '${d['id']}' == '$bId');

      if (a >= 0 && b >= 0) {
        canvas.drawLine(points[a], points[b], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ConnectionPainter oldDelegate) => true;
}

// -----------------------------------------------------------------------------
// FAILURE SIMULATION
// -----------------------------------------------------------------------------

class SimulationPage extends StatefulWidget {
  const SimulationPage({super.key});

  @override
  State<SimulationPage> createState() => _SimulationPageState();
}

class _SimulationPageState extends State<SimulationPage> {
  List<Map<String, dynamic>> devices = [];
  int? selectedId;
  String scenario = 'Device failure';
  String report = '';

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  Future<void> loadDevices() async {
    try {
      final rows = await LocalDatabase.instance.getDevices();
      if (!mounted) return;
      setState(() {
        devices = List<Map<String, dynamic>>.from(rows);
        selectedId ??= devices.isNotEmpty ? devices.first['id'] as int : null;
      });
    } catch (error) {
      if (mounted) message(context, 'Could not load devices: $error');
    }
  }

  Map<String, dynamic>? get selectedDevice {
    for (final device in devices) {
      if (device['id'] == selectedId) return device;
    }
    return null;
  }

  void runSimulation() {
    final device = selectedDevice;

    if (device == null) {
      message(context, 'Add a device before running a simulation.');
      return;
    }

    final name = '${device['name']}';
    final type = '${device['type']}';
    final address = '${device['ipAddress']}';

    String severity;
    String impact;
    String recommendation;

    switch (scenario) {
      case 'Network congestion':
        severity = 'Warning';
        impact =
            'High traffic could cause increased latency, packet loss, or slow responses for services relying on $name.';
        recommendation =
            'Review interface utilization, QoS settings, uplink capacity, and traffic baselines.';
        break;
      case 'Service outage':
        severity = 'High';
        impact =
            'If services on $name become unavailable, applications relying on $address may experience errors or downtime.';
        recommendation =
            'Check service health, logs, dependencies, recovery procedures, and backup capacity.';
        break;
      default:
        severity = 'Critical';
        impact =
            'If $name ($type) fails, connected paths or dependent services could be interrupted. The available inventory may not show every dependency.';
        recommendation =
            'Verify dependencies and alternate routes, test failover in a lab, and document recovery procedures.';
    }

    setState(() {
      report =
          '''
TWINGUARD EDGE — SIMULATION REPORT
==================================
Scenario: $scenario
Target: $name
Type: $type
Address: $address
Current inventory status: ${device['status']}
Estimated severity: $severity

POTENTIAL IMPACT
$impact

RECOMMENDATIONS
$recommendation

LIMITATION
This is a rule-based demonstration using locally entered inventory. It is not a trained ML prediction and does not inspect live network telemetry. Validate findings before operational use.
'''
              .trim();
    });
  }

  Future<void> copyReport() async {
    if (report.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) message(context, 'Report copied.');
  }

  @override
  Widget build(BuildContext context) {
    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Failure simulation',
            subtitle:
                'Explore possible scenarios without changing live systems.',
          ),
          const SectionCard(
            child: Text(
              'These simulations are rule-based demonstrations, not live predictions or ML output.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: scenario,
            decoration: const InputDecoration(labelText: 'Scenario'),
            items:
                const ['Device failure', 'Network congestion', 'Service outage']
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
            onChanged: (value) {
              if (value != null) setState(() => scenario = value);
            },
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            initialValue: selectedId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Target device'),
            items: devices
                .map(
                  (device) => DropdownMenuItem<int>(
                    value: device['id'] as int,
                    child: Text('${device['name']} (${device['type']})'),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => selectedId = value),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: runSimulation,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run simulation'),
            ),
          ),
          if (report.isNotEmpty) ...[
            const SizedBox(height: 20),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Simulation report',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    report,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: copyReport,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy report'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SETTINGS, THEME AND LOGOUT
// -----------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onThemeChanged;
  final Future<void> Function() onLogout;

  const SettingsPage({
    super.key,
    required this.darkMode,
    required this.onThemeChanged,
    required this.onLogout,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? username;

  @override
  void initState() {
    super.initState();
    loadUser();
  }

  Future<void> loadUser() async {
    try {
      final user = await AuthService.instance.currentUser();
      if (mounted) {
        setState(() => username = user?['username'] as String?);
      }
    } catch (_) {
      // Settings can still be displayed if account details cannot be loaded.
    }
  }

  Future<void> signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your local device inventory and saved connections will remain on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Settings',
            subtitle: 'Manage your local TwinGuard Edge experience.',
          ),
          SectionCard(
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE9ECFF),
                  child: Icon(Icons.person, color: primaryColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Local account',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        username ?? 'Signed in',
                        style: const TextStyle(color: mutedColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.verified_user, color: successColor),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            padding: EdgeInsets.zero,
            child: SwitchListTile(
              value: widget.darkMode,
              onChanged: widget.onThemeChanged,
              secondary: Icon(
                widget.darkMode ? Icons.dark_mode : Icons.light_mode,
                color: primaryColor,
              ),
              title: const Text(
                'Dark mode',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Save the theme preference on this device.',
                style: TextStyle(fontSize: 11, color: mutedColor),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Heading('Privacy and storage'),
          const SectionCard(
            child: Column(
              children: [
                InfoRow(
                  Icons.cloud_off,
                  'Cloud connection',
                  'Not required',
                  successColor,
                ),
                Divider(height: 24),
                InfoRow(
                  Icons.storage,
                  'Device inventory',
                  'Local SQLite',
                  primaryColor,
                ),
                Divider(height: 24),
                InfoRow(
                  Icons.lock_outline,
                  'Password storage',
                  'Salted PBKDF2 hash',
                  successColor,
                ),
                Divider(height: 24),
                InfoRow(
                  Icons.wifi_off,
                  'Offline-first',
                  'Core screens available',
                  primaryColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Heading('About TwinGuard Edge'),
          const SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Offline-first digital twin prototype for IT infrastructure.',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 12),
                Text(
                  'Current capabilities',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6),
                Text(
                  '• Local device inventory\n'
                  '• Manual device status tracking\n'
                  '• Saved device connections\n'
                  '• Rule-based failure simulation\n'
                  '• Local account and theme preference',
                  style: TextStyle(height: 1.7, fontSize: 12),
                ),
                SizedBox(height: 10),
                Text(
                  'The simulation is rule-based. It does not yet run a trained ML model or automatically collect enterprise telemetry.',
                  style: TextStyle(color: mutedColor, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: dangerColor,
                side: const BorderSide(color: dangerColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
