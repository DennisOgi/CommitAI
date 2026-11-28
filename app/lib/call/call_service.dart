import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native call plumbing on Android (android/.../MainActivity.kt, CallService.kt, CallAlerts.kt):
/// * a "call in progress" foreground service, without which Android silences the microphone as
///   soon as the screen locks or the user switches apps;
/// * the ringtone, vibration and full-screen alert for incoming calls;
/// * the ringback tone the caller hears while the other phone rings.
/// Everything is best effort: a failure here never stops the call itself.
class CallService {
  static const _channel = MethodChannel('commitai/call_service');
  static bool _running = false;
  static bool _ringing = false;
  static bool _ringback = false;

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod(method, args);
    } catch (_) {}
  }

  static Future<void> start(String peer) async {
    if (_running) return;
    _running = true;
    await _call('start', {'peer': peer});
  }

  static Future<void> stop() async {
    await stopRingback();
    if (!_running) return;
    _running = false;
    await _call('stop');
  }

  /// "Ready for calls" background service: keeps the app able to ring while it's in the background.
  static Future<void> standby(bool on) => _call(on ? 'standby' : 'standbyStop');

  /// Incoming call: ringtone + vibration + full-screen notification (wakes the screen).
  static Future<void> ring(String caller, {bool work = false}) async {
    _ringing = true;
    await _call('ring', {'caller': caller, 'work': work});
  }

  static Future<void> stopRing() async {
    if (!_ringing) return;
    _ringing = false;
    await _call('stopRing');
  }

  /// Outgoing call: the "ring ring" the caller hears until the other side answers.
  static Future<void> ringback() async {
    if (_ringback) return;
    _ringback = true;
    await _call('ringback');
  }

  static Future<void> stopRingback() async {
    if (!_ringback) return;
    _ringback = false;
    await _call('stopRingback');
  }
}
