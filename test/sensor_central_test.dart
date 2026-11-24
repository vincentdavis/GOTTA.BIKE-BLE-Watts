import 'package:cps_emulator/cpm_codec.dart';
import 'package:cps_emulator/cps_peripheral.dart';
import 'package:cps_emulator/sensor_central.dart';
import 'package:cps_emulator/sensor_decoders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fake_central_platform.dart';

const pm = 'AA:BB:CC:00:00:01';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'condition not reached');
}

void main() {
  late FakeCentralPlatform ble;

  setUp(() {
    ble = FakeCentralPlatform();
    UniversalBle.setInstance(ble);
    ble.services[pm] = [
      notifyService(CentralUuids.cpsService, [CyclingPowerPeripheral.cpmChar]),
      notifyService(CentralUuids.ftmsService, [
        CentralUuids.indoorBikeDataChar,
      ]),
      // Not a measurement: ignored.
      notifyService('0000180a-0000-1000-8000-00805f9b34fb', [
        '00002a29-0000-1000-8000-00805f9b34fb',
      ]),
    ];
  });

  SensorLink link() {
    final l = SensorLink(
      deviceId: pm,
      name: 'Quarq',
      retryDelays: const [Duration(milliseconds: 5)],
      disconnectTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(l.close);
    return l;
  }

  test('kindsAdvertised maps service UUIDs (any case/length)', () {
    expect(
      CentralUuids.kindsAdvertised([
        '1818',
        '0000180D-0000-1000-8000-00805F9B34FB',
      ]),
      {MeasurementKind.cyclingPower, MeasurementKind.heartRate},
    );
  });

  test(
    'connects, subscribes to each measurement and forwards packets',
    () async {
      final l = link();
      final packets = <SensorPacket>[];
      l.packets.listen(packets.add);
      await l.open();
      expect(l.state.value, SensorLinkState.connected);
      expect(l.subscribed, {
        MeasurementKind.cyclingPower,
        MeasurementKind.indoorBike,
      });
      expect(
        ble.calls,
        containsAll(['notification $pm 2a63', 'notification $pm 2ad2']),
      );

      final bytes = CpmCodec.encode(
        powerWatts: 250,
        cumulativeCrankRevs: 1,
        lastCrankEventTime: 2,
      );
      ble.notify(pm, CyclingPowerPeripheral.cpmChar, bytes);
      ble.notify('OTHER', CyclingPowerPeripheral.cpmChar, bytes); // not ours
      await until(() => packets.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(packets, hasLength(1));
      expect(packets.single.kind, MeasurementKind.cyclingPower);
      expect(packets.single.bytes, bytes);
      await l.close();
    },
  );

  test('re-connects after a drop and after a failed attempt', () async {
    final l = link();
    await l.open();
    ble.failConnect.add(pm);
    ble.drop(pm);
    await until(() => l.state.value == SensorLinkState.reconnecting);
    // First retry fails ("out of range"), the next one succeeds.
    await until(() => l.state.value == SensorLinkState.connected);
    expect(l.drops, 1);
    expect(
      ble.calls.where((c) => c == 'connect $pm').length,
      greaterThanOrEqualTo(3),
    );
    await l.close();
  });

  test('a device without supported measurements keeps retrying', () async {
    ble.services[pm] = const [];
    final l = link();
    await l.open();
    expect(l.state.value, SensorLinkState.reconnecting);
    expect(l.lastError, contains('no supported measurement'));
    await l.close();
  });

  test('close stops retries and disconnects', () async {
    final l = link();
    await l.open();
    await l.close();
    expect(l.state.value, SensorLinkState.disconnected);
    expect(ble.calls.last, 'disconnect $pm');
    final connects = ble.calls.where((c) => c.startsWith('connect')).length;
    ble.drop(pm);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ble.calls.where((c) => c.startsWith('connect')).length, connects);
  });
}
