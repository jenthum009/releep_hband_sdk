import 'package:flutter/material.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';
import '../widgets.dart';

/// Webhook, background behaviour, diagnostics and "forget watch".
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url = TextEditingController(text: c.webhook.url);
  bool _ignoringBattery = true;
  bool _testing = false;

  GuardController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    HBandSdk.isIgnoringBatteryOptimizations().then((v) {
      if (mounted) setState(() => _ignoringBattery = v);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  bool _validUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
  }

  Future<void> _saveUrl() async {
    final value = _url.text.trim();
    if (value.isNotEmpty && !_validUrl(value)) {
      showSnack(context, 'Enter a valid http(s) URL', error: true);
      return;
    }
    await c.saveWebhook(url: value, enabled: value.isNotEmpty ? true : false);
    if (mounted) showSnack(context, value.isEmpty ? 'Webhook removed' : 'Webhook saved');
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final result = await HBandSdk.testWebhook();
    if (!mounted) return;
    setState(() => _testing = false);
    showSnack(
      context,
      result.success ? 'OK · ${result.message}' : 'Failed · ${result.message}',
      error: !result.success,
    );
  }

  Future<void> _setCallSos(bool enabled) async {
    final granted = await c.setCallSos(enabled);
    if (mounted && !granted) showSnack(context, 'Phone permission is needed for call-based SOS', error: true);
  }

  Future<void> _forget() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_off_rounded),
        title: const Text('Forget this watch?'),
        content: const Text(
          'The watch is disconnected, the saved session is deleted and background '
          'guarding stops until you pair a watch again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.emergency, minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await c.forget();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SectionTitle('Webhook'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Every SOS / fall event is POSTed as JSON to this URL, '
                      'also while the app is in the background.',
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        hintText: 'https://example.com/hooks/watch',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                      onSubmitted: (_) => _saveUrl(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(onPressed: _saveUrl, child: const Text('Save')),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: c.webhook.url.isEmpty || _testing ? null : _test,
                            child: Text(_testing ? 'Sending…' : 'Send test'),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Send events'),
                      subtitle: Text(c.webhook.url.isEmpty ? 'Add a URL first' : 'Deliver events to the URL'),
                      value: c.webhook.enabled && c.webhook.url.isNotEmpty,
                      onChanged: c.webhook.url.isEmpty ? null : (v) => c.saveWebhook(enabled: v),
                    ),
                  ],
                ),
              ),
            ),
            const SectionTitle('Background'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.shield_outlined),
                    title: const Text('SOS & fall guard'),
                    subtitle: Text(
                      c.isAndroid
                          ? 'Foreground service keeps the watch connected'
                          : 'Bluetooth background mode keeps alerts flowing',
                    ),
                    value: c.session?.guardEnabled ?? false,
                    onChanged: c.setGuard,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.phone_forwarded_rounded),
                    title: const Text('SOS from watch call'),
                    subtitle: const Text(
                      'Outgoing calls while the watch is the call headset count as SOS — for watches that only dial (e.g. VANTA)',
                    ),
                    value: c.session?.callSosDetection ?? false,
                    onChanged: c.session == null ? null : _setCallSos,
                  ),
                  if (c.isAndroid)
                    ListTile(
                      leading: Icon(
                        _ignoringBattery ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
                        color: _ignoringBattery ? AppColors.ok : AppColors.warning,
                      ),
                      title: const Text('Allow background run'),
                      subtitle: Text(
                        _ignoringBattery
                            ? 'Battery optimisation is off for this app'
                            : 'Recommended — some phones (realme, Xiaomi…) kill background apps',
                      ),
                      trailing: _ignoringBattery ? null : const Icon(Icons.chevron_right_rounded),
                      onTap: _ignoringBattery
                          ? null
                          : () async {
                              await HBandSdk.requestIgnoreBatteryOptimizations();
                            },
                    ),
                  if (!c.isAndroid)
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: const Text('Keep the app open in the background'),
                      subtitle: const Text(
                        'iOS stops background Bluetooth if you swipe the app away from the app switcher.',
                      ),
                    ),
                ],
              ),
            ),
            const SectionTitle('Watch'),
            Card(
              child: Column(
                children: [
                  _InfoRow('Name', c.session?.name ?? '—'),
                  _InfoRow('Device ID', c.session?.deviceId ?? '—'),
                  _InfoRow('Serial (device no.)', c.session?.serial ?? '—'),
                  _InfoRow('Firmware', c.session?.firmware ?? '—'),
                  _InfoRow('Firmware (test)', c.session?.firmwareTest ?? '—'),
                  ListTile(
                    leading: const Icon(Icons.refresh_rounded),
                    title: const Text('Refresh battery'),
                    onTap: c.connection.isReady ? c.refreshBattery : null,
                  ),
                ],
              ),
            ),
            if (c.isAndroid) ...[
              const SectionTitle('Diagnostics'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.terminal_rounded),
                  title: const Text('Raw BLE frames'),
                  subtitle: const Text('Everything the watch sends — SOS frame starts with 8F,08,03'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _RawFramesPage())),
                ),
              ),
            ],
            const SectionTitle('Danger zone'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('Clear activity'),
                    onTap: c.clearEvents,
                  ),
                  ListTile(
                    leading: const Icon(Icons.link_off_rounded, color: AppColors.emergency),
                    title: const Text(
                      'Forget / change watch',
                      style: TextStyle(color: AppColors.emergency, fontWeight: FontWeight.w600),
                    ),
                    onTap: _forget,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: SelectableText(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _RawFramesPage extends StatefulWidget {
  const _RawFramesPage();

  @override
  State<_RawFramesPage> createState() => _RawFramesPageState();
}

class _RawFramesPageState extends State<_RawFramesPage> {
  ({List<String> incoming, List<String> outgoing})? _frames;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final frames = await HBandSdk.getRawFrames(lines: 40);
    if (mounted) setState(() => _frames = frames);
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.5);
    Widget block(String title, List<String> lines) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (lines.isEmpty) const Text('(no frames yet)', style: mono),
            for (final l in lines)
              Text(
                l,
                style: mono.copyWith(
                  color: l.contains('8F,08,03,') ? AppColors.emergency : null,
                  fontWeight: l.contains('8F,08,03,') ? FontWeight.w700 : null,
                ),
              ),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Raw BLE frames'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: frames == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                block('◄ Watch → phone', frames.incoming),
                const SizedBox(height: 12),
                block('► Phone → watch', frames.outgoing),
              ],
            ),
    );
  }
}
