import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Right after a work call: Commit AI shows what it heard you promise.
/// You confirm, edit or drop each one; anything you skip is auto-shared in 24h.
class PostCallReviewScreen extends StatefulWidget {
  const PostCallReviewScreen({super.key, required this.callId, this.flagged = const []});
  final String callId;
  final List<String> flagged;

  @override
  State<PostCallReviewScreen> createState() => _PostCallReviewScreenState();
}

class _Draft {
  _Draft(this.c) : keep = c.confidence >= 0.7, title = c.title, due = c.dueAt;
  final Commitment c;
  bool keep;
  String title;
  DateTime? due;
  bool get edited => title != c.title || due != c.dueAt;
}

class _PostCallReviewScreenState extends State<PostCallReviewScreen> {
  CallDetail? _detail;
  List<_Draft> _drafts = [];
  final List<Map<String, dynamic>> _added = [];
  Timer? _poll;
  int _tries = 0;
  int _step = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (_step < 2) setState(() => _step++);
      _load();
    });
  }

  Future<void> _load() async {
    final backend = AppScope.read(context).backend!;
    try {
      final d = await backend.callDetail(widget.callId);
      final ready = d.call.processing == 'done' || d.call.processing == 'failed' || ++_tries > 40;
      if (!mounted) return;
      if (ready) {
        _poll?.cancel();
        setState(() {
          _detail = d;
          _drafts = [for (final c in d.commitments.where((c) => c.status == CommitmentStatus.pendingReview)) _Draft(c)];
        });
      }
    } catch (_) {
      // keep polling
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final app = AppScope.read(context);
    final accept = [for (final d in _drafts) if (d.keep) d.c.id];
    final reject = [for (final d in _drafts) if (!d.keep) d.c.id];
    final edits = {
      for (final d in _drafts)
        if (d.keep && d.edited) d.c.id: {'title': d.title, if (d.due != null) 'due_at': d.due!.toUtc().toIso8601String()}
    };
    try {
      await app.backend!.submitReview(widget.callId, accept: accept, reject: reject, edits: edits, add: _added);
      if (!mounted) return;
      app.refresh();
      Navigator.of(context).pop();
      toast(context, '${accept.length + _added.length} commitment${accept.length + _added.length == 1 ? '' : 's'} logged and shared with your manager',
          icon: Icons.check_circle_rounded);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, '$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _edit(_Draft d) async {
    final ctrl = TextEditingController(text: d.title);
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Edit commitment', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(controller: ctrl, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'What you committed to')),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => Navigator.pop(sheet, ctrl.text.trim()), child: const Text('Save')),
        ]),
      ),
    );
    if (result != null && result.isNotEmpty) setState(() => d.title = result);
  }

  Future<void> _pickDue(_Draft d) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: d.due ?? now.add(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(d.due ?? DateTime(now.year, now.month, now.day, 17)));
    setState(() => d.due = DateTime(date.year, date.month, date.day, time?.hour ?? 17, time?.minute ?? 0));
  }

  Future<void> _addMissed() async {
    final ctrl = TextEditingController();
    final title = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add a commitment', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('A commitment Commit AI missed.', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 14),
          TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Send the driver’s contact for the Kano route')),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => Navigator.pop(sheet, ctrl.text.trim()), child: const Text('Add')),
        ]),
      ),
    );
    if (title != null && title.isNotEmpty) setState(() => _added.add({'title': title, 'category': 'other'}));
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).palette;
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('Call review')),
      body: d == null ? _Thinking(step: _step, accent: p.accent) : _body(d, p),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary))
                      : const Icon(Icons.done_all_rounded),
                  label: Text(_drafts.isEmpty && _added.isEmpty ? 'Done' : 'Confirm & share with manager'),
                ),
              ),
            ),
    );
  }

  Widget _body(CallDetail d, ModePalette p) {
    final mine = _drafts.where((x) => !x.c.byClient).toList();
    final theirs = _drafts.where((x) => x.c.byClient).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Avatar(name: d.call.counterpartName, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.call.counterpartName, style: Theme.of(context).textTheme.titleMedium),
                  Text([whenLabel(d.call.startedAt), if (d.call.length != null) duration(d.call.length!)].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              if (d.call.sentiment != null) _SentimentPill(d.call.sentiment!),
            ]),
            if (d.call.summary != null) ...[
              const SizedBox(height: 12),
              Text(d.call.summary!, style: const TextStyle(color: AppColors.text, height: 1.45)),
            ],
          ]),
        ),
      ),
      SectionLabel('You committed to', padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
          trailing: Text('${mine.where((x) => x.keep).length}/${mine.length} kept', style: Theme.of(context).textTheme.bodySmall)),
      if (mine.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text('No commitments detected on this call.', style: TextStyle(color: AppColors.textDim)),
        ),
      for (final x in mine) _DraftCard(draft: x, accent: p.accent, onToggle: () => setState(() => x.keep = !x.keep), onEdit: () => _edit(x), onDue: () => _pickDue(x)),
      for (final a in _added)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              leading: Icon(Icons.add_task_rounded, color: p.accent),
              title: Text(a['title'] as String),
              subtitle: const Text('Added by you'),
              trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _added.remove(a))),
            ),
          ),
        ),
      if (widget.flagged.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(Icons.flag_rounded, color: p.accent, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('You flagged ${widget.flagged.join(', ')}. Make sure it’s listed above.', style: const TextStyle(fontSize: 13))),
          ]),
        ),
      OutlinedButton.icon(onPressed: _addMissed, icon: const Icon(Icons.add_rounded), label: const Text('Add one Commit AI missed')),
      if (theirs.isNotEmpty) ...[
        const SectionLabel('The client committed to', padding: EdgeInsets.fromLTRB(4, 26, 4, 10)),
        for (final x in theirs) _DraftCard(draft: x, accent: AppColors.info, onToggle: () => setState(() => x.keep = !x.keep), onEdit: () => _edit(x), onDue: () => _pickDue(x)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('Tracked so you know what you’re waiting on. These don’t count against you.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
        ),
      ],
    ]);
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.draft, required this.accent, required this.onToggle, required this.onEdit, required this.onDue});
  final _Draft draft;
  final Color accent;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDue;

  @override
  Widget build(BuildContext context) {
    final c = draft.c;
    final low = c.confidence < 0.7;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: draft.keep ? 1 : .5,
        child: Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: draft.keep ? accent.withValues(alpha: .55) : AppColors.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(categoryIcon(c.category), color: accent, size: 20)),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: onEdit,
                    child: Text(draft.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.text)),
                  ),
                ),
                Switch(value: draft.keep, onChanged: (_) => onToggle()),
              ]),
              if (c.quote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 6, 12, 0),
                  child: Text('“${c.quote}”', style: const TextStyle(fontSize: 13, color: AppColors.textDim, fontStyle: FontStyle.italic, height: 1.4)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 8, 0, 0),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  ActionChip(
                    avatar: const Icon(Icons.schedule_rounded, size: 16),
                    label: Text(draft.due == null ? 'Set deadline' : dueLabel(draft.due)),
                    onPressed: onDue,
                  ),
                  ActionChip(avatar: const Icon(Icons.edit_rounded, size: 16), label: const Text('Edit'), onPressed: onEdit),
                  if (low) const Pill('Low confidence · check this', color: AppColors.warning, icon: Icons.help_outline_rounded),
                  if (c.priority == 'high') const Pill('High', color: Color(0xFFFB7185)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SentimentPill extends StatelessWidget {
  const _SentimentPill(this.sentiment);
  final String sentiment;

  @override
  Widget build(BuildContext context) {
    final (Color c, IconData i) = switch (sentiment) {
      'positive' => (AppColors.success, Icons.sentiment_satisfied_alt_rounded),
      'negative' => (AppColors.danger, Icons.sentiment_dissatisfied_rounded),
      'mixed' => (AppColors.warning, Icons.sentiment_neutral_rounded),
      _ => (AppColors.textDim, Icons.sentiment_neutral_rounded),
    };
    return Pill(sentiment[0].toUpperCase() + sentiment.substring(1), color: c, icon: i, dense: true);
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.step, required this.accent});
  final int step;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    const steps = ['Transcribing both sides', 'Finding the commitments', 'Working out the deadlines'];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 3, color: accent)),
          const SizedBox(height: 24),
          Text('Commit AI is reviewing your call', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 18),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(i < step ? Icons.check_circle_rounded : i == step ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 18, color: i <= step ? accent : AppColors.textFaint),
                const SizedBox(width: 10),
                Text(steps[i], style: TextStyle(color: i <= step ? AppColors.text : AppColors.textFaint)),
              ]),
            ),
        ]),
      ),
    );
  }
}
