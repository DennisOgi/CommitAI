import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// First run for a new account: how the two identities work, what happens on a work
/// call, the permissions a calling app needs (asked with a reason, before the first
/// call rather than in the middle of one), and joining the company workspace.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  static bool get _mobile => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  late final List<Widget Function()> _steps = [
    () => const _IdentitiesPage(),
    () => const _RecordPage(),
    if (_mobile) () => const _PermissionsPage(),
    () => _WorkspacePage(onJoin: () => _finish(joinWork: true), onLater: () => _finish(joinWork: false)),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish({required bool joinWork}) async {
    final app = AppScope.read(context);
    app.pendingWorkSetup = joinWork;
    await app.completeOnboarding();
  }

  void _next() => _pages.nextPage(duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final last = _page == _steps.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
                child: Row(children: [
                  const CommitLogo(size: 28),
                  const SizedBox(width: 14),
                  // Progress: one segment per step.
                  Expanded(
                    child: Row(children: [
                      for (var i = 0; i < _steps.length; i++)
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            height: 3,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: i <= _page ? Theme.of(context).colorScheme.primary : AppColors.outline,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  TextButton(onPressed: () => _finish(joinWork: false), child: const Text('Skip')),
                ]),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [for (final s in _steps) s()],
                ),
              ),
              if (!last)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: FilledButton(onPressed: _next, child: const Text('Continue')),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.kicker, required this.title, required this.body, required this.art, this.footer});
  final String kicker;
  final String title;
  final String body;
  final Widget art;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(24, 28, 24, 24), children: [
        art,
        const SizedBox(height: 32),
        Text(kicker.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 8),
        Text(title, style: AppType.display(32, weight: FontWeight.w500)),
        const SizedBox(height: 12),
        Text(body, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.textDim)),
        if (footer != null) ...[const SizedBox(height: 24), footer!],
      ]);
}

class _IdentitiesPage extends StatelessWidget {
  const _IdentitiesPage();

  @override
  Widget build(BuildContext context) => const _Page(
        kicker: 'Two identities',
        title: 'One phone.\nPersonal and Work.',
        body: 'Switch with one tap. In Personal mode Commit AI is a private phone: nothing is recorded or shared. '
            'In Work mode your client calls are recorded and their commitments tracked, and personal calls are held '
            'until you switch back.',
        art: Row(children: [
          Expanded(child: _ModeCard(p: ModePalette.personal, lines: ['Private calls', 'Never recorded', 'Your contacts'])),
          SizedBox(width: 12),
          Expanded(child: _ModeCard(p: ModePalette.corporate, lines: ['Client calls', 'Recorded & tracked', 'Company directory'])),
        ]),
      );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.p, required this.lines});
  final ModePalette p;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: p.accent.withValues(alpha: .45)),
          gradient: LinearGradient(
              colors: [p.accent.withValues(alpha: .18), AppColors.surface], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: p.gradient)),
            child: Icon(p.icon, color: p.onAccent, size: 20),
          ),
          const SizedBox(height: 14),
          Text(p.name, style: AppType.display(22, weight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.check_rounded, size: 14, color: p.accent),
                const SizedBox(width: 6),
                Expanded(child: Text(l, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim))),
              ]),
            ),
        ]),
      );
}

class _RecordPage extends StatelessWidget {
  const _RecordPage();

  @override
  Widget build(BuildContext context) => _Page(
        kicker: 'On work calls',
        title: 'Every commitment, caught.',
        body: 'Both sides hear that the call is recorded. As you talk, Commit AI notes what was agreed, '
            'when it’s due and the exact words. After the call you confirm or edit each one. You review it first; '
            'unreviewed items are shared with your manager after 24 hours.',
        art: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const RecordingBadge(label: 'Recording · both sides informed'),
            const SizedBox(height: 16),
            Text('“I’ll send the revised invoice with the 10% credit by Friday.”',
                style: AppType.display(19, weight: FontWeight.w400, style: FontStyle.italic, height: 1.3)),
            const SizedBox(height: 14),
            Wrap(spacing: 6, runSpacing: 6, children: [
              Pill('Pricing', color: ModePalette.corporate.accent, icon: Icons.sell_rounded, dense: true),
              const Pill('Due Fri 17:00', color: AppColors.info, icon: Icons.schedule_rounded, dense: true),
              const Pill('Needs your review', color: AppColors.success, icon: Icons.fact_check_rounded, dense: true),
            ]),
          ]),
        ),
      );
}

class _PermissionsPage extends StatefulWidget {
  const _PermissionsPage();

  @override
  State<_PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<_PermissionsPage> {
  final Map<Permission, PermissionStatus?> _status = {Permission.microphone: null, Permission.notification: null};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final p in _status.keys.toList()) {
      try {
        _status[p] = await p.status;
      } catch (_) {
        _status[p] = PermissionStatus.granted; // not applicable on this platform
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _ask(Permission p) async {
    final s = _status[p];
    if (s == PermissionStatus.permanentlyDenied) {
      await openAppSettings();
    } else {
      await p.request();
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => _Page(
        kicker: 'Permissions',
        title: 'Two things to allow.',
        body: 'Asked once now, so a call never stalls on a pop-up.',
        art: const SizedBox.shrink(),
        footer: Column(children: [
          _PermissionRow(
            icon: Icons.mic_rounded,
            title: 'Microphone',
            why: 'So the other person can hear you. Only used during calls.',
            status: _status[Permission.microphone],
            onAllow: () => _ask(Permission.microphone),
          ),
          const SizedBox(height: 10),
          _PermissionRow(
            icon: Icons.notifications_rounded,
            title: 'Notifications',
            why: 'For incoming calls, deadline reminders and your manager’s follow-ups.',
            status: _status[Permission.notification],
            onAllow: () => _ask(Permission.notification),
          ),
        ]),
      );
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.icon, required this.title, required this.why, required this.status, required this.onAllow});
  final IconData icon;
  final String title;
  final String why;
  final PermissionStatus? status;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final granted = status?.isGranted ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: .12)),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(why, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textDim)),
            ]),
          ),
          const SizedBox(width: 10),
          if (granted)
            const Pill('Allowed', color: AppColors.success, icon: Icons.check_rounded, dense: true)
          else
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: status == null ? null : onAllow,
              child: Text(status == PermissionStatus.permanentlyDenied ? 'Settings' : 'Allow'),
            ),
        ]),
      ),
    );
  }
}

class _WorkspacePage extends StatelessWidget {
  const _WorkspacePage({required this.onJoin, required this.onLater});
  final VoidCallback onJoin;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final name = AppScope.of(context).firstName;
    return _Page(
      kicker: 'Your workspace',
      title: 'Join your company, ${name.isEmpty ? 'when ready' : name}.',
      body: 'Your company gives you a company code, an employee ID and a PIN. Enter them once; '
          'after that, switching to Work takes a fingerprint or Face ID. '
          'No company yet? You can use Personal mode now and join later from the Work switch.',
      art: Container(
        height: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(colors: [ModePalette.corporate.accent.withValues(alpha: .22), AppColors.surface]),
          border: Border.all(color: ModePalette.corporate.accent.withValues(alpha: .4)),
        ),
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (label, value) in const [('Company', 'ACME'), ('ID', 'EMP-0042'), ('PIN', '••••')]) ...[
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 6),
                Text(value, style: AppType.mono(16, weight: FontWeight.w600)),
              ]),
              if (label != 'PIN') const SizedBox(width: 26),
            ],
          ]),
        ),
      ),
      footer: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: ModePalette.corporate.accent, foregroundColor: ModePalette.corporate.onAccent),
          onPressed: onJoin,
          icon: const Icon(Icons.work_rounded),
          label: const Text('Enter my corporate ID'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onLater, child: const Text('Not now, use Personal')),
      ]),
    );
  }
}
