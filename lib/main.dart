import 'dart:async';
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
import 'services/wifi_discovery_api_service.dart';
import 'database/local_database.dart';
import 'pages/wifi_discovery_page.dart';
import 'pages/vlan_management_page.dart';

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
// MAIN NAVIGATION — FIVE BOTTOM BUTTONS
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
  static const int dashboardPage = 0;
  static const int networkPage = 1;
  static const int topologyPage = 2;
  static const int simulationPage = 3;
  static const int campusPage = 4;
  static const int monitoringPage = 5;
  static const int discoveryPage = 6;
  static const int settingsPage = 7;
  static const int vlanPage = 8;
  static const int morePage = 9;

  int activePage = dashboardPage;

  static const List<int> navigationPages = [
    dashboardPage,
    topologyPage,
    discoveryPage,
    monitoringPage,
    morePage,
  ];

  void openPage(int page) {
    setState(() => activePage = page);
  }

  String get pageTitle {
    switch (activePage) {
      case networkPage:
        return 'Network Inventory';
      case simulationPage:
        return 'Failure Simulation';
      case settingsPage:
        return 'Settings';
      case vlanPage:
        return 'VLAN Management';
      case morePage:
        return 'More Features';
      default:
        return 'TwinGuard Edge';
    }
  }

  int get selectedNavigationIndex {
    switch (activePage) {
      case dashboardPage:
        return 0;
      case topologyPage:
        return 1;
      case discoveryPage:
        return 2;
      case monitoringPage:
        return 3;
      default:
        return 4;
    }
  }

  PreferredSizeWidget? buildAppBar() {
    // These pages already provide their own app bars.
    if (activePage == campusPage ||
        activePage == monitoringPage ||
        activePage == discoveryPage) {
      return null;
    }

    final isSecondaryPage = [
      networkPage,
      simulationPage,
      settingsPage,
      vlanPage,
    ].contains(activePage);

    return AppBar(
      automaticallyImplyLeading: false,
      leading: isSecondaryPage
          ? IconButton(
              tooltip: 'Back to More',
              onPressed: () => openPage(morePage),
              icon: const Icon(Icons.arrow_back),
            )
          : null,
      title: activePage == morePage || isSecondaryPage
          ? Text(
              pageTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            )
          : const Row(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
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
      const VlanManagementPage(),
      MoreFeaturesPage(onOpenPage: openPage),
    ];

    return Scaffold(
      appBar: buildAppBar(),
      body: IndexedStack(index: activePage, children: pages),
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        selectedIndex: selectedNavigationIndex,
        onDestinationSelected: (value) {
          openPage(navigationPages[value]);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: 'Topology',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_find_outlined),
            selectedIcon: Icon(Icons.wifi_find),
            label: 'Discovery',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Monitor',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_rounded),
            selectedIcon: Icon(Icons.grid_view),
            label: 'More',
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
    case 'completed':
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

  Map<String, dynamic>? _monitorStatus;
  String? _monitorError;
  bool _monitorLoading = true;
  bool _monitorFetching = false;
  Timer? _monitorTimer;
  late final WifiDiscoveryApiService _api;

  @override
  void initState() {
    super.initState();
    _api = WifiDiscoveryApiService();
    refresh();
    _loadMonitorStatus();
    _monitorTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadMonitorStatus(),
    );
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

  Future<void> _loadMonitorStatus() async {
    if (_monitorFetching) return;
    _monitorFetching = true;

    try {
      final decoded = await _api.fetchMonitorStatus();
      if (!mounted) return;

      setState(() {
        _monitorStatus = decoded;
        _monitorError = null;
        _monitorLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _monitorError = error.toString();
        _monitorLoading = false;
      });
    } finally {
      _monitorFetching = false;
    }
  }

  String _monitorTime(dynamic value) {
    if (value == null || '$value'.trim().isEmpty) return 'Not scanned yet';
    try {
      return DateTime.parse('$value').toLocal().toString().split('.').first;
    } catch (_) {
      return '$value';
    }
  }

  Widget _networkMonitorCard() {
    final status = _monitorStatus ?? <String, dynamic>{};
    final rawNetwork = status['network'];
    final network = rawNetwork is Map
        ? Map<String, dynamic>.from(rawNetwork)
        : <String, dynamic>{};

    final enabled = status['enabled'] == true;
    final connected = status['connected'] == true;
    final active = enabled && connected;
    final scanStatus = '${status['scan_status'] ?? 'unknown'}';
    final networkName =
        network['network_name'] ?? network['ssid'] ?? 'No network detected';
    final gateway = network['gateway'] ?? 'Unavailable';
    final subnet = network['subnet'] ?? 'Unavailable';
    final interval = status['poll_interval_seconds'] ?? 10;

    final monitorLabel = !enabled
        ? 'Monitor stopped'
        : !connected
        ? 'Waiting for Wi-Fi'
        : 'Monitoring active';

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi_tethering, color: primaryColor),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'Automatic Network Monitor',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Refresh monitor status',
                onPressed: _monitorFetching ? null : _loadMonitorStatus,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_monitorLoading && _monitorStatus == null)
            const LinearProgressIndicator()
          else if (_monitorStatus == null)
            Text(
              _monitorError ?? 'Monitor status is unavailable.',
              style: const TextStyle(color: dangerColor, fontSize: 12),
            )
          else ...[
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: active ? successColor : warningColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    monitorLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: active ? successColor : warningColor,
                    ),
                  ),
                ),
                statusBadge(scanStatus),
              ],
            ),
            const Divider(height: 24),
            InfoRow(
              Icons.wifi,
              'Connected network',
              '$networkName',
              primaryColor,
            ),
            const SizedBox(height: 12),
            InfoRow(Icons.router_outlined, 'Gateway', '$gateway', mutedColor),
            const SizedBox(height: 12),
            InfoRow(Icons.lan_outlined, 'Subnet', '$subnet', mutedColor),
            const SizedBox(height: 12),
            InfoRow(
              Icons.refresh_rounded,
              'Network check interval',
              '$interval sec',
              mutedColor,
            ),
            const SizedBox(height: 12),
            InfoRow(
              Icons.schedule,
              'Last automatic scan',
              _monitorTime(status['last_scan_at']),
              mutedColor,
            ),
            if (_monitorError != null) ...[
              const SizedBox(height: 10),
              Text(
                'Latest refresh issue: $_monitorError',
                style: const TextStyle(color: dangerColor, fontSize: 11),
              ),
            ],
          ],
          const SizedBox(height: 8),
          const Text(
            'The laptop performs discovery. This card displays the backend monitor status; it does not mean every device on the Wi-Fi network is visible.',
            style: TextStyle(color: mutedColor, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _api.dispose();
    super.dispose();
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
          const Heading('Remote network monitoring'),
          _networkMonitorCard(),
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
            label: const Text('Refresh local inventory'),
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
// AUTOMATIC WI-FI NETWORK TOPOLOGY — DIAGRAM VIEW
// -----------------------------------------------------------------------------

class TopologyPage extends StatefulWidget {
  const TopologyPage({super.key});

  @override
  State<TopologyPage> createState() => _TopologyPageState();
}

class _TopologyPageState extends State<TopologyPage> {
  late final WifiDiscoveryApiService _api;

  Map<String, dynamic>? _scan;
  String? _lastNetworkId;
  String? _error;

  bool _loading = true;
  bool _scanning = false;
  bool _checkingMonitor = false;
  bool? _monitorConnected;
  DateTime? _lastDiscoveryAt;

  static const Duration _sameNetworkRefreshInterval = Duration(seconds: 60);
  Timer? _monitorTimer;

  @override
  void initState() {
    super.initState();
    _api = WifiDiscoveryApiService();
    _loadDiscovery();
    _monitorTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _checkForNetworkChange(),
    );
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> _loadDiscovery() async {
    if (_scanning) return;
    if (mounted) {
      setState(() {
        _scanning = true;
        _error = null;
        if (_scan == null) _loading = true;
      });
    }

    try {
      final result = await _api.discoverDevices();
      final network = _asMap(result['network']);
      final devices = _asMapList(result['devices']);

      if (network.isEmpty || network['network_id'] == null) {
        throw const FormatException(
          'Discovery response does not contain network identity.',
        );
      }
      if (!mounted) return;

      setState(() {
        _scan = result;
        _lastNetworkId = '${network['network_id']}';
        _monitorConnected = true;
        _lastDiscoveryAt = DateTime.now();
        _error = null;
      });

      debugPrint(
        '[TwinGuard] Diagram updated for '
        '${network['network_name'] ?? network['ssid']}: ${devices.length} devices',
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _checkForNetworkChange() async {
    if (_checkingMonitor || _scanning) return;
    _checkingMonitor = true;

    try {
      final status = await _api.fetchMonitorStatus();
      final connected = status['connected'] == true;
      final statusNetwork = _asMap(status['network']);
      final currentNetworkId =
          status['network_id']?.toString() ??
          statusNetwork['network_id']?.toString();

      if (!mounted) return;
      setState(() => _monitorConnected = connected);
      if (!connected || currentNetworkId == null) return;

      if (currentNetworkId != _lastNetworkId) {
        debugPrint('[TwinGuard] Network changed; refreshing topology.');
        await _loadDiscovery();
        return;
      }

      final lastScan = _lastDiscoveryAt;
      if (lastScan == null ||
          DateTime.now().difference(lastScan) >= _sameNetworkRefreshInterval) {
        debugPrint('[TwinGuard] Refreshing devices on the current network.');
        await _loadDiscovery();
      }
    } catch (error) {
      debugPrint('[TwinGuard] Monitor status check failed: $error');
    } finally {
      _checkingMonitor = false;
    }
  }

  String _formatTime(dynamic value) {
    if (value == null) return 'Not available';
    try {
      return DateTime.parse('$value').toLocal().toString().split('.').first;
    } catch (_) {
      return '$value';
    }
  }

  Widget _networkInformation(
    Map<String, dynamic> network,
    Map<String, dynamic> interface,
  ) {
    final networkName =
        network['network_name'] ?? network['ssid'] ?? 'Unknown network';
    final networkId = '${network['network_id'] ?? 'Unknown'}';
    final gateway = '${network['gateway'] ?? 'Unknown'}';
    final subnet = '${network['subnet'] ?? 'Unknown'}';
    final laptopIp = '${interface['ip_address'] ?? 'Unknown'}';

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi, color: primaryColor),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '$networkName',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              statusBadge(
                _monitorConnected == false ? 'disconnected' : 'connected',
              ),
            ],
          ),
          const Divider(height: 24),
          InfoRow(Icons.router, 'Gateway', gateway, primaryColor),
          const SizedBox(height: 12),
          InfoRow(Icons.lan, 'Subnet', subnet, mutedColor),
          const SizedBox(height: 12),
          InfoRow(Icons.computer, 'Scanner laptop IP', laptopIp, mutedColor),
          const SizedBox(height: 12),
          InfoRow(
            Icons.fingerprint,
            'Network ID',
            networkId.length > 22
                ? '${networkId.substring(0, 19)}...'
                : networkId,
            mutedColor,
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 10, color: mutedColor)),
      ],
    );
  }

  Widget _buildNetworkDiagram(
    Map<String, dynamic> network,
    Map<String, dynamic> interface,
    List<Map<String, dynamic>> devices,
  ) {
    final gatewayIp = '${network['gateway'] ?? ''}';
    final laptopIp = '${interface['ip_address'] ?? ''}';

    Map<String, dynamic>? gatewayDevice;
    for (final device in devices) {
      if (device['is_gateway'] == true ||
          '${device['ip_address'] ?? ''}' == gatewayIp) {
        gatewayDevice = device;
        break;
      }
    }

    final endpoints = devices.where((device) {
      final ip = '${device['ip_address'] ?? ''}';
      final isGateway = device['is_gateway'] == true || ip == gatewayIp;
      final isLaptop = laptopIp.isNotEmpty && ip == laptopIp;
      return !isGateway && !isLaptop;
    }).toList();

    // The laptop is included as the discovery source, followed by the
    // endpoints that the laptop could observe on this network.
    final nodes = <_TopologyDiagramNodeData>[
      _TopologyDiagramNodeData(
        title: 'TwinGuard Scanner Laptop',
        ipAddress: laptopIp.isEmpty ? 'IP unavailable' : laptopIp,
        macAddress: '${interface['mac_address'] ?? 'MAC unavailable'}',
        status: 'SCANNER',
        detail: 'Discovery source',
        icon: Icons.laptop_windows_rounded,
        color: successColor,
      ),
      ...endpoints.map((device) {
        final trusted =
            device['is_trusted'] == true ||
            '${device['classification'] ?? ''}'.toLowerCase() == 'trusted';
        final classification =
            '${device['classification'] ?? (trusted ? 'trusted' : 'unknown')}';
        final responsive =
            device['responsive'] == true ||
            device['is_responsive'] == true ||
            device['icmp_responsive'] == true;
        final status = trusted
            ? 'TRUSTED'
            : (responsive ? 'RESPONSIVE' : classification.toUpperCase());
        final title =
            device['hostname'] ??
            device['device_name'] ??
            device['name'] ??
            device['vendor'] ??
            'Network device';

        return _TopologyDiagramNodeData(
          title: '$title',
          ipAddress: '${device['ip_address'] ?? 'IP unavailable'}',
          macAddress: '${device['mac_address'] ?? 'MAC unavailable'}',
          status: status,
          detail: classification,
          icon: trusted ? Icons.verified_user_rounded : Icons.devices_rounded,
          color: trusted
              ? successColor
              : (responsive ? primaryColor : warningColor),
        );
      }),
    ];

    final gatewayMac = '${gatewayDevice?['mac_address'] ?? 'Not discovered'}';
    final gatewayName =
        '${network['network_name'] ?? network['ssid'] ?? 'Wi-Fi Gateway'}';
    final gatewayStatus = _monitorConnected == false ? 'OFFLINE' : 'GATEWAY';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Heading(
          'Network diagram',
          subtitle:
              'A visual map of the gateway and devices observed on this network.',
        ),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            _legendItem(primaryColor, 'Gateway'),
            _legendItem(successColor, 'Scanner / trusted'),
            _legendItem(warningColor, 'Unverified'),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 720 ? 3 : 2;
            const sidePadding = 8.0;
            const columnGap = 10.0;
            final cardWidth =
                (width - (sidePadding * 2) - (columnGap * (columns - 1))) /
                columns;
            final rows = (nodes.length / columns).ceil();
            const gatewayTop = 22.0;
            const gatewayHeight = 128.0;
            const firstBusY = 190.0;
            const firstNodeTop = 220.0;
            const rowGap = 166.0;
            const nodeHeight = 132.0;
            final diagramHeight =
                firstNodeTop + ((rows - 1) * rowGap) + nodeHeight + 24;

            final centers = <Offset>[];
            for (var i = 0; i < nodes.length; i++) {
              final column = i % columns;
              final row = i ~/ columns;
              final left = sidePadding + column * (cardWidth + columnGap);
              centers.add(
                Offset(left + cardWidth / 2, firstNodeTop + row * rowGap),
              );
            }

            return Container(
              height: math.min(diagramHeight, 690.0).toDouble(),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 2.2,
                boundaryMargin: const EdgeInsets.all(28),
                child: SizedBox(
                  width: width,
                  height: diagramHeight,
                  child: Stack(
                    children: [
                      CustomPaint(
                        size: Size(width, diagramHeight),
                        painter: _NetworkDiagramPainter(
                          nodeCenters: centers,
                          columns: columns,
                          firstBusY: firstBusY,
                          firstNodeTop: firstNodeTop,
                          rowGap: rowGap,
                          color: primaryColor.withValues(alpha: 0.55),
                        ),
                      ),
                      Positioned(
                        top: gatewayTop,
                        left:
                            (width - math.min(width - 24, 330.0).toDouble()) /
                            2,
                        width: math.min(width - 24, 330.0).toDouble(),
                        height: gatewayHeight,
                        child: _TopologyDiagramCard(
                          title: gatewayName,
                          subtitle: 'DEFAULT GATEWAY · NETWORK ROOT',
                          ipAddress: gatewayIp.isEmpty
                              ? 'IP unavailable'
                              : gatewayIp,
                          macAddress: gatewayMac,
                          status: gatewayStatus,
                          icon: Icons.router_rounded,
                          color: primaryColor,
                          compact: false,
                        ),
                      ),
                      for (var i = 0; i < nodes.length; i++)
                        Positioned(
                          left:
                              sidePadding +
                              (i % columns) * (cardWidth + columnGap),
                          top: firstNodeTop + (i ~/ columns) * rowGap,
                          width: cardWidth,
                          height: nodeHeight,
                          child: _TopologyDiagramCard(
                            title: nodes[i].title,
                            subtitle: nodes[i].detail,
                            ipAddress: nodes[i].ipAddress,
                            macAddress: nodes[i].macAddress,
                            status: nodes[i].status,
                            icon: nodes[i].icon,
                            color: nodes[i].color,
                            compact: true,
                          ),
                        ),
                      Positioned(
                        top: 4,
                        right: 8,
                        child: Text(
                          'LOGICAL MEMBERSHIP VIEW',
                          style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 0.8,
                            color: mutedColor.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 9),
        const Text(
          'Connection lines show inferred membership on the same discovered network. They do not prove direct cabling, switch ports, or physical device-to-device links. Pinch to zoom and drag to inspect the diagram.',
          style: TextStyle(fontSize: 10, color: mutedColor, height: 1.5),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan ?? <String, dynamic>{};
    final network = _asMap(scan['network']);
    final interface = _asMap(scan['interface']);
    final summary = _asMap(scan['summary']);
    final devices = _asMapList(scan['devices']);
    final history = _asMap(scan['history']);

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'Automatic Network Topology',
            subtitle:
                'Explore discovered network members in a zoomable diagram.',
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _scanning ? null : _loadDiscovery,
              icon: _scanning
                  ? const SizedBox(
                      height: 17,
                      width: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.radar_rounded),
              label: Text(
                _scanning ? 'Scanning network...' : 'Scan and update diagram',
              ),
            ),
          ),
          const SizedBox(height: 15),
          if (_loading && _scan == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_scan == null)
            SectionCard(
              child: Column(
                children: [
                  const Icon(Icons.wifi_off, color: dangerColor, size: 40),
                  const SizedBox(height: 12),
                  const Text(
                    'Network discovery unavailable',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error ?? 'Could not retrieve network data.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: mutedColor, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : _loadDiscovery,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ],
              ),
            )
          else ...[
            _networkInformation(network, interface),
            const SizedBox(height: 18),
            const Heading('Discovery summary'),
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
                        title: 'Discovered',
                        value:
                            '${summary['discovered_devices'] ?? devices.length}',
                        description: 'Visible devices',
                        icon: Icons.devices,
                        color: primaryColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Responsive',
                        value: '${summary['responsive_devices'] ?? 0}',
                        description: 'Responded to scan',
                        icon: Icons.check_circle_outline,
                        color: successColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Trusted',
                        value: '${summary['trusted_devices'] ?? 0}',
                        description: 'Approved on this network',
                        icon: Icons.verified_user,
                        color: successColor,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: MetricCard(
                        title: 'Unknown',
                        value: '${summary['unknown_devices'] ?? 0}',
                        description: 'Not approved',
                        icon: Icons.help_outline,
                        color: warningColor,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 22),
            _buildNetworkDiagram(network, interface, devices),
            const SizedBox(height: 18),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Scan information',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  InfoRow(
                    Icons.schedule,
                    'Last scan',
                    _formatTime(history['scan_time']),
                    mutedColor,
                  ),
                  const Divider(height: 24),
                  InfoRow(
                    Icons.history,
                    'Total network scans',
                    '${history['scan_count'] ?? 0}',
                    primaryColor,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Latest scan issue: $_error',
                      style: const TextStyle(color: dangerColor, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TopologyDiagramNodeData {
  final String title;
  final String ipAddress;
  final String macAddress;
  final String status;
  final String detail;
  final IconData icon;
  final Color color;

  const _TopologyDiagramNodeData({
    required this.title,
    required this.ipAddress,
    required this.macAddress,
    required this.status,
    required this.detail,
    required this.icon,
    required this.color,
  });
}

class _TopologyDiagramCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String ipAddress;
  final String macAddress;
  final String status;
  final IconData icon;
  final Color color;
  final bool compact;

  const _TopologyDiagramCard({
    required this.title,
    required this.subtitle,
    required this.ipAddress,
    required this.macAddress,
    required this.status,
    required this.icon,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      padding: EdgeInsets.all(compact ? 9 : 12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.3),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: compact ? 27 : 34,
                height: compact ? 27 : 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: compact ? 16 : 20),
              ),
              const Spacer(),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: compact ? 7 : 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 5 : 7),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 10 : 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 8 : 9,
              color: mutedColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Icon(Icons.language, size: compact ? 10 : 12, color: mutedColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ipAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: compact ? 8 : 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                Icons.fingerprint,
                size: compact ? 10 : 12,
                color: mutedColor,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  macAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 7 : 9,
                    color: mutedColor,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NetworkDiagramPainter extends CustomPainter {
  final List<Offset> nodeCenters;
  final int columns;
  final double firstBusY;
  final double firstNodeTop;
  final double rowGap;
  final Color color;

  const _NetworkDiagramPainter({
    required this.nodeCenters,
    required this.columns,
    required this.firstBusY,
    required this.firstNodeTop,
    required this.rowGap,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodeCenters.isEmpty) return;

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final rowCount = (nodeCenters.length / columns).ceil();
    final lastBusY = firstBusY + (rowCount - 1) * rowGap;

    // Gateway down to the logical distribution spine.
    canvas.drawLine(Offset(centerX, 150), Offset(centerX, lastBusY), linePaint);

    for (var row = 0; row < rowCount; row++) {
      final start = row * columns;
      final end = math.min(start + columns, nodeCenters.length).toInt();
      final rowNodes = nodeCenters.sublist(start, end);
      final busY = firstBusY + row * rowGap;
      final firstX = rowNodes.first.dx;
      final lastX = rowNodes.last.dx;

      // Extend each row bus back to the central spine, including a row with
      // only one endpoint (for example, a network with just the scanner).
      final busStart = math.min(firstX, centerX).toDouble();
      final busEnd = math.max(lastX, centerX).toDouble();
      canvas.drawLine(Offset(busStart, busY), Offset(busEnd, busY), linePaint);

      canvas.drawCircle(Offset(centerX, busY), 4, dotPaint);

      for (final node in rowNodes) {
        canvas.drawLine(
          Offset(node.dx, busY),
          Offset(node.dx, firstNodeTop + (row * rowGap) - 4),
          linePaint,
        );
        canvas.drawCircle(Offset(node.dx, busY), 3.2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkDiagramPainter oldDelegate) =>
      oldDelegate.nodeCenters != nodeCenters ||
      oldDelegate.columns != columns ||
      oldDelegate.firstBusY != firstBusY ||
      oldDelegate.firstNodeTop != firstNodeTop ||
      oldDelegate.rowGap != rowGap ||
      oldDelegate.color != color;
}

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

// -----------------------------------------------------------------------------
// MORE FEATURES PAGE
// -----------------------------------------------------------------------------

class MoreFeaturesPage extends StatelessWidget {
  final ValueChanged<int> onOpenPage;

  const MoreFeaturesPage({super.key, required this.onOpenPage});

  Widget _featureCard({
    required String title,
    required String description,
    required IconData icon,
    required int? pageIndex,
    bool upcoming = false,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: pageIndex == null ? null : () => onOpenPage(pageIndex),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    color: upcoming ? mutedColor : primaryColor,
                    size: 25,
                  ),
                  const Spacer(),
                  if (upcoming)
                    const Text(
                      'PLANNED',
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  else
                    const Icon(
                      Icons.arrow_forward_ios,
                      size: 13,
                      color: mutedColor,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: mutedColor,
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableFeatures = [
      (
        title: 'Network Inventory',
        description: 'Manage routers, switches and devices.',
        icon: Icons.devices,
        page: 1,
      ),
      (
        title: 'VLAN Management',
        description: 'Configure VLANs and device assignments.',
        icon: Icons.account_tree,
        page: 8,
      ),
      (
        title: 'Failure Simulation',
        description: 'Explore infrastructure failure scenarios.',
        icon: Icons.science,
        page: 3,
      ),
      (
        title: 'Campus Overview',
        description: 'View campus infrastructure.',
        icon: Icons.business,
        page: 4,
      ),
      (
        title: 'Settings',
        description: 'Manage account, theme and application.',
        icon: Icons.settings,
        page: 7,
      ),
    ];

    final upcomingFeatures = [
      (
        title: 'Recursive Discovery',
        description: 'Discover connected routers and switches.',
        icon: Icons.device_hub,
      ),
      (
        title: 'LLDP / CDP / SNMP',
        description: 'Neighbor and interface discovery.',
        icon: Icons.cable,
      ),
      (
        title: 'Anomaly Detection',
        description: 'Identify unusual network activity.',
        icon: Icons.shield_outlined,
      ),
      (
        title: 'ML Fault Prediction',
        description: 'Predict infrastructure failures.',
        icon: Icons.psychology,
      ),
      (
        title: 'Port Mapping',
        description: 'Map interfaces and connected devices.',
        icon: Icons.settings_ethernet,
      ),
      (
        title: 'Security Management',
        description: 'Advanced security monitoring.',
        icon: Icons.security,
      ),
      (
        title: 'Analytics & Reports',
        description: 'Network performance reporting.',
        icon: Icons.analytics,
      ),
    ];

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Heading(
            'More Features',
            subtitle: 'Access all TwinGuard Edge modules.',
          ),
          const Heading('Available Features'),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 650 ? 3 : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: availableFeatures.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.4,
                ),
                itemBuilder: (context, index) {
                  final feature = availableFeatures[index];
                  return _featureCard(
                    title: feature.title,
                    description: feature.description,
                    icon: feature.icon,
                    pageIndex: feature.page,
                  );
                },
              );
            },
          ),
          const SizedBox(height: 24),
          const Heading(
            'Upcoming Features',
            subtitle: 'Planned enterprise networking capabilities.',
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 650 ? 3 : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: upcomingFeatures.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.4,
                ),
                itemBuilder: (context, index) {
                  final feature = upcomingFeatures[index];
                  return _featureCard(
                    title: feature.title,
                    description: feature.description,
                    icon: feature.icon,
                    pageIndex: null,
                    upcoming: true,
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
