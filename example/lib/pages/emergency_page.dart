import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';

/// Full-screen alert shown when the watch reports SOS / fall.
class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key, required this.event, required this.controller});

  final HBandEvent event;
  final GuardController controller;

  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void initState() {
    super.initState();
    if (!widget.event.acknowledged) HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await widget.controller.acknowledge(widget.event);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final title = switch (e.type) {
      HBandEventType.sosPressed => 'SOS pressed',
      HBandEventType.fallDetected => 'Fall detected',
      _ => 'Emergency alert',
    };
    final ts = e.timestamp;
    final time =
        '${TimeOfDay.fromDateTime(ts).format(context)} · '
        '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')}/${ts.year}';
    final watch = (e.data['watch'] as Map?) ?? const {};
    final triggers = (e.data['possibleTriggers'] as List?)?.join(' or ');

    return Scaffold(
      backgroundColor: AppColors.emergency,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, child) => CustomPaint(painter: _PulsePainter(_pulse.value), child: child),
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.sos_rounded, size: 72, color: AppColors.emergency),
                ),
              ),
              const SizedBox(height: 36),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(time, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 16)),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.detail, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      if (triggers != null) Text('Possible cause: $triggers'),
                      Text('Watch: ${watch['name'] ?? '—'} · SN ${watch['sn'] ?? '—'}'),
                      if (e.webhookStatus != null) Text('Webhook: ${e.webhookStatus}'),
                      if (e.isSimulated) const Text('This is a test alert.'),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.emergencyDark,
                    minimumSize: const Size.fromHeight(60),
                    textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  onPressed: _dismiss,
                  child: Text(e.acknowledged ? 'Close' : 'OK — I have seen this'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.width / 2;
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1.0;
      final paint = Paint()..color = Colors.white.withValues(alpha: (1 - p) * 0.35);
      canvas.drawCircle(center, base + p * 70, paint);
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t;
}
