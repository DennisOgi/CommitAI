import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../call/call_actions.dart';
import '../call/post_call_review_screen.dart';
import '../call/review_actions.dart';
import 'person_sheet.dart';

class RecentsScreen extends StatelessWidget {
  const RecentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Loader<(List<CallRecord>, List<Commitment>, Set<String>)>(
      load: (b) async {
        final calls = await b.calls();
        final review = await b.commitments(status: 'pending_review').catchError((_) => <Commitment>[]);
        return (calls, review, await ignoredReviews());
      },
      builder: (context, data, reload) {
        final (calls, review, ignored) = data;
        // Calls with commitments waiting for a review, newest first, minus the ones ignored.
        final waiting = <String, List<Commitment>>{};
        for (final c in review) {
          if (c.callId != null && !ignored.contains(c.callId)) waiting.putIfAbsent(c.callId!, () => []).add(c);
        }
        final pending = calls.where((c) => waiting.containsKey(c.id)).toList();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.only(bottom: 110), children: [
            const PageTitle('Calls'),
            if (pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: _ReviewCard(
                  call: pending.first,
                  count: waiting[pending.first.id]!.length,
                  more: pending.length - 1,
                  onReview: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostCallReviewScreen(callId: pending.first.id)));
                    reload();
                  },
                  onIgnore: () async {
                    final c = pending.first;
                    if (await ignoreReview(context, callId: c.id, mode: c.mode, commitmentIds: [for (final x in waiting[c.id]!) x.id])) {
                      reload();
                    }
                  },
                ),
              ),
            if (calls.isEmpty)
              EmptyState(
                icon: Icons.call_rounded,
                title: app.corporate ? 'No work calls yet' : 'No calls yet',
                body: app.corporate ? 'Call a client from the keypad or Clients.' : 'Your calls will show up here.',
              )
            else
              for (final c in calls)
                CallTile(
                  call: c,
                  onTap: () => showPersonSheet(
                    context,
                    name: c.counterpartName,
                    phone: c.counterpartNumber,
                    userId: c.counterpartUserId,
                    contactId: c.contactId,
                    callId: c.id,
                    callHasDetail: c.mode == AppMode.corporate && !c.missed,
                    isClient: c.mode == AppMode.corporate,
                  ),
                  onCall: () => placeCall(
                    context,
                    name: c.counterpartName,
                    pstn: c.channel != CallChannel.app,
                    phone: c.counterpartNumber,
                    calleeUserId: c.channel == CallChannel.app ? c.counterpartUserId : null,
                    contactId: c.contactId,
                    isClient: c.mode == AppMode.corporate,
                  ),
                ),
          ]),
        );
      },
    );
  }
}

/// "2 commitments from your call with Stella" · Ignore · Review. Never blocks anything.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.call, required this.count, required this.more, required this.onReview, required this.onIgnore});
  final CallRecord call;
  final int count;
  final int more;
  final VoidCallback onReview;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
      decoration: BoxDecoration(
        color: p.accentSoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.accent.withValues(alpha: .25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.auto_awesome_rounded, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count commitment${count == 1 ? '' : 's'} from your call with ${call.counterpartName.split(' ').first}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ]),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 2),
            child: Text('+$more more call${more == 1 ? '' : 's'} to review', style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
          ),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: onIgnore, child: const Text('Ignore')),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: onReview,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Review'),
          ),
        ]),
      ]),
    );
  }
}
