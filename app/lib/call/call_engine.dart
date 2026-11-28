import 'dart:async';

/// Media layer abstraction. [DailyCallEngine] is the real one; [DemoCallEngine]
/// simulates a client conversation so the whole product can be explored offline.
abstract class CallEngine {
  Stream<CallEngineEvent> get events;
  Future<void> join({required String roomUrl, required String token, required String userName});
  Future<void> leave();
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool on);
  void dispose();
}

sealed class CallEngineEvent {}

class EngineJoined extends CallEngineEvent {}

class EngineLeft extends CallEngineEvent {}

/// A remote human joined (the client's app, or the dialled GSM/landline leg).
class RemoteJoined extends CallEngineEvent {
  RemoteJoined(this.name);
  final String name;
}

class RemoteLeft extends CallEngineEvent {}

/// App message from the Commit Call bot (commitment hints, captions).
class BotMessage extends CallEngineEvent {
  BotMessage(this.data);
  final Map<String, dynamic> data;
}

class EngineError extends CallEngineEvent {
  EngineError(this.message);
  final String message;
}

/// Joining the call room failed or timed out; [message] is fit to show the user.
class CallConnectException implements Exception {
  const CallConnectException(this.message);
  final String message;
  @override
  String toString() => message;
}
