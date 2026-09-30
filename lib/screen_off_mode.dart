/// "Keep broadcasting with screen off" (Android only).
///
/// Android freezes a backgrounded app and lets the CPU sleep, which stops the
/// 500 ms notify timer. So while advertising, the app always keeps the screen
/// on as long as it is open. With this mode on, a small native foreground
/// service (`BroadcastKeepAliveService.kt`, type `connectedDevice`) also holds
/// a partial wake lock, so broadcasting keeps going when the screen turns off
/// (e.g. the power button) or the user switches apps, and shows an ongoing
/// notification with a Stop button. The BLE work itself stays in this
/// isolate: the service runs no Dart.
///
/// [ScreenOffService] is the method-channel glue, [KeepAwake] holds the
/// mechanisms, and [ScreenOffStore] persists the setting.
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

/// What the app holds to keep running while it advertises.
enum KeepAwakeMode {
  /// Not advertising: nothing is held.
  none,

  /// The screen is kept on while the app is open (`wakelock_plus`).
  screenOn,

  /// The screen is kept on while the app is open, and [ScreenOffService]
  /// runs, so broadcasting also survives the screen turning off.
  screenOnAndService,
}

/// Holds the keep-awake mechanisms for the current state: the screen
/// wakelock whenever advertising, plus [ScreenOffService] in screen-off mode.
class KeepAwake {
  KeepAwake({required this.service, required this.screenWakelock});

  /// Runs the screen-off mechanism.
  final ScreenOffService service;

  /// Turns the keep-screen-on wakelock on or off.
  final Future<void> Function(bool enable) screenWakelock;

  /// What is currently held.
  KeepAwakeMode get mode => _mode;
  KeepAwakeMode _mode = KeepAwakeMode.none;

  /// Why the service didn't start in the last [update], if it didn't.
  String? get lastError => _lastError;
  String? _lastError;

  Future<void> _queue = Future.value();

  /// Holds what [advertising] and the [screenOff] setting call for: nothing
  /// when not advertising; otherwise the screen wakelock, plus the service
  /// when [screenOff] is on (if the service can't start, just the wakelock,
  /// with [lastError] set). [title] and [text] are the service
  /// notification's. Calls run one at a time.
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
    // _mode is updated after each step, so a step that throws leaves it
    // describing what is actually held.
    if (advertising && _mode == KeepAwakeMode.none) {
      await screenWakelock(true);
      _mode = KeepAwakeMode.screenOn;
    }
    final wantService = advertising && screenOff && service.isSupported;
    if (wantService && _mode == KeepAwakeMode.screenOn) {
      final error = await service.start(title: title, text: text);
      if (error == null) {
        _mode = KeepAwakeMode.screenOnAndService;
      } else {
        _lastError = error;
        await service.stop(); // in case it started after the timeout
      }
    } else if (!wantService && _mode == KeepAwakeMode.screenOnAndService) {
      await service.stop();
      _mode = KeepAwakeMode.screenOn;
    }
    if (!advertising && _mode == KeepAwakeMode.screenOn) {
      await screenWakelock(false);
      _mode = KeepAwakeMode.none;
    }
    return _mode;
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
