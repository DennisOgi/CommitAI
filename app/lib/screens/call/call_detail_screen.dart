import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../commitments/commitment_detail_screen.dart';

/// A recorded work call: summary, commitments, and the transcript with every
/// promise highlighted where it was said.
class CallDetailScreen extends StatelessWidget {
  const CallDetailScreen({super.key, required this.callId});
  final String callId;

  @override
  Widget build(BuildContext context) {
    final accent = AppScope.of(context).palette.accent;
    return Scaffold(
      appBar: AppBar(title: const Text('Call')),
      body: Loader<CallDetail>(
        load: (b) => b.callDetail(callId),
        builder: (context, d, reload) {
          final quotes = {for (final c in d.commitments) if (c.quote != null) c.quote!.toLowerCase(): c};
          Commitment? promiseIn(String line) {
            final l = line.toLowerCase();
            for (final e in quotes.entries) {
              if (l.contains(e.key) || e.key.contains(l)) return e.value;
            }
            return null;
          }

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Row(children: [
              Avatar(name: d.call.counterpartName, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.call.counterpartName, style: Theme.of(context).textTheme.titleLarge),
                  Text(
                    [shortDate(d.call.startedAt), clock(d.call.startedAt), if (d.call.length != null) duration(d.call.length!)].join(' · '),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ]),
              ),
            ]),
            if (d.call.summary != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.auto_awesome_rounded, color: accent, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(d.call.summary!, style: const TextStyle(color: AppColors.text, height: 1.45))),
                  ]),
                ),
              ),
            ],
            SectionLabel('Commitments (${d.commitments.length})', padding: const EdgeInsets.fromLTRB(4, 22, 4, 10)),
            for (final c in d.commitments)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: CommitmentTile(
                  c: c,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c))),
                ),
              ),
            if (d.transcript.isNotEmpty) ...[
              const SectionLabel('Transcript', padding: EdgeInsets.fromLTRB(4, 18, 4, 10)),
              for (final line in d.transcript) _Line(line: line, promise: promiseIn(line.text), accent: accent, peer: d.call.counterpartName),
            ],
          ]);
        },
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.promise, required this.accent, required this.peer});
  final TranscriptLine line;
  final Commitment? promise;
  final Color accent;
  final String peer;

  @override
  Widget build(BuildContext context) {
    final me = line.speaker == 'employee';
    final ts = '${two(line.offsetMs ~/ 60000)}:${two((line.offsetMs ~/ 1000) % 60)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: promise != null ? accent.withValues(alpha: .1) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: promise != null ? accent : Colors.transparent, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(me ? 'You' : peer.split(' ').first,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: me ? accent : AppColors.info)),
          const SizedBox(width: 8),
          Text(ts, style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
          const Spacer(),
          if (promise != null) Pill(promise!.byClient ? 'Client commitment' : 'Commitment', color: accent, icon: Icons.handshake_rounded, dense: true),
        ]),
        const SizedBox(height: 4),
        Text(line.text, style: const TextStyle(color: AppColors.text, height: 1.4)),
      ]),
    );
  }
}
