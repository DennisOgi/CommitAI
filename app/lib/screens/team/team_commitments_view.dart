import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../commitments/commitment_detail_screen.dart';

/// The manager's register of every commitment their staff made on calls:
/// search, filter by state / person / type, sort, and act (open, nudge) from one list.
class TeamCommitmentsView extends StatefulWidget {
  const TeamCommitmentsView({super.key, this.initialFilter = 'open'});

  /// One of: open, overdue, week, review, client, kept, missed, all.
  final String initialFilter;

  @override
  State<TeamCommitmentsView> createState() => _TeamCommitmentsViewState();
}

enum _Filter {
  open('Open'),
  overdue('Overdue'),
  week('Due in 7 days'),
  review('Awaiting review'),
  client('Client owes us'),
  kept('Kept'),
  missed('Missed'),
  all('All');

  const _Filter(this.label);
  final String label;
}

enum _Sort {
  due('Due date'),
  newest('Newest first'),
  person('Person'),
  client('Client');

  const _Sort(this.label);
  final String label;
}

class _TeamCommitmentsViewState extends State<TeamCommitmentsView> {
  final _search = TextEditingController();
  _Filter _filter = _Filter.open;
  _Sort _sort = _Sort.due;
  String? _person; // membership id
  String? _category;
  bool _groupByPerson = false;

  @override
  void initState() {
    super.initState();
    _filter = _Filter.values.firstWhere((f) => f.name == widget.initialFilter, orElse: () => _Filter.open);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Commitment c, _Filter f, DateTime now) => switch (f) {
        _Filter.open => !c.byClient && (c.isLive || c.status == CommitmentStatus.pendingReview),
        _Filter.overdue => !c.byClient && c.isOverdue,
        _Filter.week => !c.byClient && c.isLive && c.dueAt != null && !c.isOverdue && c.dueAt!.isBefore(now.add(const Duration(days: 7))),
        _Filter.review => c.status == CommitmentStatus.pendingReview,
        _Filter.client => c.byClient && c.isLive,
        _Filter.kept => c.status == CommitmentStatus.fulfilled,
        _Filter.missed => c.status == CommitmentStatus.missed,
        _Filter.all => true,
      };

  int _compare(Commitment a, Commitment b) {
    final far = DateTime(9999);
    return switch (_sort) {
      _Sort.due => (a.dueAt ?? far).compareTo(b.dueAt ?? far),
      _Sort.newest => b.createdAt.compareTo(a.createdAt),
      _Sort.person => (a.employeeName ?? '').compareTo(b.employeeName ?? ''),
      _Sort.client => (a.clientName ?? '~').compareTo(b.clientName ?? '~'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final accent = app.palette.accent;
    return Loader<List<Commitment>>(
      load: (b) => b.commitments(team: true),
      builder: (context, all, reload) {
        final now = DateTime.now();
        final people = <String, String>{
          for (final c in all)
            if (c.membershipId != null) c.membershipId!: c.employeeName ?? 'Unknown',
        };
        final q = _search.text.trim().toLowerCase();
        final scoped = all.where((c) =>
            (_person == null || c.membershipId == _person) &&
            (_category == null || c.category == _category) &&
            (q.isEmpty || [c.title, c.clientName, c.employeeName, c.quote, c.detail].any((s) => s != null && s.toLowerCase().contains(q))));
        final counts = {for (final f in _Filter.values) f: scoped.where((c) => _matches(c, f, now)).length};
        final shown = scoped.where((c) => _matches(c, _filter, now)).toList()..sort(_compare);

        final sections = <(String, List<Commitment>)>[];
        if (_groupByPerson) {
          final byPerson = <String, List<Commitment>>{};
          for (final c in shown) {
            byPerson.putIfAbsent(c.employeeName ?? 'Unknown', () => []).add(c);
          }
          final names = byPerson.keys.toList()
            ..sort((a, b) => byPerson[b]!.where((c) => c.isOverdue).length.compareTo(byPerson[a]!.where((c) => c.isOverdue).length));
          sections.addAll([for (final n in names) (n, byPerson[n]!)]);
        } else {
          sections.add(('', shown));
        }

        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search commitments, clients, people or quotes',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final f in _Filter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${f.label} · ${counts[f]}'),
                      selected: _filter == f,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _filter == f
                            ? Theme.of(context).colorScheme.onPrimary
                            : f == _Filter.overdue && (counts[f] ?? 0) > 0
                                ? AppColors.danger
                                : AppColors.text,
                      ),
                      selectedColor: accent,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _MenuChip<String?>(
                icon: Icons.person_rounded,
                label: _person == null ? 'Everyone' : people[_person] ?? 'Person',
                active: _person != null,
                options: [
                  (null, 'Everyone'),
                  for (final e in (people.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))) (e.key, e.value)
                ],
                onSelected: (v) => setState(() => _person = v),
              ),
              _MenuChip<String?>(
                icon: Icons.category_rounded,
                label: _category == null ? 'All types' : categoryLabel(_category!),
                active: _category != null,
                options: [
                  (null, 'All types'),
                  for (final c in const ['deliverable', 'follow_up', 'pricing', 'meeting', 'information', 'support', 'other'])
                    (c, categoryLabel(c)),
                ],
                onSelected: (v) => setState(() => _category = v),
              ),
              _MenuChip<_Sort>(
                icon: Icons.sort_rounded,
                label: _sort.label,
                active: false,
                options: [for (final s in _Sort.values) (s, s.label)],
                onSelected: (v) => setState(() => _sort = v),
              ),
              FilterChip(
                avatar: Icon(Icons.groups_rounded, size: 16, color: _groupByPerson ? accent : AppColors.textDim),
                label: const Text('Group by person'),
                selected: _groupByPerson,
                showCheckmark: false,
                onSelected: (v) => setState(() => _groupByPerson = v),
              ),
            ]),
            const SizedBox(height: 6),
            if (shown.isEmpty)
              EmptyState(
                icon: _filter == _Filter.overdue ? Icons.verified_rounded : Icons.search_off_rounded,
                title: _filter == _Filter.overdue ? 'Nothing overdue' : 'No commitments match',
                body: _filter == _Filter.overdue ? 'Every live commitment is on schedule.' : 'Try another filter, person or search term.',
              ),
            for (final (title, items) in sections) ...[
              SectionLabel(
                title.isEmpty ? '${items.length} ${_filter.label.toLowerCase()}' : '$title · ${items.length}',
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
                trailing: title.isEmpty || !items.any((c) => c.isOverdue)
                    ? null
                    : Pill('${items.where((c) => c.isOverdue).length} overdue', color: AppColors.danger, dense: true),
              ),
              for (final c in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CommitmentTile(
                    c: c,
                    showEmployee: !_groupByPerson,
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c)));
                      reload();
                    },
                    trailing: !c.byClient && (c.isLive || c.isOverdue)
                        ? IconButton(
                            tooltip: 'Nudge ${c.employeeName?.split(' ').first ?? ''}',
                            icon: Icon(Icons.notifications_active_rounded, color: accent),
                            onPressed: () async {
                              try {
                                await app.backend!.nudge(c.id);
                                if (context.mounted) {
                                  toast(context, 'Nudged ${c.employeeName?.split(' ').first ?? 'them'}',
                                      icon: Icons.notifications_active_rounded);
                                }
                              } catch (e) {
                                if (context.mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
                              }
                            },
                          )
                        : null,
                  ),
                ),
            ],
          ]),
        );
      },
    );
  }
}

/// A chip that opens a menu of options.
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({required this.icon, required this.label, required this.active, required this.options, required this.onSelected});
  final IconData icon;
  final String label;
  final bool active;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<int>(
      tooltip: label,
      color: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.outline)),
      onSelected: (i) => onSelected(options[i].$1),
      itemBuilder: (_) => [for (final (i, o) in options.indexed) PopupMenuItem(value: i, child: Text(o.$2))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: .14) : AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? accent.withValues(alpha: .5) : AppColors.outline, width: .8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: active ? accent : AppColors.textDim),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: active ? accent : AppColors.text)),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: active ? accent : AppColors.textDim),
        ]),
      ),
    );
  }
}
