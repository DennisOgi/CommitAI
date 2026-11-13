import 'dart:async';
import 'dart:convert';

import 'package:daily_flutter/daily_flutter.dart';

import 'call_engine.dart';

/// Voice calls over Daily. This is the only file that touches the Daily SDK,
/// so SDK upgrades are contained here.
///
/// Daily is voice-only here: the camera stays off, and the Commit AI bot
/// (user id "commit-ai-bot") is hidden from the participant list.
class DailyCallEngine implements CallEngine {
  static const botUserId = 'commit-ai-bot';

  CallClient? _client;
  StreamSubscription<Event>? _sub;
  final _events = StreamController<CallEngineEvent>.broadcast();
  final Set<String> _humans = {};

  @override
  Stream<CallEngineEvent> get events => _events.stream;

  /// How long connecting to the call room may take before we give up and say so,
  /// instead of leaving the user on a call screen that never connects.
  static const joinTimeout = Duration(seconds: 25);

  @override
  Future<void> join({required String roomUrl, required String token, required String userName}) async {
    try {
      final client = _client ??= await CallClient.create().timeout(const Duration(seconds: 10));
      await _sub?.cancel();
      _sub = client.events.listen(_onEvent);
      await client.setUsername(userName).timeout(const Duration(seconds: 5));
      // Microphone on and camera off as part of joining (Daily's documented way), so the mic
      // permission prompt and publishing happen in one step.
      await client
          .join(
            url: Uri.parse(roomUrl),
            token: token,
            clientSettings: const ClientSettingsUpdate.set(
              inputs: InputSettingsUpdate.set(
                camera: CameraInputSettingsUpdate.set(isEnabled: BoolUpdate.set(false)),
                microphone: MicrophoneInputSettingsUpdate.set(isEnabled: BoolUpdate.set(true)),
              ),
            ),
          )
          .timeout(joinTimeout);
    } on TimeoutException {
      _events.add(EngineError('Couldn’t connect the call audio (timed out).'));
      throw const CallConnectException('Couldn’t connect the call audio. Check your connection and try again.');
    } catch (e) {
      _events.add(EngineError('Could not connect the call: $e'));
      throw CallConnectException('Couldn’t connect the call: $e');
    }
  }

  void _onEvent(Event event) {
    event.whenOrNull<void>(
      callStateUpdated: (data) {
        data.whenOrNull(
          joined: (_) => _events.add(EngineJoined()),
          left: () => _events.add(EngineLeft()),
        );
      },
      participantJoined: (p) {
        if (p.info.isLocal || p.info.userId == botUserId) return;
        _humans.add(p.id.toString());
        _events.add(RemoteJoined(p.info.username ?? 'Caller'));
      },
      participantLeft: (p) {
        if (_humans.remove(p.id.toString()) && _humans.isEmpty) _events.add(RemoteLeft());
      },
      appMessageReceived: (data, from) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) _events.add(BotMessage(decoded));
        } on FormatException {
          // Not ours.
        }
      },
      error: (message) => _events.add(EngineError(message)),
    );
  }

  @override
  Future<void> leave() async {
    _humans.clear();
    await _client?.leave();
  }

  @override
  Future<void> setMuted(bool muted) async => _client?.setInputsEnabled(microphone: !muted);

  /// On mobile, Daily exposes audio routes (earpiece, speakerphone, bluetooth,
  /// wired) as the available audio devices.
  @override
  Future<void> setSpeaker(bool on) async {
    final client = _client;
    if (client == null) return;
    final devices = client.availableDevices.microphone; // mobile audio routes live here
    final want = devices.where((d) {
      final label = d.label.toLowerCase();
      return on ? label.contains('speaker') : (label.contains('earpiece') || label.contains('phone') && !label.contains('speaker'));
    }).firstOrNull;
    if (want != null) await client.setAudioDevice(deviceId: want.deviceId);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _client?.dispose();
    _client = null;
    _events.close();
  }
}
