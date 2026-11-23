import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as phone;
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/backend.dart';

/// Keeps the user's phone contacts in their Personal contacts, the way messaging apps do.
///
/// * The first import happens as soon as contacts permission is given (onboarding or the
///   Contacts tab). After that the app re-syncs quietly at most once a day to pick up new
///   contacts and people who have joined Commit AI since. The server skips anything already
///   imported, so syncing never duplicates.
/// * Nothing leaves the phone without the user's permission: a sync never asks for it.
class ContactSync {
  ContactSync._();

  static const _resyncAfter = Duration(hours: 24);
  static bool _running = false;

  static bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static String _key(String userId) => 'contacts_synced_at:$userId';

  /// Has this account imported its phone contacts at least once (on this phone)?
  static Future<bool> hasSynced(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(userId)) != null;
  }

  static Future<bool> permitted() async {
    if (!supported) return false;
    try {
      final s = await perm.Permission.contacts.status;
      return s.isGranted || s.isLimited;
    } catch (_) {
      return false;
    }
  }

  /// Import now (if permission is already given). [force] ignores the once-a-day limit.
  /// Returns null when nothing ran (no permission, already running, or synced recently).
  static Future<({int imported, int skipped, int onApp})?> run(Backend backend, String userId, {bool force = false}) async {
    if (_running || !await permitted()) return null;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_key(userId));
    if (!force && last != null && DateTime.now().millisecondsSinceEpoch - last < _resyncAfter.inMilliseconds) return null;
    _running = true;
    try {
      final all = await phone.FlutterContacts.getAll(
          properties: {phone.ContactProperty.name, phone.ContactProperty.phone, phone.ContactProperty.email});
      final payload = [
        for (final c in all)
          if ((c.displayName ?? '').trim().isNotEmpty && (c.phones.isNotEmpty || c.emails.isNotEmpty))
            {
              'name': c.displayName!.trim().length > 120 ? c.displayName!.trim().substring(0, 120) : c.displayName!.trim(),
              'phones': [for (final p in c.phones.take(10)) p.number],
              'emails': [for (final e in c.emails.take(10)) e.address],
            }
      ];
      final r = await backend.importContacts(payload);
      await prefs.setInt(_key(userId), DateTime.now().millisecondsSinceEpoch);
      return r;
    } finally {
      _running = false;
    }
  }
}
