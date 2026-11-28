import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import 'commitment_detail_screen.dart';

/// "Commitments": everything you (or, for a manager drilling in, a team member) committed to.
class CommitmentsScreen extends StatefulWidget {
  const CommitmentsScreen({super.key, this.memberId, this.memberName});
  final String? memberId;
  final String? memberName;

  @override
  State<CommitmentsScreen> createState() => _CommitmentsScreenState();
}

class _CommitmentsScreenState extends State<CommitmentsScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final forMember = widget.memberId != null;
    final body = Loader<List<Commitment>>(
      load: (b) => b.commitments(team: forMember, memberId: widget.memberId),
      builder: (context, all, reload) {
        final now = DateTime.now();
        final endOfToday = DateTime(now.year, now.month, now.day, 23, 59);
        final mine = all.where((c) => !c.byClient).toList();
        final closed = mine.where((c) => c.status == CommitmentStatus.fulfilled || c.status == CommitmentStatus.missed).toList();
        final onTime = closed.where((c) => c.status == CommitmentStatus.fulfilled && (c.dueAt == null || c.completedAt == null || !c.completedAt!.isAfter(c.dueAt!))).length;
        final reliability = closed.isEmpty ? null : (100 * onTime / closed.length).round();

        final groups = <(String, List<Commitment>)>[];
        if (_done) {
          groups.add(('Kept', mine.where((c) => c.status == CommitmentStatus.fulfilled).toList()));
          groups.add(('Missed', mine.where((c) => c.status == CommitmentStatus.missed).toList()));
          groups.add(('Cancelled', mine.where((c) => c.status == CommitmentStatus.cancelled).toList()));
        } else {
          final live = mine.where((c) => c.isLive && !c.isOverdue).toList();
          groups.add(('Needs your review', mine.where((c) => c.status == CommitmentStatus.pendingReview).toList()));
          groups.add(('Overdue', mine.where((c) => c.isLive && c.isOverdue).toList()));
          groups.add(('Due today', live.where((c) => c.dueAt != null && c.dueAt!.isBefore(endOfToday)).toList()));
          groups.add(('This week', live.where((c) => c.dueAt != null && !c.dueAt!.isBefore(endOfToday) && c.dueAt!.isBefore(now.add(const Duration(days: 7)))).toList()));
          groups.add(('Later or no deadline', live.where((c) => c.dueAt == null || !c.dueAt!.isBefore(now.add(const Duration(days: 7)))).toList()));
          groups.add(('Waiting on the client', all.where((c) => c.byClient && c.isLive).toList()));
        }
        final openCount = mine.where((c) => c.isLive || c.status == CommitmentStatus.pendingReview).length;

        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
            if (!forMember)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                child: Text('Commitments', style: AppType.display(28, weight: FontWeight.w600)),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  ScoreRing(value: reliability, size: 58, stroke: 6),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(reliability == null ? 'Building your track record' : '$reliability% kept on time',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text('$openCount open · ${closed.length} closed recently', style: Theme.of(context).textTheme.bodyMedium),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Active'), icon: Icon(Icons.pending_actions_rounded)),
                ButtonSegment(value: true, label: Text('History'), icon: Icon(Icons.history_rounded)),
              ],
              selected: {_done},
              onSelectionChanged: (s) => setState(() => _done = s.first),
              showSelectedIcon: false,
            ),
            for (final (label, items) in groups)
              if (items.isNotEmpty) ...[
                SectionLabel('$label · ${items.length}', padding: const EdgeInsets.fromLTRB(4, 22, 4, 10)),
                for (final c in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CommitmentTile(
                      c: c,
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c)));
                        reload();
                      },
                    ),
                  ),
              ],
            if (groups.every((g) => g.$2.isEmpty))
              const EmptyState(
                icon: Icons.handshake_rounded,
                title: 'Nothing here',
                body: 'Commitments from your work calls land here automatically.',
              ),
          ]),
        );
      },
    );
    if (!forMember) return body;
    return Scaffold(appBar: AppBar(title: Text(widget.memberName ?? 'Commitments')), body: body);
  }
}
