import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';

/// Deadline reminders scheduled on the phone itself.
///
/// The server also sends reminders by push, but push needs Firebase; these local notifications
/// work without it and fire even when the app is closed. For each of the user's live
/// commitments with a deadline we schedule two: a day before and 2 hours before.
///
/// Reminders are kept per mode (Personal / Work) because each mode lists its own commitments;
/// syncing one mode replaces only that mode's reminders.
class ReminderService {
  ReminderService._();
  static final instance = ReminderService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static const _channel = AndroidNotificationDetails(
    'commitment_reminders',
    'Commitment reminders',
    channelDescription: 'Reminders before your commitments are due',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _details = NotificationDetails(android: _channel, iOS: DarwinNotificationDetails());

  Future<void> _init() async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
    );
    _ready = true;
  }

  /// Ask for notification permission (Android 13+ / iOS). Safe to call repeatedly.
  Future<void> requestPermission() async {
    if (!supported) return;
    await _init();
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);
  }

  /// Replace this mode's reminders with ones for [items] (only the user's own, live, dated ones).
  Future<void> sync(AppMode mode, List<Commitment> items) async {
    if (!supported) return;
    try {
      await _init();
      final prefs = await SharedPreferences.getInstance();
      final key = 'reminder_ids_${mode.name}';
      for (final id in prefs.getStringList(key) ?? const <String>[]) {
        await _plugin.cancel(id: int.parse(id));
      }
      final now = DateTime.now();
      final scheduled = <String>[];
      for (final c in items) {
        if (c.byClient || !c.isLive || c.dueAt == null) continue;
        final due = c.dueAt!;
        final what = c.clientName == null ? c.title : '${c.title} · ${c.clientName}';
        for (final (stage, lead, title) in [
          (0, const Duration(days: 1), 'Due tomorrow'),
          (1, const Duration(hours: 2), 'Due in 2 hours'),
        ]) {
          final at = due.subtract(lead);
          if (!at.isAfter(now)) continue;
          final id = _id(mode, c.id, stage);
          await _plugin.zonedSchedule(
            id: id,
            scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
            notificationDetails: _details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            title: title,
            body: what,
            payload: c.id,
          );
          scheduled.add('$id');
        }
      }
      await prefs.setStringList(key, scheduled);
    } catch (e) {
      // Reminders are a convenience; never let them break the app.
      debugPrint('reminder sync failed: $e');
    }
  }

  /// Remove every reminder (e.g. on sign-out).
  Future<void> clear() async {
    if (!supported) return;
    try {
      await _init();
      await _plugin.cancelAll();
      final prefs = await SharedPreferences.getInstance();
      for (final m in AppMode.values) {
        await prefs.remove('reminder_ids_${m.name}');
      }
    } catch (_) {}
  }

  /// A stable 31-bit notification id per (mode, commitment, stage).
  static int _id(AppMode mode, String commitmentId, int stage) {
    var h = 0;
    for (final unit in '${mode.name}:$commitmentId:$stage'.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return h;
  }
}
