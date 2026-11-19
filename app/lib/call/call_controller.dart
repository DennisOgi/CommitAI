import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:permission_handler/permission_handler.dart';

import '../core/config.dart';
import '../data/backend.dart';
import '../data/demo_backend.dart';
import '../models/models.dart';
import 'call_engine.dart';
import 'call_service.dart';
import 'daily_call_engine.dart';
import 'demo_call_engine.dart';

enum CallPhase { idle, connecting, ringing, active, ended }

class Caption {
  Caption(this.speaker, this.text);
  final String speaker;
  final String text;
}

/// One live call at a time. Screens listen to this.
class CallController extends ChangeNotifier {
  CallController(this.backend, this.userName);

  final Backend backend;
  String userName;

  CallPhase phase = CallPhase.idle;
  CallRecord? call;
  String peerName = '';
  String peerDetail = '';
  bool recorded = false;
  String? disclosure;
  bool muted = false;
  bool speaker = false;
  bool outbound = true;
  DateTime? connectedAt;
  String? error;
  final List<LiveHint> hints = [];
  final List<Caption> captions = [];
  final List<String> flagged = []; // moments the employee marked as a promise

  /// Fires once when a recorded call ends, so the UI can open the review.
  final ValueNotifier<String?> reviewReady = ValueNotifier(null);

  CallEngine? _engine;
  StreamSubscription<CallEngineEvent>? _sub;
  Timer? _ticker;
  Timer? _ringWatch;
  static const ringTimeout = Duration(seconds: 60);

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;
  Duration get elapsed => connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  Future<bool> _micOk() async {
    if (AppConfig.demoMode) return true;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      error = 'Microphone access is needed to make calls.';
      notifyListeners();
      return false;
    }
    return true;
  }

  /// Returns a message when the call couldn't ring (e.g. callee is at work).
  Future<String?> dial({
    required String name,
    String? detail,
    bool pstn = false,
    String? phone,
    String? calleeUserId,
    String? contactId,
    bool isClient = false,
  }) async {
    if (busy || !await _micOk()) return error;
    _reset();
    outbound = true;
    peerName = name;
    peerDetail = detail ?? '';
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      final start = await backend.startCall(pstn: pstn, phone: phone, calleeUserId: calleeUserId, contactId: contactId, displayName: name);
      if (start.decision != 'ring') {
        phase = CallPhase.idle;
        notifyListeners();
        return start.message ?? '$name can\'t take calls right now.';
      }
      call = start.call;
      recorded = start.recorded;
      disclosure = start.disclosure;
      phase = CallPhase.ringing;
      notifyListeners();
      await _join(start.roomUrl, start.token, scripted: recorded && isClient);
      if (phase == CallPhase.ringing) unawaited(CallService.ringback());
      _watchCall();
      return null;
    } catch (e) {
      error = e.toString();
      unawaited(backend.reportProblem('dial', error!, callId: call?.id));
      await hangUp(); // ends it on the server too, so the other phone stops ringing / waiting
      return error;
    }
  }

  Future<void> accept(IncomingCall incoming) async {
    // The call screen is already open when this runs, so every early exit must end the
    // call visibly (with the reason) rather than leave a screen with nothing to hang up.
    if (busy) {
      error = 'You are already on a call.';
      phase = CallPhase.ended;
      notifyListeners();
      return;
    }
    if (!await _micOk()) {
      phase = CallPhase.ended; // _micOk set the error message
      notifyListeners();
      unawaited(backend.declineCall(incoming.callId).catchError((_) {}));
      return;
    }
    _reset();
    outbound = false;
    peerName = incoming.callerName.split(' · ').first;
    peerDetail = incoming.callerName.contains(' · ') ? incoming.callerName.split(' · ').last : '';
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      final r = await backend.acceptCall(incoming.callId);
      recorded = r.recorded;
      disclosure = r.disclosure;
      call = (await backend.callDetail(incoming.callId)).call;
      await _join(r.roomUrl, r.token, scripted: recorded);
      _watchCall();
    } catch (e) {
      error = e.toString();
      unawaited(backend.reportProblem('accept', error!, callId: incoming.callId));
      await hangUp();
      if (call == null) unawaited(backend.endCall(incoming.callId).catchError((_) {}));
    }
  }

  Future<void> decline(IncomingCall incoming) => backend.declineCall(incoming.callId);

  Future<void> _join(String roomUrl, String token, {required bool scripted}) async {
    final b = backend;
    _engine = b is DemoBackend
        ? DemoCallEngine(backend: b, callId: call!.id, peerName: peerName, scripted: scripted)
        : DailyCallEngine();
    _sub = _engine!.events.listen(_onEngine);
    unawaited(CallService.start(peerName));
    await _engine!.join(roomUrl: roomUrl, token: token, userName: userName);
    if (!outbound) _connected();
  }

  /// Watches the call on the server for as long as it lasts:
  /// * while an outbound call rings: give up after [ringTimeout], and stop if the other side
  ///   declined or the call was missed;
  /// * once connected: if the other side hung up (the server marks the call completed), end it
  ///   here too, even if the audio connection didn't tell us.
  void _watchCall() {
    if (backend is DemoBackend) return;
    final started = DateTime.now();
    _ringWatch?.cancel();
    _ringWatch = Timer.periodic(const Duration(seconds: 3), (t) async {
      final c = call;
      if (c == null || phase == CallPhase.ended || phase == CallPhase.idle) {
        t.cancel();
        return;
      }
      if (phase == CallPhase.ringing && DateTime.now().difference(started) > ringTimeout) {
        t.cancel();
        error = 'No answer.';
        await hangUp();
        return;
      }
      try {
        final status = (await backend.callDetail(c.id)).call.status;
        if (status == 'ringing' || status == 'active') return;
        if (phase == CallPhase.ended || phase == CallPhase.idle) return;
        t.cancel();
        if (phase == CallPhase.ringing || phase == CallPhase.connecting) {
          error = status == 'rejected' ? '$peerName declined the call.' : 'No answer.';
        }
        await hangUp(); // the other side ended it
      } catch (_) {
        // Transient network errors shouldn't drop the call.
      }
    });
  }

  void _connected() {
    unawaited(CallService.stopRingback());
    if (phase == CallPhase.active) return;
    phase = CallPhase.active;
    connectedAt = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  void _onEngine(CallEngineEvent e) {
    switch (e) {
      case RemoteJoined():
        _connected();
      case RemoteLeft():
        hangUp();
      case BotMessage(:final data):
        if (data['type'] == 'commitment_detected') {
          hints.insert(0, LiveHint.fromJson(data));
          HapticFeedback.lightImpact();
        } else if (data['type'] == 'caption') {
          captions.add(Caption(data['speaker'] ?? 'unknown', data['text'] ?? ''));
          if (captions.length > 60) captions.removeAt(0);
        }
        notifyListeners();
      case EngineError(:final message):
        error = message;
        notifyListeners();
      case EngineLeft():
        // We were dropped from the room (network loss, room expired) without hanging up.
        if (phase == CallPhase.active || phase == CallPhase.ringing) {
          error = 'Call disconnected.';
          hangUp();
        }
      case EngineJoined():
        break;
    }
  }

  Future<void> toggleMute() async {
    muted = !muted;
    notifyListeners();
    await _engine?.setMuted(muted);
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    notifyListeners();
    await _engine?.setSpeaker(speaker);
  }

  /// "That was a promise" — the employee marks a moment the AI might miss.
  void flagMoment() {
    flagged.add('Commitment at ${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}');
    HapticFeedback.mediumImpact();
    notifyListeners();
    // Tell the server so extraction looks hardest at this moment (best effort).
    final c = call;
    if (c != null && recorded) unawaited(backend.flagMoment(c.id, elapsed.inMilliseconds).catchError((_) {}));
  }

  /// Ends the call. Always closes the call screen, whatever state the call got stuck in.
  Future<void> hangUp() async {
    if (phase == CallPhase.ended) return;
    final c = call;
    final wasRecorded = recorded;
    final wasConnected = connectedAt != null;
    // Decide the review before telling the UI, so the call screen can open it straight away
    // (the review screen itself waits for the transcript to be processed).
    if (c != null && wasRecorded && wasConnected) reviewReady.value = c.id;
    phase = CallPhase.ended;
    _ticker?.cancel();
    _ringWatch?.cancel();
    notifyListeners();
    unawaited(CallService.stop());
    if (c != null) {
      // Tell the server first, so the other phone hangs up even if leaving the room is slow.
      try {
        await backend.endCall(c.id).timeout(const Duration(seconds: 10));
        if (wasRecorded && wasConnected && backend is DemoBackend) {
          unawaited(backend.simulateExtraction(c.id)); // demo stands in for the bot
        }
      } catch (_) {
        // Best effort; the server also ends the call when the room empties.
      }
    }
    final engine = _engine;
    _engine = null;
    try {
      await engine?.leave().timeout(const Duration(seconds: 5));
    } catch (_) {
      // A slow or failed leave must not keep the user on the call screen.
    }
    engine?.dispose();
    await _sub?.cancel();
  }

  void dismiss() {
    _reset();
    phase = CallPhase.idle;
    notifyListeners();
  }

  void _reset() {
    call = null;
    error = null;
    muted = false;
    speaker = false;
    connectedAt = null;
    recorded = false;
    disclosure = null;
    hints.clear();
    captions.clear();
    flagged.clear();
    _ticker?.cancel();
  }

  @override
  void dispose() {
    unawaited(CallService.stop());
    _ticker?.cancel();
    _ringWatch?.cancel();
    _sub?.cancel();
    _engine?.dispose();
    super.dispose();
  }
}
