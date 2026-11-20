import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';
import '../widgets.dart';

/// Sync watch history + on-demand measurements, showing the exact JSON body
/// the host app would POST to `api/smartwatch_vp_insert/{type}`.
class HealthPage extends StatefulWidget {
  const HealthPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  String? _imei;
  HBandCapabilities? _caps;
  int _days = 1;
  bool _syncing = false;
  HBandSyncProgress? _progress;
  HBandHealthSyncResult? _result;
  StreamSubscription<HBandSyncProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _progressSub = HBandSdk.syncProgress.listen((p) => setState(() => _progress = p));
    _load();
  }

  Future<void> _load() async {
    final imei = await HBandSdk.getImei();
    final caps = await HBandSdk.getCapabilities();
    if (!mounted) return;
    setState(() {
      _imei = imei;
      _caps = caps;
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _progress = null;
    });
    try {
      final result = await HBandSdk.syncHealthData(days: _days);
      if (!mounted) return;
      setState(() => _result = result);
      showSnack(
        context,
        result.cancelled
            ? 'Sync cancelled'
            : 'Synced ${result.totalCount} records in ${result.duration.inSeconds}s'
                  '${result.errors.isEmpty ? '' : ' · ${result.errors.length} step(s) failed'}',
        error: result.errors.isNotEmpty,
      );
    } on PlatformException catch (e) {
      if (mounted) showSnack(context, e.message ?? e.code, error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _showPayload(String type, List<Map<String, dynamic>> records) {
    final imei = _imei ?? 'UNKNOWN';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PayloadSheet(requests: buildInsertRequests(imei, type, records)),
    );
  }

  Future<void> _measure(String type) async {
    final result = await showModalBottomSheet<HBandMeasureResult>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MeasureSheet(type: type),
    );
    if (!mounted || result == null) return;
    if (!result.success) {
      showSnack(context, result.message ?? 'Measurement failed', error: true);
      return;
    }
    final requests = result.toInsertRequests(_imei ?? 'UNKNOWN');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => requests.length == 1 && result.records.isEmpty
          ? _PayloadSheet(requests: requests, title: 'Measured ${_label(type)}')
          : _ResultSheet(title: 'Measured ${_label(type)}', record: result.record ?? const {}, requests: requests),
    );
  }

  /// Older plugin builds report no list — then every tile stays enabled.
  bool _canMeasure(String type) {
    final list = _caps?.measurements ?? const [];
    return list.isEmpty || list.contains(type);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = widget.controller.connection.isReady;
    final maxDays = math.max(1, math.min(7, _caps?.watchDays ?? 3));
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Health data')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('IMEI for the API'),
              subtitle: SelectableText(
                _imei ?? '—',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
              ),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: _imei == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: _imei!));
                        showSnack(context, 'IMEI copied');
                      },
              ),
            ),
          ),
          if (!ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Connect the watch to sync or measure.',
                style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
              ),
            ),
          const SectionTitle('Sync history'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reads what the watch stored (heart rate, SpO2, blood pressure, sleep, steps, …). '
                    'Sending the same records again is safe — the backend skips duplicate times.',
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Text('Days', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: [
                            for (var d = 1; d <= maxDays; d++) ButtonSegment(value: d, label: Text('$d')),
                          ],
                          selected: {_days.clamp(1, maxDays)},
                          onSelectionChanged: _syncing ? null : (s) => setState(() => _days = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_syncing) ...[
                    LinearProgressIndicator(
                      value: _progress?.progress,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Reading ${_stageLabel(_progress?.stage)}… ${((_progress?.progress ?? 0) * 100).round()}%',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(onPressed: HBandSdk.cancelHealthSync, child: const Text('Cancel')),
                  ] else
                    FilledButton.icon(
                      onPressed: ready ? _sync : null,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('Sync from watch'),
                    ),
                ],
              ),
            ),
          ),
          if (result != null) ...[
            SectionTitle(
              'Last sync · ${result.totalCount} records',
              trailing: Text(
                '${result.duration.inSeconds}s',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            Card(
              child: Column(
                children: [
                  for (final type in HBandHealthType.all)
                    if ((result.records[type] ?? const []).isNotEmpty)
                      ListTile(
                        leading: Icon(_icon(type), color: AppColors.brand),
                        title: Text(_label(type)),
                        subtitle: Text(
                          'api/smartwatch_vp_insert/$type',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${result.records[type]!.length}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                        onTap: () => _showPayload(type, result.records[type]!),
                      ),
                  if (result.totalCount == 0)
                    const ListTile(title: Text('No records — the watch has no stored data yet')),
                ],
              ),
            ),
            if (result.errors.isNotEmpty || result.skipped.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  [
                    if (result.errors.isNotEmpty)
                      'Failed: ${result.errors.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
                    if (result.skipped.isNotEmpty)
                      'Not supported by this watch: ${result.skipped.join(', ')}',
                  ].join('\n'),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.4),
                ),
              ),
          ],
          const SectionTitle('Measure now'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              for (final type in HBandMeasureType.all)
                _MeasureTile(
                  type: type,
                  enabled: ready && !_syncing && _canMeasure(type),
                  supported: _canMeasure(type),
                  onTap: () => _measure(type),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _label(String type) => switch (type) {
  HBandHealthType.heartRate => 'Heart rate',
  HBandHealthType.spo2 => 'SpO2',
  HBandHealthType.bloodPressure => 'Blood pressure',
  HBandHealthType.bodyTemp => 'Body temperature',
  HBandHealthType.respiratory => 'Respiratory rate',
  HBandHealthType.hrv => 'HRV',
  HBandHealthType.fatigue => 'Fatigue',
  HBandHealthType.stepCount => 'Steps',
  HBandHealthType.calorie => 'Calories',
  HBandHealthType.battery => 'Battery',
  HBandHealthType.sleep => 'Sleep',
  HBandHealthType.sport => 'Workouts',
  HBandHealthType.ecg => 'ECG',
  HBandHealthType.bloodGlucose => 'Blood glucose',
  HBandHealthType.rrInterval => 'RR interval',
  HBandHealthType.heartWarning => 'Heart-rate alarm',
  HBandMeasureType.ptt => 'PTT',
  HBandHealthType.stress => 'Stress',
  HBandMeasureType.bloodComponent => 'Blood component',
  HBandMeasureType.bodyComposition => 'Body composition',
  HBandMeasureType.gsr => 'Skin conductance (GSR)',
  HBandMeasureType.met => 'MET',
  HBandMeasureType.emotion => 'Emotion',
  HBandMeasureType.checkup => 'Quick checkup',
  _ => type,
};

IconData _icon(String type) => switch (type) {
  HBandHealthType.heartRate => Icons.favorite_rounded,
  HBandHealthType.spo2 => Icons.water_drop_rounded,
  HBandHealthType.bloodPressure => Icons.speed_rounded,
  HBandHealthType.bodyTemp => Icons.thermostat_rounded,
  HBandHealthType.respiratory => Icons.air_rounded,
  HBandHealthType.hrv => Icons.timeline_rounded,
  HBandHealthType.fatigue => Icons.battery_alert_rounded,
  HBandHealthType.stepCount => Icons.directions_walk_rounded,
  HBandHealthType.calorie => Icons.local_fire_department_rounded,
  HBandHealthType.battery => Icons.battery_full_rounded,
  HBandHealthType.sleep => Icons.bedtime_rounded,
  HBandHealthType.sport => Icons.fitness_center_rounded,
  HBandHealthType.ecg || HBandMeasureType.ptt => Icons.monitor_heart_rounded,
  HBandHealthType.bloodGlucose => Icons.bloodtype_rounded,
  HBandHealthType.rrInterval => Icons.straighten_rounded,
  HBandHealthType.heartWarning => Icons.warning_amber_rounded,
  HBandHealthType.stress => Icons.psychology_alt_rounded,
  HBandMeasureType.bloodComponent => Icons.science_rounded,
  HBandMeasureType.bodyComposition => Icons.accessibility_new_rounded,
  HBandMeasureType.gsr => Icons.touch_app_rounded,
  HBandMeasureType.met => Icons.directions_run_rounded,
  HBandMeasureType.emotion => Icons.mood_rounded,
  HBandMeasureType.checkup => Icons.health_and_safety_rounded,
  _ => Icons.analytics_rounded,
};

String _stageLabel(String? stage) => switch (stage) {
  'battery' => 'battery',
  'steps' => 'steps',
  'daily' => 'daily data',
  'sleep' => 'sleep',
  'temperature' => 'temperature',
  'spo2' => 'SpO2',
  'hrv' => 'HRV',
  'database' => 'stored data',
  'rrinterval' => 'RR intervals',
  'sport' => 'workouts',
  'ecg' => 'ECG',
  'heartwarning' => 'heart-rate alarm',
  _ => 'watch',
};

class _MeasureTile extends StatelessWidget {
  const _MeasureTile({required this.type, required this.enabled, required this.supported, required this.onTap});

  final String type;
  final bool enabled;
  final bool supported;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = type == HBandMeasureType.ecg || type == HBandMeasureType.ptt
        ? AppColors.emergency
        : AppColors.brand;
    return Material(
      color: enabled ? color.withValues(alpha: 0.10) : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(_icon(type), color: enabled ? color : scheme.outline),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _label(type),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: enabled ? null : scheme.outline),
                  ),
                  if (!supported)
                    Text('Not supported', style: TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs one measurement with live value, progress ring and ECG waveform.
class _MeasureSheet extends StatefulWidget {
  const _MeasureSheet({required this.type});

  final String type;

  @override
  State<_MeasureSheet> createState() => _MeasureSheetState();
}

class _MeasureSheetState extends State<_MeasureSheet> {
  StreamSubscription<HBandMeasureUpdate>? _sub;
  int? _progress;
  Object? _value;
  bool _leadOff = false;
  final List<int> _wave = [];

  bool get _isEcg => widget.type == HBandMeasureType.ecg || widget.type == HBandMeasureType.ptt;

  @override
  void initState() {
    super.initState();
    _sub = HBandSdk.measurementUpdates.listen((u) {
      setState(() {
        if (u.progress != null) _progress = u.progress;
        if (u.value != null) _value = u.value;
        if (u.leadOff != null) _leadOff = u.leadOff!;
        if (u.samples != null) {
          _wave.addAll(u.samples!);
          if (_wave.length > 600) _wave.removeRange(0, _wave.length - 600);
        }
      });
    });
    HBandSdk.startMeasurement(widget.type)
        .then((result) {
          if (mounted) Navigator.pop(context, result);
        })
        .catchError((Object e) {
          if (mounted) {
            Navigator.pop(
              context,
              HBandMeasureResult(
                success: false,
                type: widget.type,
                message: e is PlatformException ? e.message : '$e',
              ),
            );
          }
        });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String get _unit => switch (widget.type) {
    HBandMeasureType.heartRate => 'bpm',
    HBandMeasureType.spo2 => '%',
    HBandMeasureType.bloodPressure => 'mmHg',
    HBandMeasureType.bodyTemp => '°C',
    HBandMeasureType.bloodGlucose => 'mmol/L',
    HBandMeasureType.fatigue || HBandMeasureType.stress || HBandMeasureType.emotion => 'level',
    HBandMeasureType.hrv => 'ms',
    HBandMeasureType.respiratory => 'breaths/min',
    HBandMeasureType.met => 'MET',
    HBandMeasureType.ecg || HBandMeasureType.ptt => 'bpm',
    _ => '',
  };

  String get _hint => switch (widget.type) {
    HBandMeasureType.ecg => 'Touch the watch electrode with a finger of the other hand and keep still.',
    HBandMeasureType.ptt => 'Start PTT mode on the watch, then keep your finger on the electrode.',
    HBandMeasureType.bloodPressure => 'Keep your arm still at heart level (about 50 seconds).',
    HBandMeasureType.hrv => 'Stay still — HRV is read for about 30 seconds.',
    HBandMeasureType.bodyComposition || HBandMeasureType.gsr || HBandMeasureType.checkup =>
      'Keep a finger of the other hand on the watch electrode until it finishes.',
    _ => 'Keep the watch snug on your wrist and stay still.',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = _value;
    final display = value is double ? value.toStringAsFixed(value < 20 ? 2 : 1) : (value?.toString() ?? '—');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _label(widget.type),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            _hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 180,
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: _progress == null ? null : _progress! / 100,
                    strokeWidth: 10,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(display, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900)),
                    Text(_unit, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
          if (_leadOff) ...[
            const SizedBox(height: 12),
            const Text(
              'Finger is off the electrode',
              style: TextStyle(color: AppColors.emergency, fontWeight: FontWeight.w700),
            ),
          ],
          if (_isEcg) ...[
            const SizedBox(height: 20),
            Container(
              height: 90,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.emergency.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: CustomPaint(painter: _WavePainter(_wave, AppColors.emergency)),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(onPressed: HBandSdk.stopMeasurement, child: const Text('Stop')),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.samples, this.color);

  final List<int> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final minV = samples.reduce(math.min).toDouble();
    final maxV = samples.reduce(math.max).toDouble();
    final range = (maxV - minV).abs() < 1 ? 1.0 : maxV - minV;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i / (samples.length - 1) * size.width;
      final y = size.height - 8 - (samples[i] - minV) / range * (size.height - 16);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

/// Shows a measured record (any type) and which requests it maps to.
class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.title, required this.record, required this.requests});

  final String title;
  final Map<String, dynamic> record;
  final List<HBandInsertRequest> requests;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pretty = const JsonEncoder.withIndent('  ').convert(record);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            requests.isEmpty
                ? 'No backend API for this type yet — display only.'
                : 'POST to: ${requests.map((r) => r.path).join(', ')}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF111B1C), borderRadius: BorderRadius.circular(14)),
            child: SelectableText(
              pretty,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFD7F2EF), height: 1.4),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy JSON'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonEncode(record)));
              showSnack(context, 'Copied');
            },
          ),
        ],
      ),
    );
  }
}

/// Shows the JSON body (or bodies) to POST, with copy.
class _PayloadSheet extends StatelessWidget {
  const _PayloadSheet({required this.requests, this.title});

  final List<HBandInsertRequest> requests;
  final String? title;

  /// Long arrays (ECG wave, RR) are shortened for display only.
  static Object? _preview(Object? v) {
    if (v is Map) return v.map((k, val) => MapEntry(k, _preview(val)));
    if (v is List && v.length > 12) return [...v.take(12).map(_preview), '… ${v.length - 12} more'];
    if (v is List) return v.map(_preview).toList();
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final first = requests.first;
    final data = first.body['data'] as List;
    final preview = {
      'imei': first.body['imei'],
      'data': [...data.take(3).map(_preview), if (data.length > 3) '… ${data.length - 3} more'],
    };
    final pretty = const JsonEncoder.withIndent('  ').convert(preview);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(
            title ?? _label(first.type),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          SelectableText(
            'POST {HEALTH_API_URL}/${first.path}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w600),
          ),
          Text(
            '${requests.fold<int>(0, (s, r) => s + r.count)} records'
            '${requests.length > 1 ? ' in ${requests.length} requests' : ''}',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF111B1C),
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              pretty,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFFD7F2EF),
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy full JSON body'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonEncode(first.body)));
              showSnack(context, 'Copied ${first.count} records');
            },
          ),
        ],
      ),
    );
  }
}
