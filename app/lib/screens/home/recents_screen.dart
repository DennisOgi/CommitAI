import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../call/call_actions.dart';
import '../call/call_detail_screen.dart';
import '../call/post_call_review_screen.dart';

class RecentsScreen extends StatelessWidget {
  const RecentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Loader<(List<CallRecord>, List<Commitment>)>(
      load: (b) async {
        final calls = await b.calls();
        final review = app.corporate ? await b.commitments(status: 'pending_review') : <Commitment>[];
        return (calls, review);
      },
      builder: (context, data, reload) {
        final (calls, review) = data;
        final reviewCalls = {for (final c in review) if (c.callId != null) c.callId!};
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text('Calls', style: AppType.display(36, weight: FontWeight.w500)),
            ),
            if (review.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _ReviewBanner(
                  count: review.length,
                  calls: reviewCalls.length,
                  onTap: () {
                    final callId = reviewCalls.first;
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostCallReviewScreen(callId: callId)));
                  },
                ),
              ),
            if (calls.isEmpty)
              EmptyState(
                icon: Icons.call_rounded,
                title: app.corporate ? 'No work calls yet' : 'No calls yet',
                body: app.corporate
                    ? 'Call a client from the keypad or Clients tab. Commit AI will catch every commitment.'
                    : 'Personal calls are private: commitments you make are tracked for you alone, never shared with your company.',
              )
            else ...[
              const SectionLabel('Recent'),
              for (final c in calls)
                CallTile(
                  call: c,
                  onTap: c.mode == AppMode.corporate && !c.missed
                      ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallDetailScreen(callId: c.id)))
                      : null,
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
            ],
          ]),
        );
      },
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner({required this.count, required this.calls, required this.onTap});
  final int count;
  final int calls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).palette;
    return Material(
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
            gradient: LinearGradient(colors: p.gradient, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: p.onAccent.withValues(alpha: .12), shape: BoxShape.circle),
                child: Icon(Icons.auto_awesome_rounded, color: p.onAccent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$count commitment${count == 1 ? '' : 's'} to approve',
                      style: AppType.display(19, weight: FontWeight.w600, color: p.onAccent)),
                  const SizedBox(height: 3),
                  Text(AppScope.of(context).corporate
                          ? 'From $calls call${calls == 1 ? '' : 's'} · tap to approve and send to your manager'
                          : 'From $calls call${calls == 1 ? '' : 's'} · tap to approve',
                      style: TextStyle(color: p.onAccent.withValues(alpha: .75), fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
              ),
              Icon(Icons.arrow_forward_rounded, color: p.onAccent),
            ]),
          ),
        ),
      ),
    );
  }
}
