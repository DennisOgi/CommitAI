import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../commitments/commitment_detail_screen.dart';

/// The manager's view of every commitment their staff made on calls.
///
/// Person-first so it never overwhelms: one card per staff member with what matters
/// (open, overdue, how reliably they keep their word); tap a person to see their list.
/// "All" is the searchable register across the team, with a handful of filters.
class TeamCommitmentsView extends StatefulWidget {
  const TeamCommitmentsView({super.key, this.initialFilter = 'open'});

  /// One of: open, overdue, week, review, client, kept, missed, all. Anything other than
  /// "open" (e.g. tapping "Overdue" on the dashboard) opens the All list on that filter.
  final String initialFilter;

  @override
  State<TeamCommitmentsView> createState() => _TeamCommitmentsViewState();
}

enum _Filter {
  open('Open'),
  overdue('Overdue'),
  week('This week'),
  review('To review'),
  kept('Kept'),
  missed('Missed'),
  client('Owed to us'),
  all('All');

  const _Filter(this.label);
  final String label;
}

bool _matches(Commitment c, _Filter f, DateTime now) => switch (f) {
      _Filter.open => !c.byClient && (c.isLive || c.status == CommitmentStatus.pendingReview),
      _Filter.overdue => !c.byClient && c.isOverdue,
      _Filter.week => !c.byClient && c.isLive && c.dueAt != null && !c.isOverdue && c.dueAt!.isBefore(now.add(const Duration(days: 7))),
      _Filter.review => c.status == CommitmentStatus.pendingReview,
      _Filter.kept => c.status == CommitmentStatus.fulfilled,
      _Filter.missed => c.status == CommitmentStatus.missed,
      _Filter.client => c.byClient && c.isLive,
      _Filter.all => true,
    };

int _byDue(Commitment a, Commitment b) => (a.dueAt ?? DateTime(9999)).compareTo(b.dueAt ?? DateTime(9999));

class _Person {
  _Person(this.id, this.name);
  final String id;
  final String name;
  final List<Commitment> items = [];

  Iterable<Commitment> get own => items.where((c) => !c.byClient);
  int get open => own.where((c) => c.isLive || c.status == CommitmentStatus.pendingReview).length;
  int get overdue => own.where((c) => c.isOverdue).length;
  int get kept => own.where((c) => c.status == CommitmentStatus.fulfilled).length;
  int get missed => own.where((c) => c.status == CommitmentStatus.missed).length;

  /// Share of finished commitments that were kept; null until something finished.
  double? get reliability => kept + missed == 0 ? null : kept / (kept + missed);
}

class _TeamCommitmentsViewState extends State<TeamCommitmentsView> {
  final _search = TextEditingController();
  late bool _people = widget.initialFilter == 'open';
  late _Filter _filter = _Filter.values.firstWhere((f) => f.name == widget.initialFilter, orElse: () => _Filter.open);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Loader<List<Commitment>>(
      load: (b) => b.commitments(team: true),
      builder: (context, all, reload) {
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('By person'), icon: Icon(Icons.groups_rounded, size: 18)),
                ButtonSegment(value: false, label: Text('All commitments'), icon: Icon(Icons.list_rounded, size: 18)),
              ],
              selected: {_people},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _people = s.first),
            ),
            const SizedBox(height: 14),
            if (_people) ..._peopleList(context, all, reload) else ..._register(context, all, reload),
          ]),
        );
      },
    );
  }

  // ---------------------------------------------------------------- by person --
  List<Widget> _peopleList(BuildContext context, List<Commitment> all, Future<void> Function() reload) {
    final people = <String, _Person>{};
    for (final c in all) {
      final id = c.membershipId ?? c.employeeName ?? '?';
      people.putIfAbsent(id, () => _Person(id, c.employeeName ?? 'Unknown')).items.add(c);
    }
    final list = people.values.toList()
      ..sort((a, b) => b.overdue != a.overdue ? b.overdue.compareTo(a.overdue) : a.name.compareTo(b.name));
    if (list.isEmpty) {
      return const [
        EmptyState(
          icon: Icons.groups_rounded,
          title: 'No commitments yet',
          body: 'When your team makes commitments on calls and approves them, they appear here, person by person.',
        ),
      ];
    }
    final overdue = list.fold<int>(0, (n, p) => n + p.overdue);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Text(
          overdue == 0
              ? '${list.length} ${list.length == 1 ? 'person' : 'people'} · nothing overdue'
              : '${list.length} ${list.length == 1 ? 'person' : 'people'} · $overdue overdue, needing attention first',
          style: const TextStyle(color: AppColors.textDim, fontSize: 13),
        ),
      ),
      for (final p in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _PersonCard(
            person: p,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PersonScreen(person: p)));
              reload();
            },
          ),
        ),
    ];
  }

  // --------------------------------------------------------------- register --
  List<Widget> _register(BuildContext context, List<Commitment> all, Future<void> Function() reload) {
    final accent = AppScope.of(context).palette.accent;
    final now = DateTime.now();
    final q = _search.text.trim().toLowerCase();
    final scoped = all.where(
        (c) => q.isEmpty || [c.title, c.clientName, c.employeeName, c.quote, c.detail].any((s) => s != null && s.toLowerCase().contains(q)));
    final shown = scoped.where((c) => _matches(c, _filter, now)).toList()..sort(_byDue);
    const chips = [_Filter.open, _Filter.overdue, _Filter.week, _Filter.review, _Filter.kept];
    return [
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search by person, client or commitment',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: () => setState(_search.clear)),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final f in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('${f.label} ${scoped.where((c) => _matches(c, f, now)).length}'),
                selected: _filter == f,
                showCheckmark: false,
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _filter == f
                      ? Theme.of(context).colorScheme.onPrimary
                      : f == _Filter.overdue && scoped.any((c) => _matches(c, f, now))
                          ? AppColors.danger
                          : AppColors.text,
                ),
                selectedColor: accent,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
          PopupMenuButton<_Filter>(
            tooltip: 'More filters',
            color: AppColors.surfaceHigh,
            onSelected: (f) => setState(() => _filter = f),
            itemBuilder: (_) => [
              for (final f in const [_Filter.missed, _Filter.client, _Filter.all])
                PopupMenuItem(value: f, child: Text('${f.label} (${scoped.where((c) => _matches(c, f, now)).length})')),
            ],
            child: Chip(
              label: Text(chips.contains(_filter) ? 'More' : _filter.label,
                  style: TextStyle(fontWeight: FontWeight.w700, color: chips.contains(_filter) ? AppColors.text : accent)),
              avatar: Icon(Icons.tune_rounded, size: 16, color: chips.contains(_filter) ? AppColors.textDim : accent),
            ),
          ),
        ]),
      ),
      if (shown.isEmpty)
        EmptyState(
          icon: _filter == _Filter.overdue ? Icons.verified_rounded : Icons.search_off_rounded,
          title: _filter == _Filter.overdue ? 'Nothing overdue' : 'Nothing here',
          body: _filter == _Filter.overdue ? 'Every live commitment is on schedule.' : 'Try another filter or search term.',
        )
      else
        SectionLabel('${shown.length} ${_filter.label.toLowerCase()}', padding: const EdgeInsets.fromLTRB(4, 16, 4, 10)),
      for (final c in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ManagedTile(c: c, showEmployee: true, onChanged: reload),
        ),
    ];
  }
}

/// One staff member at a glance.
class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person, required this.onTap});
  final _Person person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final rel = p.reliability;
    final relColor = rel == null
        ? AppColors.textFaint
        : rel >= .85
            ? AppColors.success
            : rel >= .6
                ? AppColors.warning
                : AppColors.danger;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(children: [
            Avatar(name: p.name, size: 46),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _Stat('${p.open} open', AppColors.textDim),
                  if (p.overdue > 0) _Stat('${p.overdue} overdue', AppColors.danger),
                  if (p.kept > 0) _Stat('${p.kept} kept', AppColors.success),
                ]),
              ]),
            ),
            SizedBox(
              width: 54,
              child: Column(children: [
                Text(rel == null ? '–' : '${(rel * 100).round()}%',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: relColor)),
                const Text('kept', style: TextStyle(fontSize: 11, color: AppColors.textFaint)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
          ]),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      );
}

/// One person's commitments: Open / Overdue / Done, nothing else.
class _PersonScreen extends StatefulWidget {
  const _PersonScreen({required this.person});
  final _Person person;

  @override
  State<_PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<_PersonScreen> {
  late _Filter _filter = widget.person.overdue > 0 ? _Filter.overdue : _Filter.open;

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final now = DateTime.now();
    final tabs = [_Filter.open, _Filter.overdue, _Filter.kept, _Filter.client];
    String label(_Filter f) => f == _Filter.kept ? 'Done' : f.label;
    final shown = p.items.where((c) => f2(c, _filter, now)).toList()..sort(_byDue);
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(children: [
              _Big('${p.open}', 'Open', AppColors.text),
              _Big('${p.overdue}', 'Overdue', p.overdue > 0 ? AppColors.danger : AppColors.text),
              _Big('${p.kept}', 'Kept', AppColors.success),
              _Big(p.reliability == null ? '–' : '${(p.reliability! * 100).round()}%', 'Reliability', AppColors.text),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final f in tabs)
            ChoiceChip(
              label: Text('${label(f)} ${p.items.where((c) => f2(c, f, now)).length}'),
              selected: _filter == f,
              showCheckmark: false,
              labelStyle: TextStyle(fontWeight: FontWeight.w700, color: _filter == f ? Theme.of(context).colorScheme.onPrimary : AppColors.text),
              selectedColor: AppScope.of(context).palette.accent,
              onSelected: (_) => setState(() => _filter = f),
            ),
        ]),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          EmptyState(
            icon: Icons.inbox_rounded,
            title: _filter == _Filter.overdue ? 'Nothing overdue' : 'Nothing here',
            body: _filter == _Filter.overdue ? '${p.name.split(' ').first} is on schedule.' : 'No ${label(_filter).toLowerCase()} commitments.',
          ),
        for (final c in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ManagedTile(c: c, showEmployee: false, onChanged: () async => setState(() {})),
          ),
      ]),
    );
  }

  // "Done" here means kept or missed: everything finished.
  bool f2(Commitment c, _Filter f, DateTime now) => f == _Filter.kept
      ? !c.byClient && (c.status == CommitmentStatus.fulfilled || c.status == CommitmentStatus.missed)
      : _matches(c, f, now);
}

class _Big extends StatelessWidget {
  const _Big(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value, style: AppType.display(24, weight: FontWeight.w600, color: color)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        ]),
      );
}

/// A commitment row with the manager's one action: nudge.
class _ManagedTile extends StatelessWidget {
  const _ManagedTile({required this.c, required this.showEmployee, required this.onChanged});
  final Commitment c;
  final bool showEmployee;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return CommitmentTile(
      c: c,
      showEmployee: showEmployee,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c)));
        await onChanged();
      },
      trailing: !c.byClient && (c.isLive || c.isOverdue)
          ? IconButton(
              tooltip: 'Nudge ${c.employeeName?.split(' ').first ?? ''}',
              icon: Icon(Icons.notifications_active_rounded, color: app.palette.accent),
              onPressed: () async {
                try {
                  await app.backend!.nudge(c.id);
                  if (context.mounted) {
                    toast(context, 'Nudged ${c.employeeName?.split(' ').first ?? 'them'}', icon: Icons.notifications_active_rounded);
                  }
                } catch (e) {
                  if (context.mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
                }
              },
            )
          : null,
    );
  }
}
