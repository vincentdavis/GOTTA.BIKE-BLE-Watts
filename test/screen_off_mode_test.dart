import 'dart:async';

import 'package:cps_emulator/screen_off_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const channel = MethodChannel(ScreenOffService.channelName);

/// Stands in for MainActivity + BroadcastKeepAliveService.
class FakeNative {
  FakeNative() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  /// Every call, plus the wakelock changes, in order.
  final log = <String>[];

  /// What `start` answers: null = running, a string = the error.
  String? startError;

  /// When set, `start` waits for it (a slow service).
  Completer<void>? startGate;

  /// When set, `start` never answers.
  bool startHangs = false;

  bool notificationsAllowed = true;
  bool running = false;
  Map<Object?, Object?>? lastStartArgs;

  Future<Object?> _handle(MethodCall call) async {
    log.add(call.method);
    switch (call.method) {
      case 'start':
        lastStartArgs = call.arguments as Map<Object?, Object?>;
        await startGate?.future;
        if (startHangs) return Completer<String?>().future;
        running = startError == null;
        return startError;
      case 'stop':
        running = false;
        return null;
      case 'notificationsAllowed':
      case 'requestNotifications':
        return notificationsAllowed;
    }
    throw MissingPluginException();
  }

  Future<void> wakelock(bool on) async => log.add(on ? 'wake on' : 'wake off');

  /// Delivers a call from the native side to Dart.
  Future<void> sendFromNative(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method)),
          (_) {},
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;
  late ScreenOffService service;
  late KeepAwake keepAwake;

  setUp(() {
    native = FakeNative();
    service = ScreenOffService(supported: true);
    keepAwake = KeepAwake(service: service, screenWakelock: native.wakelock);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('KeepAwake', () {
    test('not advertising holds nothing', () async {
      final mode = await keepAwake.update(advertising: false, screenOff: true);
      expect(mode, KeepAwakeMode.none);
      expect(native.log, isEmpty);
    });

    test(
      'screen-off setting off: keeps the screen on, then releases',
      () async {
        expect(
          await keepAwake.update(advertising: true, screenOff: false),
          KeepAwakeMode.screenOn,
        );
        expect(
          await keepAwake.update(advertising: false, screenOff: false),
          KeepAwakeMode.none,
        );
        expect(native.log, ['wake on', 'wake off']);
      },
    );

    test('screen-off setting on: runs the service, then stops it', () async {
      final mode = await keepAwake.update(
        advertising: true,
        screenOff: true,
        title: 'Broadcasting as “X”',
        text: 'Tap to open',
      );
      expect(mode, KeepAwakeMode.screenOff);
      expect(native.running, isTrue);
      expect(native.lastStartArgs, {
        'title': 'Broadcasting as “X”',
        'text': 'Tap to open',
      });
      expect(keepAwake.lastError, isNull);

      await keepAwake.update(advertising: false, screenOff: true);
      expect(native.running, isFalse);
      expect(native.log, ['start', 'stop']); // the screen wakelock is unused
    });

    test('a service that fails to start falls back to screen on', () async {
      native.startError = 'Bluetooth permission missing';
      final mode = await keepAwake.update(advertising: true, screenOff: true);
      expect(mode, KeepAwakeMode.screenOn);
      expect(keepAwake.lastError, 'Bluetooth permission missing');
      expect(native.log, ['start', 'stop', 'wake on']);

      // Next time it starts: the service takes over, then the screen is freed.
      native.startError = null;
      native.log.clear();
      expect(
        await keepAwake.update(advertising: true, screenOff: true),
        KeepAwakeMode.screenOff,
      );
      expect(keepAwake.lastError, isNull);
      expect(native.log, ['start', 'wake off']);
    });

    test('switching to screen on takes the wakelock before stopping', () async {
      await keepAwake.update(advertising: true, screenOff: true);
      native.log.clear();
      expect(
        await keepAwake.update(advertising: true, screenOff: false),
        KeepAwakeMode.screenOn,
      );
      expect(native.log, ['wake on', 'stop']);
    });

    test('unchanged state does nothing', () async {
      await keepAwake.update(advertising: true, screenOff: true);
      native.log.clear();
      await keepAwake.update(advertising: true, screenOff: true);
      expect(native.log, isEmpty);
    });

    test('unsupported platforms ignore the setting', () async {
      final unsupported = KeepAwake(
        service: ScreenOffService(supported: false),
        screenWakelock: native.wakelock,
      );
      expect(
        await unsupported.update(advertising: true, screenOff: true),
        KeepAwakeMode.screenOn,
      );
      expect(native.log, ['wake on']);
    });

    test('overlapping updates run in order', () async {
      native.startGate = Completer<void>();
      final start = keepAwake.update(advertising: true, screenOff: true);
      final stop = keepAwake.update(advertising: false, screenOff: true);
      await Future<void>.delayed(Duration.zero);
      expect(native.log, ['start']); // the stop waits for the start
      native.startGate!.complete();
      expect(await start, KeepAwakeMode.screenOff);
      expect(await stop, KeepAwakeMode.none);
      expect(native.log, ['start', 'stop']);
      expect(native.running, isFalse);
    });

    test('a service that never answers times out', () async {
      native.startHangs = true;
      final impatient = KeepAwake(
        service: ScreenOffService(
          supported: true,
          startTimeout: const Duration(milliseconds: 20),
        ),
        screenWakelock: native.wakelock,
      );
      expect(
        await impatient.update(advertising: true, screenOff: true),
        KeepAwakeMode.screenOn,
      );
      expect(impatient.lastError, 'the service did not respond');
      // It is told to stop in case it comes up late.
      expect(native.log, ['start', 'stop', 'wake on']);
    });
  });

  group('ScreenOffService', () {
    test('platform errors become messages', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom', message: 'Not allowed');
          });
      expect(await service.start(title: 't', text: 'x'), 'Not allowed');
      expect(await service.notificationsAllowed(), isFalse);
      await service.stop(); // doesn't throw
    });

    test('a missing native side is reported, not thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await service.start(title: 't', text: 'x'),
        'not available in this build',
      );
      expect(await service.requestNotifications(), isFalse);
      await service.stop();
    });

    test('unsupported platforms never call native code', () async {
      final unsupported = ScreenOffService(supported: false);
      expect(await unsupported.start(title: 't', text: 'x'), isNotNull);
      expect(await unsupported.requestNotifications(), isFalse);
      await unsupported.stop();
      expect(native.log, isEmpty);
    });

    test('notification permission answers pass through', () async {
      expect(await service.requestNotifications(), isTrue);
      native.notificationsAllowed = false;
      expect(await service.notificationsAllowed(), isFalse);
    });

    test('the notification Stop button reaches onStopRequested', () async {
      var stops = 0;
      service.onStopRequested = () => stops++;
      await native.sendFromNative('stopRequested');
      expect(stops, 1);
    });
  });

  group('ScreenOffStore', () {
    test('defaults to off and round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ScreenOffStore();
      expect(await store.load(), isFalse);
      await store.save(true);
      expect(await store.load(), isTrue);
    });

    test('a value of the wrong type reads as off', () async {
      SharedPreferences.setMockInitialValues({
        'screen_off_broadcast_v1': 'yes',
      });
      expect(await ScreenOffStore().load(), isFalse);
    });
  });
}
