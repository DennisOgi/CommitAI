import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/tiles.dart';
import '../call/call_detail_screen.dart';
import '../commitments/commitment_detail_screen.dart';
import '../commitments/commitments_screen.dart';
import 'team_commitments_view.dart';

/// Management view: what the team promised clients, what's at risk, who's reliable.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _days = 30;
  bool _register = false; // false = overview, true = all staff commitments
  String _registerFilter = 'open';

  void _openRegister(String filter) => setState(() {
        _registerFilter = filter;
        _register = true;
      });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text('Team', style: AppType.display(28, weight: FontWeight.w600)),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Overview'), icon: Icon(Icons.insights_rounded, size: 16)),
              ButtonSegment(value: true, label: Text('Commitments'), icon: Icon(Icons.list_alt_rounded, size: 16)),
            ],
            selected: {_register},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() {
              _register = s.first;
              _registerFilter = 'open';
            }),
          ),
        ]),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _register
              ? TeamCommitmentsView(key: ValueKey('register-$_registerFilter'), initialFilter: _registerFilter)
              : KeyedSubtree(key: const ValueKey('overview'), child: _overview(context)),
        ),
      ),
    ]);
  }

  Widget _overview(BuildContext context) {
    final app = AppScope.of(context);
    final accent = app.palette.accent;
    return Loader<Dashboard>(
      key: ValueKey(_days),
      load: (b) => b.dashboard(days: _days),
      builder: (context, d, reload) {
        num? k(String key) => d.kpis[key];
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
            Row(children: [
              Text('Last $_days days', style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7d')),
                  ButtonSegment(value: 30, label: Text('30d')),
                  ButtonSegment(value: 90, label: Text('90d'))
                ],
                selected: {_days},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (s) => setState(() => _days = s.first),
              ),
            ]),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.55,
              children: [
                _Kpi(
                    label: 'On-time rate',
                    value: k('on_time_rate') == null ? '–' : '${k('on_time_rate')}%',
                    icon: Icons.verified_rounded,
                    color: ScoreRing.colorFor(k('on_time_rate')?.toInt()),
                    hero: true,
                    accent: accent),
                _Kpi(
                    label: 'Overdue',
                    value: '${k('overdue') ?? 0}',
                    icon: Icons.error_rounded,
                    color: AppColors.danger,
                    sub: 'View all →',
                    onTap: () => _openRegister('overdue')),
                _Kpi(
                    label: 'Open commitments',
                    value: '${k('open') ?? 0}',
                    icon: Icons.pending_actions_rounded,
                    color: AppColors.warning,
                    sub: '${k('due_this_week') ?? 0} due this week',
                    onTap: () => _openRegister('open')),
                _Kpi(
                    label: 'Client calls',
                    value: '${k('calls') ?? 0}',
                    icon: Icons.call_rounded,
                    color: AppColors.info,
                    sub: '${k('commitments_per_call') ?? 0} commitments / call'),
              ],
            ),
            if ((k('pending_review') ?? 0) > 0 || (k('off_duty_attempts') ?? 0) > 0) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if ((k('pending_review') ?? 0) > 0)
                  GestureDetector(
                    onTap: () => _openRegister('review'),
                    child: Pill('${k('pending_review')} awaiting employee review', color: AppColors.info, icon: Icons.fact_check_rounded),
                  ),
                if ((k('off_duty_attempts') ?? 0) > 0)
                  Pill('${k('off_duty_attempts')} client calls reached staff off duty',
                      color: AppColors.warning, icon: Icons.voicemail_rounded),
              ]),
            ],
            const SectionLabel('Commitments made vs kept', padding: EdgeInsets.fromLTRB(4, 24, 4, 10)),
            Card(child: Padding(padding: const EdgeInsets.fromLTRB(12, 18, 12, 12), child: TrendChart(points: d.trend, accent: accent))),
            SectionLabel('At risk · ${d.atRisk.length}',
                padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
                trailing: TextButton(onPressed: () => _openRegister('open'), child: const Text('All commitments →'))),
            if (d.atRisk.isEmpty)
              const Card(
                  child: Padding(padding: EdgeInsets.all(16), child: Text('Nothing due in the next 48 hours and nothing slipped. 🎉'))),
            for (final c in d.atRisk)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: CommitmentTile(
                  c: c,
                  showEmployee: true,
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c)));
                    reload();
                  },
                  trailing: c.isLive || c.isOverdue
                      ? IconButton(
                          tooltip: 'Nudge',
                          icon: Icon(Icons.notifications_active_rounded, color: accent),
                          onPressed: () async {
                            await app.backend!.nudge(c.id);
                            if (context.mounted) {
                              toast(context, 'Nudged ${c.employeeName?.split(' ').first}', icon: Icons.notifications_active_rounded);
                            }
                          },
                        )
                      : null,
                ),
              ),
            const SectionLabel('People', padding: EdgeInsets.fromLTRB(4, 24, 4, 10)),
            Card(
              child: Column(children: [
                for (final (i, person) in d.people.indexed) ...[
                  if (i > 0) const Divider(indent: 72),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    leading: ScoreRing(value: person.reliability, size: 46),
                    title: Text(person.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      '${person.open} open',
                      if (person.overdue > 0) '${person.overdue} overdue',
                      '${person.calls} calls',
                    ].join(' · ')),
                    trailing: person.overdue > 0
                        ? Pill('${person.overdue}', color: AppColors.danger, icon: Icons.error_rounded, dense: true)
                        : const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CommitmentsScreen(memberId: person.membershipId, memberName: person.name),
                    )),
                  ),
                ],
              ]),
            ),
            if (d.byCategory.isNotEmpty) ...[
              const SectionLabel('Open by type', padding: EdgeInsets.fromLTRB(4, 24, 4, 10)),
              Card(child: Padding(padding: const EdgeInsets.all(16), child: _CategoryBars(data: d.byCategory, accent: accent))),
            ],
            if (d.attentionCalls.isNotEmpty) ...[
              const SectionLabel('Calls that need attention', padding: EdgeInsets.fromLTRB(4, 24, 4, 10)),
              Card(
                child: Column(children: [
                  for (final call in d.attentionCalls)
                    ListTile(
                      leading: Icon(call.sentiment == 'negative' ? Icons.sentiment_dissatisfied_rounded : Icons.sentiment_neutral_rounded,
                          color: call.sentiment == 'negative' ? AppColors.danger : AppColors.warning),
                      title: Text(call.counterpartName),
                      subtitle: Text(call.summary ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text(whenLabel(call.startedAt), style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallDetailScreen(callId: call.id))),
                    ),
                ]),
              ),
            ],
          ]),
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color,
      this.sub,
      this.hero = false,
      this.accent,
      this.onTap});
  final VoidCallback? onTap;
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? sub;
  final bool hero;
  final Color? accent;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: _body(),
        ),
      );

  Widget _body() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: hero ? (accent ?? color).withValues(alpha: .6) : AppColors.outline),
          gradient: hero
              ? LinearGradient(
                  colors: [(accent ?? color).withValues(alpha: .22), AppColors.surface],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight)
              : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 12, color: AppColors.textDim, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis)),
          ]),
          Text(value, style: AppType.display(28, weight: FontWeight.w600)),
          Text(sub ?? ' ', style: const TextStyle(fontSize: 11, color: AppColors.textFaint), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}

class _CategoryBars extends StatelessWidget {
  const _CategoryBars({required this.data, required this.accent});
  final Map<String, int> data;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final entries = data.entries.toList()..sort((a, b) => b.value - a.value);
    final max = entries.first.value;
    return Column(children: [
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(categoryIcon(e.key), size: 16, color: AppColors.textDim),
            const SizedBox(width: 8),
            SizedBox(width: 92, child: Text(categoryLabel(e.key), style: const TextStyle(fontSize: 13, color: AppColors.text))),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: e.value / max, minHeight: 8, color: accent, backgroundColor: AppColors.surfaceHigh),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
                width: 20,
                child: Text('${e.value}',
                    textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text))),
          ]),
        ),
    ]);
  }
}
