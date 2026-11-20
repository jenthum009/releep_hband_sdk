import 'dart:async';

import 'package:flutter/material.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import 'guard_controller.dart';
import 'pages/dashboard_page.dart';
import 'pages/emergency_page.dart';
import 'pages/scan_page.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GuardApp(controller: GuardController()));
}

class GuardApp extends StatefulWidget {
  const GuardApp({super.key, required this.controller});

  final GuardController controller;

  @override
  State<GuardApp> createState() => _GuardAppState();
}

class _GuardAppState extends State<GuardApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<HBandEvent>? _emergencySub;
  String? _showingEmergencyId;

  GuardController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _emergencySub = controller.emergencies.listen(_showEmergency);
    controller.init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Events may have arrived while the UI was in the background.
    if (state == AppLifecycleState.resumed && controller.initialized) controller.refreshAll();
  }

  void _showEmergency(HBandEvent event) {
    final nav = _navigator.currentState;
    if (nav == null || _showingEmergencyId == event.id) return;
    _showingEmergencyId = event.id;
    nav
        .push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => EmergencyPage(event: event, controller: controller),
          ),
        )
        .whenComplete(() => _showingEmergencyId = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _emergencySub?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watch Guard',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.initialized) return const _Splash();
          return controller.isPaired
              ? DashboardPage(controller: controller)
              : ScanPage(controller: controller);
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, size: 64, color: AppColors.brand),
            SizedBox(height: 16),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
