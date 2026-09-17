/// "Keep broadcasting with screen off" (Android only).
///
/// Android freezes a backgrounded app and lets the CPU sleep, which stops the
/// 500 ms notify timer, so by default the app keeps the screen on while
/// advertising. With this mode on, a small native foreground service
/// (`BroadcastKeepAliveService.kt`, type `connectedDevice`) holds a partial
/// wake lock instead, and shows an ongoing notification with a Stop button.
/// The BLE work itself stays in this isolate: the service runs no Dart.
///
/// [ScreenOffService] is the method-channel glue, [KeepAwake] decides which
/// mechanism is active, and [ScreenOffStore] persists the setting.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Talks to `BroadcastKeepAliveService` through `MainActivity`.
class ScreenOffService {
  ScreenOffService({
    bool? supported,
    this.startTimeout = const Duration(seconds: 5),
  }) : isSupported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (isSupported) _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String channelName = 'gotta.bike/keep_alive';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// Whether this platform has the service (Android only).
  final bool isSupported;

  /// How long [start] waits for the service to report back.
  final Duration startTimeout;

  /// Called when the user taps Stop in the notification.
  VoidCallback? onStopRequested;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'stopRequested') onStopRequested?.call();
  }

  /// Whether the ongoing notification can be shown (the service runs either
  /// way; without permission the notification is only listed in the
  /// system's task manager).
  Future<bool> notificationsAllowed() => _askBool('notificationsAllowed');

  /// Asks for the notification permission (Android 13+) when needed.
  /// Returns whether notifications are allowed afterwards.
  Future<bool> requestNotifications() => _askBool('requestNotifications');

  Future<bool> _askBool(String method) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts the service with the notification's [title] and [text]; a
  /// running service just updates its notification. Returns null once the
  /// service runs in the foreground, else why it didn't start.
  Future<String?> start({required String title, required String text}) async {
    if (!isSupported) return 'not supported on this device';
    try {
      return await _channel
          .invokeMethod<String>('start', {'title': title, 'text': text})
          .timeout(
            startTimeout,
            onTimeout: () => 'the service did not respond',
          );
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return 'not available in this build';
    }
  }

  /// Stops the service (a no-op when it isn't running).
  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Nothing to undo: the service is gone or never started.
    } on MissingPluginException {
      // Same.
    }
  }
}

/// How the app is kept running while it advertises.
enum KeepAwakeMode {
  /// Not advertising: nothing is held.
  none,

  /// The screen is kept on (`wakelock_plus`), so the app stays in front.
  screenOn,

  /// [ScreenOffService] runs: the screen may turn off.
  screenOff,
}

/// Chooses and holds the keep-awake mechanism for the current state.
class KeepAwake {
  KeepAwake({required this.service, required this.screenWakelock});

  /// Runs the screen-off mechanism.
  final ScreenOffService service;

  /// Turns the keep-screen-on wakelock on or off.
  final Future<void> Function(bool enable) screenWakelock;

  /// The mechanism currently held.
  KeepAwakeMode get mode => _mode;
  KeepAwakeMode _mode = KeepAwakeMode.none;

  /// Why screen-off mode didn't start in the last [update], if it didn't.
  String? get lastError => _lastError;
  String? _lastError;

  Future<void> _queue = Future.value();

  /// Holds what [advertising] and the [screenOff] setting call for: nothing
  /// when not advertising, else the screen-off service (falling back to
  /// keeping the screen on if it can't start). [title] and [text] are the
  /// service notification's. Calls run one at a time.
  Future<KeepAwakeMode> update({
    required bool advertising,
    required bool screenOff,
    String title = '',
    String text = '',
  }) {
    final run = _queue.then(
      (_) => _update(advertising, screenOff, title, text),
    );
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<KeepAwakeMode> _update(
    bool advertising,
    bool screenOff,
    String title,
    String text,
  ) async {
    _lastError = null;
    var target = !advertising
        ? KeepAwakeMode.none
        : (screenOff && service.isSupported)
        ? KeepAwakeMode.screenOff
        : KeepAwakeMode.screenOn;
    if (target == _mode) return _mode;

    if (target == KeepAwakeMode.screenOff) {
      final error = await service.start(title: title, text: text);
      if (error != null) {
        _lastError = error;
        await service.stop(); // in case it started after the timeout
        target = KeepAwakeMode.screenOn;
      }
    }
    // Take the new mechanism before releasing the old one, so the app is
    // never left without either.
    if (target == KeepAwakeMode.screenOn && _mode != KeepAwakeMode.screenOn) {
      await screenWakelock(true);
    }
    if (_mode == KeepAwakeMode.screenOn && target != KeepAwakeMode.screenOn) {
      await screenWakelock(false);
    }
    if (_mode == KeepAwakeMode.screenOff && target != KeepAwakeMode.screenOff) {
      await service.stop();
    }
    return _mode = target;
  }
}

/// Persists the "keep broadcasting with screen off" setting (default off).
class ScreenOffStore {
  static const String _key = 'screen_off_broadcast_v1';

  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      return prefs.getBool(_key) ?? false;
    } on TypeError {
      return false; // something else stored under the key
    }
  }

  Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}
