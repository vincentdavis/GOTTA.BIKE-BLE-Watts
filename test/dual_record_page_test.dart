import 'package:cps_emulator/cpm_codec.dart';
import 'package:cps_emulator/cps_peripheral.dart';
import 'package:cps_emulator/dual_record_page.dart';
import 'package:cps_emulator/dual_recorder.dart';
import 'package:cps_emulator/recording_files.dart';
import 'package:cps_emulator/sensor_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fake_central_platform.dart';

const idA = 'AA:00:00:00:00:01';
const idB = 'BB:00:00:00:00:02';

class FakeFiles extends RecordingFiles {
  final saved = <String, String>{};
  final shared = <String>[];

  @override
  Future<String> save(String fileName, String csv) async {
    saved[fileName] = csv;
    return '/recordings/$fileName';
  }

  @override
  Future<void> share(String path, {Rect? origin}) async => shared.add(path);
}

void main() {
  late FakeCentralPlatform ble;
  late FakeFiles files;
  late DateTime now;
  late List<bool> wakelock;

  setUp(() {
    ble = FakeCentralPlatform();
    UniversalBle.setInstance(ble);
    for (final id in [idA, idB]) {
      ble.services[id] = [
        notifyService(CentralUuids.cpsService, [
          CyclingPowerPeripheral.cpmChar,
        ]),
      ];
    }
    files = FakeFiles();
    now = DateTime.utc(2026, 11, 24, 8);
    wakelock = [];
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DualRecordPage(
                      files: files,
                      clock: () => now,
                      screenWakelock: (on) async => wakelock.add(on),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// BLE events are delivered in microtasks after the frame being pumped.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// The scan sheet's progress bar never settles: pump a fixed time.
  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> choose(WidgetTester tester, String slot, String id) async {
    await tester.tap(find.text('Choose $slot'));
    await pumpSheet(tester);
    expect(ble.scanning, isTrue);
    for (final d in [idA, idB]) {
      ble.updateScanResult(
        BleDevice(
          deviceId: d,
          name: d == idA ? 'Quarq' : 'Kickr',
          rssi: -50,
          services: const ['00001818-0000-1000-8000-00805f9b34fb'],
        ),
      );
    }
    await pumpSheet(tester);
    await tester.tap(find.text(id == idA ? 'Quarq' : 'Kickr'));
    await tester.pumpAndSettle();
    expect(ble.scanning, isFalse);
  }

  void power(String id, int watts, int revs, int time) => ble.notify(
    id,
    CyclingPowerPeripheral.cpmChar,
    CpmCodec.encode(
      powerWatts: watts,
      cumulativeCrankRevs: revs,
      lastCrankEventTime: time,
    ),
  );

  testWidgets('empty state fits 360 px; recording needs a device', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('Dual record'), findsOneWidget);
    expect(find.text('Choose A'), findsOneWidget);
    expect(find.text('Choose B'), findsOneWidget);
    final record = tester.widget<FilledButton>(
      find.byKey(const ValueKey('record-button')),
    );
    expect(record.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connect A and B, record, compare, save and share', (
    tester,
  ) async {
    await pumpPage(tester);
    await choose(tester, 'A', idA);
    expect(find.textContaining('Connected · Power'), findsOneWidget);
    expect(wakelock, [true]);

    // B's list doesn't offer the device already used as A.
    await tester.tap(find.text('Choose B'));
    await pumpSheet(tester);
    ble.updateScanResult(BleDevice(deviceId: idA, name: 'Quarq'));
    ble.updateScanResult(BleDevice(deviceId: idB, name: 'Kickr'));
    await pumpSheet(tester);
    expect(find.text('Quarq'), findsOneWidget); // only the slot card
    await tester.tap(find.text('Kickr'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected · Power'), findsNWidgets(2));

    // Live values before recording.
    power(idA, 200, 0, 0);
    power(idB, 210, 0, 0);
    await settle(tester);
    expect(find.text('200'), findsOneWidget);
    expect(find.text('210'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('record-button')));
    await tester.pump();
    expect(find.text('Stop recording'), findsOneWidget);

    now = now.add(const Duration(seconds: 2));
    power(idA, 200, 3, 2048); // 90 rpm
    power(idB, 220, 3, 2048);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Elapsed 00:02'), findsOneWidget);
    expect(find.text('90 rpm'), findsNWidgets(2));
    expect(find.text('B vs A: +10.0 %'), findsOneWidget);
    expect(tester.takeException(), isNull); // no overflow while recording

    await tester.tap(find.text('Stop recording'));
    await tester.pumpAndSettle();
    expect(files.saved, hasLength(1));
    final csv = files.saved.values.single.split('\r\n');
    expect(csv.first, DualRecorder.csvHeader.join(','));
    expect(csv.where((l) => l.contains(',A,Quarq,')), hasLength(1));
    expect(csv.where((l) => l.contains(',B,Kickr,')), hasLength(1));
    expect(find.textContaining('Saved 2 samples'), findsOneWidget);

    await tester.tap(find.text('Share CSV'));
    await tester.pump();
    expect(files.shared.single, startsWith('/recordings/dual-record-'));

    await tester.tap(find.text('Disconnect').first);
    await tester.pumpAndSettle();
    expect(find.text('Choose A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(ble.calls, contains('disconnect $idA'));
  });

  testWidgets('a dropped device shows reconnecting, then recovers', (
    tester,
  ) async {
    await pumpPage(tester);
    await choose(tester, 'A', idA);
    ble.failConnect.add(idA);
    ble.drop(idA);
    await settle(tester);
    expect(find.textContaining('Reconnecting'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // retry fails
    await tester.pump(const Duration(seconds: 2)); // next retry connects
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected · Power'), findsOneWidget);
  });

  testWidgets('leaving while recording asks, then stops and saves', (
    tester,
  ) async {
    await pumpPage(tester);
    await choose(tester, 'A', idA);
    await tester.tap(find.byKey(const ValueKey('record-button')));
    await tester.pump();
    power(idA, 150, 0, 0);
    await settle(tester);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Stop recording?'), findsOneWidget);
    await tester.tap(find.text('Keep recording'));
    await tester.pumpAndSettle();
    expect(find.text('Dual record'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop and leave'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(files.saved, hasLength(1));
    expect(wakelock.last, isFalse);
    expect(ble.calls, contains('disconnect $idA'));
  });

  testWidgets('Bluetooth off: explains instead of scanning', (tester) async {
    ble.availability = AvailabilityState.poweredOff;
    await pumpPage(tester);
    await tester.tap(find.text('Choose A'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bluetooth is off'), findsOneWidget);
    expect(ble.scanning, isFalse);
  });
}
