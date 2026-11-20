import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';
import '../widgets.dart';

/// Onboarding: permissions → scan → pick a watch → password → connect.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _devices = <HBandDevice>[];
  final _subs = <StreamSubscription<dynamic>>[];
  HBandPermissionStatus? _permissions;
  bool _bluetoothOn = true;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(
        HBandSdk.scanResults.listen((d) {
          setState(() {
            _devices
              ..remove(d)
              ..add(d)
              ..sort((a, b) => b.rssi.compareTo(a.rssi));
          });
        }),
      )
      ..add(HBandSdk.scanFinished.listen((_) => setState(() => _scanning = false)));
    _checkState();
  }

  Future<void> _checkState() async {
    final permissions = await HBandSdk.checkPermissions();
    final on = await HBandSdk.isBluetoothEnabled();
    if (!mounted) return;
    setState(() {
      _permissions = permissions;
      _bluetoothOn = on;
    });
    if (permissions.bluetooth && on) _scan();
  }

  Future<void> _requestPermissions() async {
    final result = await HBandSdk.requestPermissions();
    if (!mounted) return;
    setState(() => _permissions = result);
    await _checkState();
  }

  Future<void> _scan() async {
    setState(() {
      _devices.clear();
      _scanning = true;
    });
    try {
      await HBandSdk.startScan(timeout: const Duration(seconds: 12));
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      if (e.code == 'BLUETOOTH_OFF') setState(() => _bluetoothOn = false);
      showSnack(context, e.message ?? e.code, error: true);
    }
  }

  Future<void> _onDeviceTap(HBandDevice device) async {
    await HBandSdk.stopScan();
    if (!mounted) return;
    final password = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PasswordSheet(device: device),
    );
    if (password == null || !mounted) return;
    final result = await showDialog<HBandConnectResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ConnectDialog(device: device, connect: () => widget.controller.connect(device, password)),
    );
    if (!mounted || result == null) return;
    if (!result.success) {
      showSnack(context, result.message ?? 'Could not connect', error: true);
    }
    // On success the app switches to the dashboard (controller.isPaired).
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    HBandSdk.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final permissions = _permissions;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _checkState,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(Icons.watch_rounded, size: 34, color: scheme.onPrimaryContainer),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Pair your watch',
                        style: Theme.of(
                          context,
                        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Keep the watch close to your phone. After pairing, SOS presses and '
                        'falls are detected automatically — even in the background.',
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
              if (permissions != null && !permissions.allGranted)
                SliverToBoxAdapter(
                  child: _NoticeCard(
                    icon: Icons.lock_open_rounded,
                    title: 'Permissions needed',
                    message: [
                      if (!permissions.bluetooth) 'Bluetooth — to find and connect to the watch',
                      if (!permissions.notification) 'Notifications — to alert you on SOS / fall',
                    ].join('\n'),
                    action: 'Allow',
                    onAction: _requestPermissions,
                  ),
                ),
              if (!_bluetoothOn)
                SliverToBoxAdapter(
                  child: _NoticeCard(
                    icon: Icons.bluetooth_disabled_rounded,
                    title: 'Bluetooth is off',
                    message: 'Turn on Bluetooth in system settings, then pull down to retry.',
                    color: AppColors.warning,
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: SectionTitle(
                    _scanning ? 'Searching…' : 'Nearby watches',
                    trailing: _scanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                ),
              ),
              if (_devices.isEmpty)
                SliverToBoxAdapter(child: _EmptyScan(scanning: _scanning))
              else
                SliverList.separated(
                  itemCount: _devices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _DeviceCard(device: _devices[i], onTap: () => _onDeviceTap(_devices[i])),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FilledButton.icon(
          onPressed: _scanning
              ? () => HBandSdk.stopScan()
              : (permissions?.bluetooth ?? false)
              ? _scan
              : _requestPermissions,
          icon: Icon(_scanning ? Icons.stop_rounded : Icons.bluetooth_searching_rounded),
          label: Text(_scanning ? 'Stop scanning' : 'Scan for watches'),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.onTap});

  final HBandDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.watch_outlined, color: scheme.onSecondaryContainer),
        ),
        title: Text(device.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(device.deviceId, style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SignalBars(rssi: device.rssi),
            const SizedBox(width: 8),
            Text('${device.rssi}', style: TextStyle(color: scheme.outline, fontSize: 12)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _EmptyScan extends StatelessWidget {
  const _EmptyScan({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        children: [
          Icon(scanning ? Icons.radar_rounded : Icons.watch_off_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            scanning ? 'Looking for watches nearby…' : 'No watch found yet',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Make sure the watch is on and not connected to another phone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
    this.color,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(message, style: const TextStyle(height: 1.4)),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: onAction,
                child: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 4-digit password entry (factory default 0000).
class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.device});

  final HBandDevice device;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _controller = TextEditingController(text: '0000');

  bool get _valid => RegExp(r'^\d{4}$').hasMatch(_controller.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.viewInsetsOf(context).bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connect to ${widget.device.name}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Enter the 4-digit watch password. The factory default is 0000. '
            'Your watch may ask you to confirm the connection.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 18, fontWeight: FontWeight.w700),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(counterText: '', hintText: '••••'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _valid ? Navigator.pop(context, _controller.text) : null,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _valid ? () => Navigator.pop(context, _controller.text) : null,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

/// Shows live connection steps while [connect] runs.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.device, required this.connect});

  final HBandDevice device;
  final Future<HBandConnectResult> Function() connect;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  HBandConnectionStatus _status = HBandConnectionStatus.connecting;
  StreamSubscription<HBandConnectionState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = HBandSdk.connectionState.listen((s) => setState(() => _status = s.status));
    widget.connect().then((result) {
      if (mounted) Navigator.pop(context, result);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = switch (_status) {
      HBandConnectionStatus.connecting => 0,
      HBandConnectionStatus.verifying => 1,
      HBandConnectionStatus.ready => 2,
      _ => 0,
    };
    Widget row(int index, String label) {
      final done = step > index;
      final active = step == index;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: done
                  ? const Icon(Icons.check_circle_rounded, color: AppColors.ok)
                  : active
                  ? const CircularProgressIndicator(strokeWidth: 2.5)
                  : Icon(Icons.circle_outlined, color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontWeight: active ? FontWeight.w700 : FontWeight.w400)),
          ],
        ),
      );
    }

    return AlertDialog(
      title: Text(widget.device.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(0, 'Connecting over Bluetooth'),
          row(1, 'Verifying password & syncing'),
          row(2, 'Starting SOS & fall guard'),
          const SizedBox(height: 8),
          Text(
            'Confirm the connection on the watch if it asks.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
