import 'dart:async';

import '../data/demo_backend.dart';
import 'call_engine.dart';

/// Plays a believable call without any network: the far end "answers", and for
/// recorded client calls the bot's captions and commitment hints arrive on cue.
class DemoCallEngine implements CallEngine {
  DemoCallEngine({required this.backend, required this.callId, required this.peerName, required this.scripted});

  final DemoBackend backend;
  final String callId;
  final String peerName;
  final bool scripted;

  final _events = StreamController<CallEngineEvent>.broadcast();
  final List<Timer> _timers = [];

  @override
  Stream<CallEngineEvent> get events => _events.stream;

  void _at(int ms, void Function() f) => _timers.add(Timer(Duration(milliseconds: ms), f));

  @override
  Future<void> join({required String roomUrl, required String token, required String userName}) async {
    _at(300, () => _events.add(EngineJoined()));
    _at(2600, () {
      backend.markAnswered(callId);
      _events.add(RemoteJoined(peerName));
    });
    if (!scripted) return;
    const start = 5200;
    const gap = 3400;
    for (var i = 0; i < DemoBackend.demoScript.length; i++) {
      final (speaker, text) = DemoBackend.demoScript[i];
      _at(start + i * gap, () {
        _events.add(BotMessage({'type': 'caption', 'speaker': speaker, 'text': text}));
        final hint = DemoBackend.demoHints[i];
        if (hint != null) {
          _at(900, () => _events.add(BotMessage({
                'type': 'commitment_detected',
                'title': hint.title,
                'due_text': hint.dueText,
                'category': hint.category,
                'quote': text,
              })));
        }
      });
    }
  }

  @override
  Future<void> leave() async {
    for (final t in _timers) {
      t.cancel();
    }
    _events.add(EngineLeft());
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeaker(bool on) async {}

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _events.close();
  }
}
