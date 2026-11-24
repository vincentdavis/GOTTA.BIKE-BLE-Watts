/// Dual record: connect to two real sensors (slots A and B) as a BLE central,
/// show their live readings side by side and record both streams to a CSV.
///
/// Record-only: nothing is rebroadcast. Opened from the main screen's app
/// bar, and only while not advertising (see `main.dart`), so the phone is
/// never a peripheral and a central at the same time.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'dual_recorder.dart';
import 'recording_files.dart';
import 'sensor_central.dart';
import 'sensor_decoders.dart';

/// Short labels for the measurement kinds, as shown in the UI.
const Map<MeasurementKind, String> kKindLabels = {
  MeasurementKind.cyclingPower: 'Power',
  MeasurementKind.heartRate: 'HR',
  MeasurementKind.speedCadence: 'Speed/Cad',
  MeasurementKind.indoorBike: 'FTMS',
};

class DualRecordPage extends StatefulWidget {
  const DualRecordPage({
    super.key,
    this.wheelCircumferenceM = 2.105,
    this.files = const RecordingFiles(),
    this.screenWakelock,
    this.clock,
  });

  /// Turns wheel revolutions (CSC, CPS wheel data) into speed.
  final double wheelCircumferenceM;
  final RecordingFiles files;

  /// Keeps the screen on while a device is connected or a recording runs
  /// (Android freezes a screen-off app). Defaults to `wakelock_plus`.
  final Future<void> Function(bool on)? screenWakelock;
  final DateTime Function()? clock;

  @override
  State<DualRecordPage> createState() => _DualRecordPageState();
}

/// One connected device and what it last reported.
class _Slot {
  _Slot(this.link, double wheelCircumferenceM)
    : interpreter = MeasurementInterpreter(
        wheelCircumferenceM: wheelCircumferenceM,
      );

  final SensorLink link;
  final MeasurementInterpreter interpreter;
  final Map<MeasurementKind, SensorSample> latest = {};
  StreamSubscription<SensorPacket>? packetSub;
  int malformed = 0;

  T? _first<T>(List<MeasurementKind> order, T? Function(SensorSample) f) {
    for (final k in order) {
      final s = latest[k];
      final v = s == null ? null : f(s);
      if (v != null) return v;
    }
    return null;
  }

  // Same source preference as DualRecorder.stats.
  int? get power => _first(const [
    MeasurementKind.cyclingPower,
    MeasurementKind.indoorBike,
  ], (s) => s.powerWatts);
  double? get cadence => _first(const [
    MeasurementKind.cyclingPower,
    MeasurementKind.indoorBike,
    MeasurementKind.speedCadence,
  ], (s) => s.cadenceRpm);
  double? get speed => _first(const [
    MeasurementKind.speedCadence,
    MeasurementKind.indoorBike,
    MeasurementKind.cyclingPower,
  ], (s) => s.speedKmh);
  int? get heartRate => _first(const [
    MeasurementKind.heartRate,
    MeasurementKind.indoorBike,
  ], (s) => s.heartRateBpm);
}

class _DualRecordPageState extends State<DualRecordPage> {
  final SensorScanner _scanner = SensorScanner();
  final DualRecorder _recorder = DualRecorder();
  final Map<RecordSlot, _Slot> _slots = {};
  Timer? _ticker;
  String? _savedPath;
  bool _saving = false;
  bool _wakelockOn = false;
  bool _disposed = false;
  String _status = 'Choose device A and device B.';

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    for (final slot in _slots.values) {
      unawaited(slot.packetSub?.cancel());
      unawaited(slot.link.close());
    }
    _slots.clear();
    if (_wakelockOn) unawaited(_setWakelock(false));
    super.dispose();
  }

  Future<void> _setWakelock(bool on) async {
    _wakelockOn = on;
    try {
      await (widget.screenWakelock ?? (v) => WakelockPlus.toggle(enable: v))(
        on,
      );
    } catch (_) {}
  }

  void _syncWakelock() {
    final want = _slots.isNotEmpty || _recorder.recording;
    if (want != _wakelockOn) unawaited(_setWakelock(want));
  }

  /// Checks permission and Bluetooth state; returns an error message or null.
  Future<String?> _bluetoothProblem() async {
    try {
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    } catch (e) {
      return 'Bluetooth permission is needed to find sensors '
          '(Settings › Apps › Permissions › Nearby devices).';
    }
    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      if (state == AvailabilityState.poweredOff) {
        return 'Bluetooth is off. Turn it on to find sensors.';
      }
      if (state == AvailabilityState.unsupported) {
        return 'This device has no Bluetooth LE.';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _choose(RecordSlot slot) async {
    final problem = await _bluetoothProblem();
    if (!mounted) return;
    if (problem != null) {
      setState(() => _status = problem);
      return;
    }
    final other = _slots[slot == RecordSlot.a ? RecordSlot.b : RecordSlot.a];
    final device = await showModalBottomSheet<BleDevice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScanSheet(
        scanner: _scanner,
        slot: slot,
        excludeId: other?.link.deviceId,
      ),
    );
    if (device == null || !mounted) return;
    _connect(slot, device);
  }

  void _connect(RecordSlot slot, BleDevice device) {
    final name = (device.name?.isNotEmpty ?? false)
        ? device.name!
        : device.deviceId;
    final link = SensorLink(
      deviceId: device.deviceId,
      name: name,
      clock: widget.clock,
    );
    final s = _Slot(link, widget.wheelCircumferenceM);
    s.packetSub = link.packets.listen((p) => _onPacket(slot, s, p));
    link.state.addListener(() {
      if (_disposed || !mounted) return;
      if (link.state.value != SensorLinkState.connected) s.latest.clear();
      setState(() {});
    });
    setState(() {
      _slots[slot] = s;
      _status = 'Connecting to $name…';
    });
    _syncWakelock();
    unawaited(link.open());
  }

  void _onPacket(RecordSlot slot, _Slot s, SensorPacket p) {
    if (_disposed || !mounted || !identical(_slots[slot], s)) return;
    final sample = s.interpreter.decode(p.kind, p.bytes, p.time);
    if (sample == null) {
      s.malformed++;
      return;
    }
    s.latest[p.kind] = sample;
    _recorder.add(
      RecordedSample(
        time: p.time,
        slot: slot,
        deviceId: s.link.deviceId,
        deviceName: s.link.name,
        sample: sample,
        raw: p.bytes,
      ),
    );
    setState(() {});
  }

  Future<void> _disconnect(RecordSlot slot) async {
    final s = _slots.remove(slot);
    setState(() {});
    _syncWakelock();
    if (s == null) return;
    unawaited(s.packetSub?.cancel());
    await s.link.close();
  }

  void _startRecording() {
    setState(() {
      _recorder.start(_now());
      _savedPath = null;
      _status = 'Recording…';
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _syncWakelock();
  }

  Future<void> _stopRecording() async {
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _recorder.stop(_now());
      _saving = true;
      _status = 'Saving…';
    });
    _syncWakelock();
    final total = _recorder.count(RecordSlot.a) + _recorder.count(RecordSlot.b);
    try {
      final path = await widget.files.save(
        _recorder.fileName(),
        _recorder.toCsv(),
      );
      if (!mounted) return;
      setState(() {
        _savedPath = path;
        _status = 'Saved $total samples as ${_recorder.fileName()}.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Saving failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    final path = _savedPath;
    if (path == null) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      await widget.files.share(path, origin: origin);
    } catch (e) {
      if (mounted) setState(() => _status = 'Sharing failed: $e');
    }
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text(
          'Leaving Dual record stops the recording and saves it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop and leave'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    await _stopRecording();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _recorder.recording;
    final hasData = recording || !_recorder.isEmpty;
    return PopScope(
      canPop: !recording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Dual record')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final slot in RecordSlot.values) ...[
                      if (slot != RecordSlot.a) const SizedBox(width: 8),
                      Expanded(
                        child: _SlotCard(
                          key: ValueKey('slot-${slot.label}'),
                          slot: slot,
                          state: _slots[slot],
                          recording: recording,
                          samples: _recorder.count(slot),
                          onChoose: () => _choose(slot),
                          onDisconnect: () => _disconnect(slot),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (hasData) ...[
                _ComparisonCard(
                  comparison: _recorder.comparison(),
                  elapsed: _recorder.elapsed(_now()),
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                key: const ValueKey('record-button'),
                onPressed: _saving
                    ? null
                    : recording
                    ? _stopRecording
                    : (_slots.isEmpty ? null : _startRecording),
                icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
                label: Text(recording ? 'Stop recording' : 'Start recording'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: recording ? Colors.red.shade700 : null,
                ),
              ),
              if (_savedPath != null && !recording) ...[
                const SizedBox(height: 8),
                Builder(
                  builder: (buttonContext) => OutlinedButton.icon(
                    onPressed: () => _share(buttonContext),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share CSV'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(_status, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                'Recordings are saved on this phone. Each CSV row is one '
                'notification from A or B with a UTC timestamp; nothing is '
                'rebroadcast. Keep this screen open while recording.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    super.key,
    required this.slot,
    required this.state,
    required this.recording,
    required this.samples,
    required this.onChoose,
    required this.onDisconnect,
  });

  final RecordSlot slot;
  final _Slot? state;
  final bool recording;
  final int samples;
  final VoidCallback onChoose;
  final VoidCallback onDisconnect;

  String _linkText(SensorLink link) {
    switch (link.state.value) {
      case SensorLinkState.connected:
        final kinds = link.subscribed.map((k) => kKindLabels[k]).join(', ');
        return 'Connected · $kinds';
      case SensorLinkState.connecting:
        return 'Connecting…';
      case SensorLinkState.reconnecting:
        final err = link.lastError;
        return err == null ? 'Reconnecting…' : 'Reconnecting… ($err)';
      case SensorLinkState.disconnected:
        return 'Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = state;
    final connected = s?.link.state.value == SensorLinkState.connected;
    String fmt(num? v, [int digits = 0]) =>
        v == null ? '—' : v.toStringAsFixed(digits);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  child: Text(slot.label, style: theme.textTheme.labelMedium),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s?.link.name ?? 'No device',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s == null ? 'Not connected' : _linkText(s.link),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: connected ? Colors.greenAccent : theme.hintColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              fmt(s?.power),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text('watts', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text('${fmt(s?.cadence)} rpm'),
            if (s?.speed != null) Text('${fmt(s?.speed, 1)} km/h'),
            if (s?.heartRate != null) Text('${s?.heartRate} bpm'),
            if (recording || samples > 0)
              Text('$samples samples', style: theme.textTheme.bodySmall),
            const Spacer(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: s == null
                  ? FilledButton.tonal(
                      onPressed: onChoose,
                      child: Text('Choose ${slot.label}'),
                    )
                  : OutlinedButton(
                      onPressed: recording ? null : onDisconnect,
                      child: const Text('Disconnect'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.comparison, required this.elapsed});

  final PowerComparison comparison;
  final Duration elapsed;

  static String formatElapsed(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = comparison.a;
    final b = comparison.b;
    final diff = comparison.differencePercent;
    String watts(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} W';
    TableRow row(String label, String va, String vb) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Text(va, textAlign: TextAlign.end),
        Text(vb, textAlign: TextAlign.end),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Elapsed ${formatElapsed(elapsed)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.4),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
              },
              children: [
                row('', 'A', 'B'),
                row('Samples', '${a.samples}', '${b.samples}'),
                row(
                  'Avg power',
                  watts(a.averagePowerWatts),
                  watts(b.averagePowerWatts),
                ),
                row(
                  'Avg cadence',
                  a.averageCadenceRpm?.toStringAsFixed(1) ?? '—',
                  b.averageCadenceRpm?.toStringAsFixed(1) ?? '—',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              diff == null
                  ? 'B vs A: —'
                  : 'B vs A: ${diff >= 0 ? '+' : ''}'
                        '${diff.toStringAsFixed(1)} %',
              key: const ValueKey('difference'),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Live list of nearby sensors; pops with the chosen [BleDevice].
class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.scanner, required this.slot, this.excludeId});

  final SensorScanner scanner;
  final RecordSlot slot;
  final String? excludeId;

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  final Map<String, BleDevice> _devices = {};
  StreamSubscription<BleDevice>? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.scanner.results.listen((d) {
      if (!mounted || d.deviceId == widget.excludeId) return;
      setState(() => _devices[d.deviceId] = d);
    });
    widget.scanner.start().catchError((Object e) {
      if (mounted) setState(() => _error = 'Scan failed: $e');
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(widget.scanner.stop().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _devices.values.toList()
      ..sort((x, y) => (y.rssi ?? -999).compareTo(x.rssi ?? -999));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Choose device ${widget.slot.label}',
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            else
              const LinearProgressIndicator(),
            if (devices.isEmpty && _error == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Looking for power meters, trainers, heart-rate and '
                  'speed/cadence sensors… Wake the sensor up (turn the '
                  'cranks) if it does not appear.',
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final d in devices)
                    ListTile(
                      title: Text(
                        (d.name?.isNotEmpty ?? false)
                            ? d.name!
                            : 'Unnamed device',
                      ),
                      subtitle: Text(
                        [
                          CentralUuids.kindsAdvertised(
                            d.services,
                          ).map((k) => kKindLabels[k]).join(', '),
                          if (d.rssi != null) '${d.rssi} dBm',
                          d.deviceId,
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, d),
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
