import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

import '../guard_controller.dart';
import '../theme.dart';
import '../widgets.dart';

/// SOS calling setup: the watch dials its SOS contacts through the phone over
/// call Bluetooth, so both have to be in place for an SOS press to do anything.
class SosSetupPage extends StatefulWidget {
  const SosSetupPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<SosSetupPage> createState() => _SosSetupPageState();
}

class _SosSetupPageState extends State<SosSetupPage> {
  HBandCallBluetoothState? _bt;
  HBandContactSupport? _support;
  List<HBandContact>? _contacts;
  HBandSosCallTimes? _callTimes;
  String? _contactsError;
  bool _working = false;
  StreamSubscription<HBandCallBluetoothState>? _btSub;

  GuardController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _btSub = HBandSdk.callBluetoothState.listen((s) {
      if (mounted) setState(() => _bt = s);
    });
    _load();
  }

  @override
  void dispose() {
    _btSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final bt = await HBandSdk.getCallBluetoothState();
    final support = await HBandSdk.getContactSupport();
    if (!mounted) return;
    setState(() {
      _bt = bt;
      _support = support;
    });
    if (!c.connection.isReady) return;
    await _guard(() async {
      final bt = await HBandSdk.readCallBluetoothState();
      if (mounted) setState(() => _bt = bt);
    }, silent: true);
    if (!support.contacts) return;
    await _guard(() async {
      final contacts = await HBandSdk.getContacts();
      if (mounted) setState(() => _contacts = contacts);
    }, onError: (m) => _contactsError = m);
    if (support.sosContacts) {
      await _guard(() async {
        final times = await HBandSdk.getSosCallTimes();
        if (mounted) setState(() => _callTimes = times);
      }, silent: true);
    }
  }

  /// Runs one watch command at a time and shows SDK errors as a snackbar.
  Future<void> _guard(
    Future<void> Function() action, {
    bool silent = false,
    void Function(String message)? onError,
  }) async {
    setState(() => _working = true);
    try {
      await action();
      _contactsError = null;
    } on PlatformException catch (e) {
      final message = e.message ?? e.code;
      onError?.call(message);
      if (!silent && mounted) showSnack(context, message, error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pairBt() => _guard(HBandSdk.connectCallBluetooth);

  Future<void> _addContact() async {
    final draft = await showModalBottomSheet<({String name, String phone, bool sos})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ContactSheet(sosSupported: _support?.sosContacts ?? false),
    );
    if (draft == null) return;
    await _guard(() async {
      final list = await HBandSdk.addContact(name: draft.name, phone: draft.phone, sos: draft.sos);
      if (mounted) setState(() => _contacts = list);
    });
  }

  Future<void> _toggleSos(HBandContact contact, bool enabled) => _guard(() async {
    final list = await HBandSdk.setSosContact(contact, enabled);
    if (mounted) setState(() => _contacts = list);
  });

  Future<void> _delete(HBandContact contact) => _guard(() async {
    final list = await HBandSdk.deleteContact(contact);
    if (mounted) setState(() => _contacts = list);
  });

  Future<void> _setCallTimes(int times) => _guard(() async {
    await HBandSdk.setSosCallTimes(times);
    if (mounted) {
      setState(
        () => _callTimes = HBandSosCallTimes(times: times, min: _callTimes?.min, max: _callTimes?.max),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final ready = c.connection.isReady;
    final sosContacts = _contacts?.where((e) => e.sos).length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SOS calling'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _working || !ready ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: _working
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (!ready)
              const _Banner(
                icon: Icons.watch_off_outlined,
                color: AppColors.warning,
                text: 'Connect the watch first — contacts and call Bluetooth are read from it.',
              ),
            _Checklist(btOk: _bt?.canPlaceSosCalls ?? false, sosContacts: sosContacts),
            const SectionTitle('Call Bluetooth'),
            _BtCard(state: _bt, android: c.isAndroid, onPair: ready && !_working ? _pairBt : null),
            SectionTitle(
              'Contacts on the watch',
              trailing: _support?.contacts ?? false
                  ? TextButton.icon(
                      onPressed: ready && !_working ? _addContact : null,
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            _ContactsCard(
              support: _support,
              contacts: _contacts,
              error: _contactsError,
              enabled: ready && !_working,
              onToggleSos: _toggleSos,
              onDelete: _delete,
            ),
            if (_support?.sosContacts ?? false) ...[
              const SectionTitle('SOS call rounds'),
              _CallTimesCard(times: _callTimes, enabled: ready && !_working, onChanged: _setCallTimes),
            ],
          ],
        ),
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.btOk, required this.sosContacts});

  final bool btOk;
  final int sosContacts;

  @override
  Widget build(BuildContext context) {
    Widget row(bool ok, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: ok ? AppColors.ok : Theme.of(context).colorScheme.outline,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('When SOS is pressed', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 6),
            Text(
              'The watch calls its SOS contacts through this phone. The app also gets an '
              'SOS alert while the watch is connected.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            row(btOk, 'Call Bluetooth connected to this phone'),
            row(sosContacts > 0, sosContacts > 0 ? '$sosContacts SOS contact(s) on the watch' : 'At least one SOS contact'),
          ],
        ),
      ),
    );
  }
}

class _BtCard extends StatelessWidget {
  const _BtCard({required this.state, required this.android, required this.onPair});

  final HBandCallBluetoothState? state;
  final bool android;
  final VoidCallback? onPair;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final (label, color) = switch (s?.status) {
      HBandCallBtStatus.connected => ('Connected', AppColors.ok),
      HBandCallBtStatus.broadcasting => ('Waiting to pair', AppColors.warning),
      HBandCallBtStatus.disconnected => ('Not connected', AppColors.emergency),
      _ => ('Unknown', Colors.grey),
    };
    final link = s?.link;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.phone_in_talk_rounded),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Watch ↔ phone calls', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                StatusPill(label: label, color: color),
              ],
            ),
            if (s != null && !s.supported && s.status == HBandCallBtStatus.unknown) ...[
              const SizedBox(height: 10),
              const Text('This watch does not report call Bluetooth.'),
            ],
            if (link != null && link != 'connected') ...[
              const SizedBox(height: 8),
              Text('Last request: $link', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (!(s?.isConnected ?? false)) ...[
              const SizedBox(height: 12),
              Text(
                android
                    ? 'Tap Pair, then accept the Android pairing dialog. The watch may also ask to confirm.'
                    : 'Tap Turn on, then open Settings → Bluetooth on the iPhone and pair the watch '
                          '(it shows up with the same name).',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onPair,
                icon: const Icon(Icons.bluetooth_searching_rounded),
                label: Text(android ? 'Pair call Bluetooth' : 'Turn on call Bluetooth'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ContactsCard extends StatelessWidget {
  const _ContactsCard({
    required this.support,
    required this.contacts,
    required this.error,
    required this.enabled,
    required this.onToggleSos,
    required this.onDelete,
  });

  final HBandContactSupport? support;
  final List<HBandContact>? contacts;
  final String? error;
  final bool enabled;
  final void Function(HBandContact, bool) onToggleSos;
  final void Function(HBandContact) onDelete;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget message(String text) => Padding(padding: const EdgeInsets.all(18), child: Text(text, style: muted));

    final Widget child;
    if (support == null) {
      child = message('Loading…');
    } else if (!support!.contacts) {
      child = message('This watch has no contacts feature.');
    } else if (contacts == null) {
      child = message(error ?? 'Connect the watch to read its contacts.');
    } else if (contacts!.isEmpty) {
      child = message('No contacts yet. Add one and turn on SOS for it.');
    } else {
      child = Column(
        children: [
          for (final contact in contacts!)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: contact.sos ? const Color(0x1AD7263D) : null,
                child: Icon(
                  contact.sos ? Icons.sos_rounded : Icons.person_rounded,
                  color: contact.sos ? AppColors.emergency : null,
                ),
              ),
              title: Text(contact.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(contact.phone),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (support!.sosContacts)
                    Switch(value: contact.sos, onChanged: enabled ? (v) => onToggleSos(contact, v) : null),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: enabled ? () => onDelete(contact) : null,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          if (support!.sosContacts)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Text('Switch on = called when SOS is pressed', style: muted.copyWith(fontSize: 12)),
            ),
        ],
      );
    }
    return Card(clipBehavior: Clip.antiAlias, child: child);
  }
}

class _CallTimesCard extends StatelessWidget {
  const _CallTimesCard({required this.times, required this.enabled, required this.onChanged});

  final HBandSosCallTimes? times;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = times;
    final min = t?.min ?? 1;
    final max = t?.max ?? 5;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                t == null ? 'Not read yet' : 'Calls the SOS list ${t.times}×',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton.filledTonal(
              onPressed: enabled && t != null && t.times > min ? () => onChanged(t.times - 1) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: enabled && t != null && t.times < max ? () => onChanged(t.times + 1) : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactSheet extends StatefulWidget {
  const _ContactSheet({required this.sosSupported});

  final bool sosSupported;

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  late bool _sos = widget.sosSupported;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && RegExp(r'^\+?[0-9]{3,20}$').hasMatch(_phone.text.trim());

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add contact', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 20,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Name', counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))],
            decoration: const InputDecoration(labelText: 'Phone number', hintText: '0812345678'),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.sosSupported)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _sos,
              onChanged: (v) => setState(() => _sos = v),
              title: const Text('SOS contact'),
              subtitle: const Text('Called when SOS is pressed on the watch'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _valid
                ? () => Navigator.pop(context, (name: _name.text.trim(), phone: _phone.text.trim(), sos: _sos))
                : null,
            child: const Text('Save to watch'),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
