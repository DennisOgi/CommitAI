import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android "call in progress" foreground service (android/.../CallService.kt).
/// Without it Android silences the microphone as soon as the screen locks or the
/// user switches apps, so the other side stops hearing them mid-call.
class CallService {
  static const _channel = MethodChannel('commitai/call_service');
  static bool _running = false;

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> start(String peer) async {
    if (!_android || _running) return;
    try {
      await _channel.invokeMethod('start', {'peer': peer});
      _running = true;
    } catch (_) {
      // Best effort: the call still works while the app is on screen.
    }
  }

  static Future<void> stop() async {
    if (!_android || !_running) return;
    _running = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
