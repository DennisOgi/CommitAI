import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../call/call_detail_screen.dart';

class CommitmentDetailScreen extends StatefulWidget {
  const CommitmentDetailScreen({super.key, required this.commitment});
  final Commitment commitment;

  @override
  State<CommitmentDetailScreen> createState() => _CommitmentDetailScreenState();
}

class _CommitmentDetailScreenState extends State<CommitmentDetailScreen> {
  late Commitment c = widget.commitment;
  List<CommitmentEvent> _events = [];
  final _comment = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final e = await AppScope.read(context).backend!.events(c.id);
    if (mounted) setState(() => _events = e);
  }

  Future<void> _set(CommitmentStatus s, {String? note}) async {
    setState(() => _busy = true);
    final app = AppScope.read(context);
    try {
      final updated = await app.backend!.updateCommitment(c.id, status: s, note: note);
      if (!mounted) return;
      setState(() => c = updated);
      app.refresh();
      await _loadEvents();
      if (mounted && s == CommitmentStatus.fulfilled) toast(context, 'Marked as kept. Nice work.', icon: Icons.check_circle_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reschedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: (c.dueAt ?? now).isBefore(now) ? now : c.dueAt!,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'New deadline (agree it with the client)',
    );
    if (date == null || !mounted) return;
    final app = AppScope.read(context);
    final updated = await app.backend!.updateCommitment(c.id,
        dueAt: DateTime(date.year, date.month, date.day, 17), status: c.status == CommitmentStatus.missed ? CommitmentStatus.open : null);
    if (!mounted) return;
    setState(() => c = updated);
    app.refresh();
    _loadEvents();
  }

  Future<void> _nudge() async {
    await AppScope.read(context).backend!.nudge(c.id);
    if (!mounted) return;
    toast(context, 'Nudged ${c.employeeName?.split(' ').first ?? 'them'} with the exact commitment.', icon: Icons.notifications_active_rounded);
    _loadEvents();
  }

  Future<void> _sendComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    _comment.clear();
    await AppScope.read(context).backend!.comment(c.id, text);
    _loadEvents();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = statusStyle(c);
    final t = Theme.of(context).textTheme;
    final mine = c.membershipId == app.session?.membership?.id;
    final managing = app.isManager && !mine;
    return Scaffold(
      appBar: AppBar(title: Text(categoryLabel(c.category))),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        Wrap(spacing: 8, children: [
          Pill(s.label, color: s.color, icon: s.icon),
          if (c.priority == 'high') const Pill('High priority', color: Color(0xFFFB7185)),
          if (c.byClient) const Pill('Client’s commitment', color: AppColors.info),
        ]),
        const SizedBox(height: 14),
        Text(c.title, style: t.headlineSmall),
        const SizedBox(height: 8),
        Text([if (c.employeeName != null && !mine) c.employeeName!, if (c.clientName != null) 'for ${c.clientName}'].join(' '),
            style: t.bodyLarge?.copyWith(color: AppColors.textDim)),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _Fact(icon: Icons.schedule_rounded, label: 'Deadline', value: c.dueAt == null ? 'None set' : '${shortDate(c.dueAt!)}, ${clock(c.dueAt!)}', sub: dueLabel(c.dueAt))),
          const SizedBox(width: 10),
          Expanded(child: _Fact(icon: Icons.auto_awesome_rounded, label: 'AI confidence', value: '${(c.confidence * 100).round()}%', sub: c.dueText != null ? 'Said: “${c.dueText}”' : null)),
        ]),
        if (c.quote != null && c.quote != 'Historical commitment.') ...[
          const SizedBox(height: 14),
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: c.callId == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallDetailScreen(callId: c.callId!))),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.format_quote_rounded, color: app.palette.accent),
                  const SizedBox(height: 4),
                  Text(c.quote!, style: const TextStyle(fontSize: 16, color: AppColors.text, fontStyle: FontStyle.italic, height: 1.45)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(
                      'Said ${c.quoteOffsetMs != null ? 'at ${two(c.quoteOffsetMs! ~/ 60000)}:${two((c.quoteOffsetMs! ~/ 1000) % 60)} ' : ''}on the call',
                      style: t.bodySmall,
                    ),
                    const Spacer(),
                    if (c.callId != null) Text('Open call ›', style: TextStyle(color: app.palette.accent, fontWeight: FontWeight.w600, fontSize: 13)),
                  ]),
                ]),
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (c.isLive || c.status == CommitmentStatus.missed || c.status == CommitmentStatus.pendingReview) ...[
          if (mine && !c.byClient) ...[
            FilledButton.icon(
              onPressed: _busy ? null : () => _set(CommitmentStatus.fulfilled),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Mark as kept'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              if (c.status != CommitmentStatus.inProgress)
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _set(CommitmentStatus.inProgress), child: const Text('Working on it'))),
              if (c.status != CommitmentStatus.inProgress) const SizedBox(width: 10),
              Expanded(child: OutlinedButton(onPressed: _busy ? null : _reschedule, child: const Text('Reschedule'))),
            ]),
          ],
          if (c.byClient && mine)
            FilledButton.icon(onPressed: _busy ? null : () => _set(CommitmentStatus.fulfilled), icon: const Icon(Icons.inbox_rounded), label: const Text('Client delivered')),
          if (managing) ...[
            FilledButton.icon(onPressed: _nudge, icon: const Icon(Icons.notifications_active_rounded), label: Text('Nudge ${c.employeeName?.split(' ').first ?? ''}')),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _busy ? null : () => _set(CommitmentStatus.disputed, note: 'Flagged by manager'),
              child: const Text('Flag for discussion'),
            ),
          ],
        ],
        const SectionLabel('Activity', padding: EdgeInsets.fromLTRB(0, 26, 0, 10)),
        for (final e in _events.reversed) _EventRow(e: e),
        const SizedBox(height: 10),
        TextField(
          controller: _comment,
          onSubmitted: (_) => _sendComment(),
          decoration: InputDecoration(
            hintText: managing ? 'Ask for an update…' : 'Add a note for your manager…',
            suffixIcon: IconButton(icon: Icon(Icons.send_rounded, color: app.palette.accent), onPressed: _sendComment),
          ),
        ),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value, this.sub});
  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 15, color: AppColors.textFaint),
              const SizedBox(width: 6),
              Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
            ]),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text, fontSize: 15)),
            if (sub != null) Text(sub!, style: const TextStyle(fontSize: 12, color: AppColors.textDim), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      );
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.e});
  final CommitmentEvent e;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text) = switch (e.kind) {
      'created' => (Icons.auto_awesome_rounded, e.payload['manual'] == true ? '${e.actorName} added this' : 'Detected by Commit Call on the call'),
      'confirmed' => (Icons.verified_rounded, e.payload['auto'] == true ? 'Auto-shared (not reviewed within 24h)' : '${e.actorName} confirmed it'),
      'status_changed' => (Icons.swap_horiz_rounded, '${e.actorName} moved it to ${(e.payload['to'] ?? '').toString().replaceAll('_', ' ')}'),
      'due_changed' => (Icons.event_repeat_rounded, '${e.actorName} changed the deadline'),
      'comment' => (Icons.chat_bubble_rounded, '${e.actorName}: ${e.payload['text']}'),
      'nudge' => (Icons.notifications_active_rounded, '${e.actorName} sent a nudge'),
      'reminder' => (Icons.alarm_rounded, 'Reminder sent'),
      'escalated' => (Icons.priority_high_rounded, 'Deadline passed: manager alerted'),
      _ => (Icons.circle, e.kind),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 17, color: AppColors.textDim),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(color: AppColors.text, fontSize: 14))),
        Text(whenLabel(e.at), style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
      ]),
    );
  }
}
