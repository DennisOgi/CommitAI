import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';

/// Calls whose review the user chose to ignore (work calls: the reminder is hidden only).
Future<Set<String>> ignoredReviews() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList('ignored_reviews') ?? const []).toSet();
}

/// "Ignore" on a call's commitments.
/// * Personal call: the commitments are discarded (nobody else ever sees them).
/// * Work call: only the reminder is hidden; your company still receives them after 24 hours,
///   as it does for any call nobody reviews.
/// Returns true when ignored.
Future<bool> ignoreReview(BuildContext context, {required String callId, required AppMode mode, required List<String> commitmentIds}) async {
  final work = mode == AppMode.corporate;
  final go = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(work ? 'Skip this review?' : 'Ignore these commitments?'),
      content: Text(work
          ? 'They’ll be shared with your manager as found, after 24 hours, like any call that isn’t reviewed.'
          : 'They’ll be discarded and you won’t get reminders for them.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(work ? 'Skip' : 'Ignore')),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;
  final app = AppScope.read(context);
  try {
    if (!work && commitmentIds.isNotEmpty) {
      await app.backend!.submitReview(callId, accept: const [], reject: commitmentIds);
    }
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList('ignored_reviews') ?? <String>[])..add(callId);
    await prefs.setStringList('ignored_reviews', ids.length > 300 ? ids.sublist(ids.length - 300) : ids);
    app.refresh();
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}
