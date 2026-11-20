import 'package:flutter/material.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';
import '../widgets.dart';
import 'emergency_page.dart';
import 'health_page.dart';
import 'settings_page.dart';
import 'sos_setup_page.dart';

/// Home once a watch is paired: watch status, guard switch, live event feed.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _alertsOnly = false;
  bool _busy = false;

  GuardController get c => widget.controller;

  Future<void> _simulate() async {
    await HBandSdk.simulateEmergency(label: 'Test alert from the app');
  }

  Future<void> _testWebhook() async {
    if (c.webhook.url.isEmpty) {
      showSnack(context, 'Set a webhook URL in Settings first');
      return;
    }
    setState(() => _busy = true);
    final result = await HBandSdk.testWebhook();
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(
      context,
      result.success ? 'Webhook OK · ${result.message}' : 'Webhook failed · ${result.message}',
      error: !result.success,
    );
  }

  void _openEvent(HBandEvent event) {
    if (!event.isEmergency) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => EmergencyPage(event: event, controller: c),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final events = _alertsOnly ? c.events.where((e) => !e.isStatus).toList() : c.events;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Watch Guard'),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c))),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: c.refreshAll,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverList.list(
                    children: [
                      _WatchCard(controller: c),
                      const SizedBox(height: 12),
                      _GuardCard(controller: c),
                      const SizedBox(height: 12),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          leading: const CircleAvatar(
                            backgroundColor: Color(0x1A0E7C7B),
                            child: Icon(Icons.monitor_heart_rounded, color: AppColors.brand),
                          ),
                          title: const Text('Health data', style: TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: const Text('Sync history · measure now · API payloads'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => HealthPage(controller: c))),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          leading: const CircleAvatar(
                            backgroundColor: Color(0x1AD7263D),
                            child: Icon(Icons.contact_phone_rounded, color: AppColors.emergency),
                          ),
                          title: const Text('SOS calling', style: TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: const Text('SOS contacts · call Bluetooth'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => SosSetupPage(controller: c))),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _ActionButton(
                              icon: Icons.sos_rounded,
                              label: 'Test alert',
                              color: AppColors.emergency,
                              onTap: _simulate,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ActionButton(
                              icon: Icons.cloud_upload_outlined,
                              label: _busy ? 'Sending…' : 'Test webhook',
                              color: AppColors.brand,
                              onTap: _busy ? null : _testWebhook,
                            ),
                          ),
                        ],
                      ),
                      SectionTitle(
                        'Activity',
                        trailing: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [
                            ButtonSegment(value: false, label: Text('All')),
                            ButtonSegment(value: true, label: Text('Alerts')),
                          ],
                          selected: {_alertsOnly},
                          onSelectionChanged: (s) => setState(() => _alertsOnly = s.first),
                        ),
                      ),
                    ],
                  ),
                ),
                if (events.isEmpty)
                  const SliverToBoxAdapter(child: _EmptyFeed())
                else
                  SliverList.builder(
                    itemCount: events.length,
                    itemBuilder: (_, i) => EventTile(event: events[i], onTap: () => _openEvent(events[i])),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WatchCard extends StatelessWidget {
  const _WatchCard({required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final look = connectionLook(controller.connection);
    final battery = controller.battery;
    final message = controller.connection.message;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF0E7C7B), Color(0xFF13555E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.watch_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    session?.name.isNotEmpty == true ? session!.name : 'My watch',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: StatusPill(label: look.label, color: look.color, pulsing: look.busy),
                ),
              ],
            ),
            if (!controller.connection.isReady && message != null) ...[
              const SizedBox(height: 8),
              Text(message, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13)),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                _Metric(
                  icon: battery?.charging == true
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_std_rounded,
                  label: 'Battery',
                  value: battery == null ? '—' : '${battery.displayPercent}%',
                ),
                _Metric(icon: Icons.tag_rounded, label: 'SN', value: session?.serial ?? '—'),
                _Metric(icon: Icons.memory_rounded, label: 'Firmware', value: session?.firmware ?? '—'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
    );
  }
}

class _GuardCard extends StatelessWidget {
  const _GuardCard({required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = controller.session?.guardEnabled ?? false;
    final protecting = on && controller.connection.isReady;
    final color = protecting ? AppColors.ok : (on ? AppColors.warning : scheme.outline);
    final subtitle = !on
        ? 'SOS & fall alerts are off'
        : protecting
        ? 'Listening for SOS & fall alerts'
        : 'Waiting for the watch — reconnecting automatically';
    final webhook = controller.webhook;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(on ? Icons.shield_rounded : Icons.shield_outlined, color: color, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        protecting ? 'Protected' : (on ? 'Guard on' : 'Guard off'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                  ),
                ),
                Switch(value: on, onChanged: controller.setGuard),
              ],
            ),
            const Divider(height: 28),
            Row(
              children: [
                Icon(Icons.cloud_outlined, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    webhook.url.isEmpty
                        ? 'Webhook not configured'
                        : 'Webhook ${webhook.enabled ? 'on' : 'off'} · ${Uri.tryParse(webhook.url)?.host ?? webhook.url}',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  controller.isAndroid ? Icons.android_rounded : Icons.phone_iphone_rounded,
                  size: 18,
                  color: scheme.outline,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.color, this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 32),
      child: Column(
        children: [
          Icon(Icons.notifications_none_rounded, size: 48, color: scheme.outline),
          const SizedBox(height: 10),
          Text('No activity yet', style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
