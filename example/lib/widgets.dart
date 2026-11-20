import 'package:flutter/material.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import 'theme.dart';

/// Small rounded pill showing a coloured dot + label.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.pulsing = false});

  final String label;
  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pulsing
              ? SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

({String label, Color color, bool busy}) connectionLook(HBandConnectionState state) {
  return switch (state.status) {
    HBandConnectionStatus.ready => (label: 'Connected', color: AppColors.ok, busy: false),
    HBandConnectionStatus.connecting => (label: 'Connecting…', color: AppColors.warning, busy: true),
    HBandConnectionStatus.verifying => (label: 'Verifying…', color: AppColors.warning, busy: true),
    HBandConnectionStatus.passwordFailed => (
      label: 'Wrong password',
      color: AppColors.emergency,
      busy: false,
    ),
    HBandConnectionStatus.failed => (label: 'Connection failed', color: AppColors.emergency, busy: false),
    HBandConnectionStatus.disconnected => (label: 'Disconnected', color: Colors.grey, busy: false),
  };
}

/// Signal strength as 4 bars.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.rssi});

  final int rssi;

  int get _bars => rssi >= -60
      ? 4
      : rssi >= -70
      ? 3
      : rssi >= -80
      ? 2
      : 1;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final idle = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        return Container(
          margin: const EdgeInsets.only(left: 2),
          width: 4,
          height: 6.0 + i * 4,
          decoration: BoxDecoration(color: i < _bars ? active : idle, borderRadius: BorderRadius.circular(2)),
        );
      }),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One feed row. Emergencies are tinted red, status lines are compact.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.onTap});

  final HBandEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(event.timestamp).format(context);
    if (event.isStatus) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.circle, size: 6, color: scheme.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(event.detail, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Text(time, style: TextStyle(color: scheme.outline, fontSize: 12)),
          ],
        ),
      );
    }
    final color = event.isEmergency ? AppColors.emergency : AppColors.warning;
    final title = switch (event.type) {
      HBandEventType.emergencyAlarm => 'Emergency (SOS / fall)',
      HBandEventType.sosPressed => 'SOS pressed',
      HBandEventType.fallDetected => 'Fall detected',
      HBandEventType.sedentary => 'Sedentary reminder',
      _ => event.type,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: color,
                  child: Icon(
                    event.isEmergency ? Icons.sos_rounded : Icons.event_seat_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ),
                          if (event.isSimulated) ...[const SizedBox(width: 6), const _Tag('TEST')],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$time · ${event.detection ?? ''}',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                      if (event.webhookStatus != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Webhook: ${event.webhookStatus}',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                if (event.isEmergency && !event.acknowledged)
                  const Icon(Icons.priority_high_rounded, color: AppColors.emergency),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? AppColors.emergencyDark : null,
      ),
    );
}
