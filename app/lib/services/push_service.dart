import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../core/config.dart';
import '../data/backend.dart';
import '../models/models.dart';

/// Incoming calls arrive as data-only FCM pushes from the server:
///   {type: incoming_call, call_id, caller_name, mode, recorded, room_url}
/// In the background they raise the native call screen (CallKit / Android
/// full-screen intent); in the foreground they go straight to the app's own UI.
class PushService {
  static Future<void> init(Backend backend) async {
    if (!AppConfig.pushEnabled || AppConfig.demoMode) return;
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    final fm = FirebaseMessaging.instance;
    await fm.requestPermission();
    await backend.registerDevice(Platform.isIOS ? 'ios' : 'android', await fm.getToken());
    fm.onTokenRefresh.listen((t) => backend.registerDevice(Platform.isIOS ? 'ios' : 'android', t));

    FirebaseMessaging.onMessage.listen((m) {
      if (m.data['type'] == 'incoming_call') backend.incoming.add(_toIncoming(m.data));
    });

    FlutterCallkitIncoming.onEvent.listen((event) async {
      if (event == null) return;
      final body = Map<String, dynamic>.from(event.body as Map);
      final extra = Map<String, dynamic>.from((body['extra'] as Map?) ?? const {});
      switch (event.event) {
        case Event.actionCallAccept:
          await FlutterCallkitIncoming.endCall(body['id'] as String);
          backend.incoming.add(_toIncoming(extra, autoAccept: true));
        case Event.actionCallDecline:
          await backend.declineCall(body['id'] as String);
        default:
          break;
      }
    });
  }

  static IncomingCall _toIncoming(Map<String, dynamic> d, {bool autoAccept = false}) => IncomingCall(
        callId: d['call_id'] as String,
        callerName: (d['caller_name'] as String?) ?? 'Caller',
        recorded: d['recorded'] == 'true',
        mode: d['mode'] == 'corporate' ? AppMode.corporate : AppMode.personal,
        roomUrl: d['room_url'] as String?,
      );
}

@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final d = message.data;
  if (d['type'] != 'incoming_call') return;
  final work = d['mode'] == 'corporate';
  await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
    id: d['call_id'],
    nameCaller: d['caller_name'] ?? 'Caller',
    appName: 'Commit AI',
    handle: work ? 'Work call · recorded' : 'Commit AI',
    type: 0,
    duration: 45000,
    textAccept: 'Accept',
    textDecline: 'Decline',
    extra: Map<String, dynamic>.from(d),
    android: AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: work ? '#4338CA' : '#0F766E',
      actionColor: '#FFFFFF',
    ),
    ios: const IOSParams(handleType: 'generic', supportsVideo: false, audioSessionMode: 'voiceChat'),
  ));
}
