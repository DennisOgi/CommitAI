import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/demo_backend.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/phone_sheet.dart';
import '../auth/corporate_login_sheet.dart';
import '../commitments/commitments_screen.dart';
import '../team/company_screens.dart';
import '../team/dashboard_screen.dart';
import 'contacts_screen.dart';
import 'keypad_screen.dart';
import 'recents_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _Tab {
  const _Tab(this.label, this.icon, this.selectedIcon, this.build);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() build;
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = AppScope.read(context);
      if (app.pendingWorkSetup) {
        app.pendingWorkSetup = false;
        _switch(AppMode.corporate);
      }
    });
  }

  List<_Tab> _tabs(AppState app) => [
        _Tab('Calls', Icons.history_rounded, Icons.history_rounded, () => const RecentsScreen()),
        _Tab('Keypad', Icons.dialpad_rounded, Icons.dialpad_rounded, () => const KeypadScreen()),
        _Tab(app.corporate ? 'Clients' : 'Contacts', Icons.people_outline_rounded, Icons.people_rounded, () => const ContactsScreen()),
        // Personal mode has commitments too (from recorded personal calls, private to the user).
        _Tab('Commitments', Icons.handshake_outlined, Icons.handshake_rounded, () => const CommitmentsScreen()),
        if (app.isManager) _Tab('Team', Icons.insights_outlined, Icons.insights_rounded, () => const DashboardScreen()),
      ];

  Future<void> _switch(AppMode target) async {
    final app = AppScope.read(context);
    final result = await app.switchTo(target);
    if (!mounted) return;
    switch (result) {
      case NeedsCorporateLogin():
        if (await showCorporateLogin(context) && mounted) {
          setState(() => _index = 0);
          toast(context, 'Work mode on. Calls are recorded and personal calls are held.', icon: Icons.business_center_rounded);
        }
      case Switched(:final held):
        setState(() => _index = 0);
        if (target == AppMode.personal && held.isNotEmpty) {
          _showHeld(held);
        } else {
          toast(context, target == AppMode.corporate ? 'Back in Work mode.' : 'Personal mode. Nothing is recorded.',
              icon: target == AppMode.corporate ? Icons.business_center_rounded : Icons.person_rounded);
        }
      case SwitchFailed(:final message):
        toast(context, message, icon: Icons.error_outline_rounded);
    }
  }

  void _showHeld(List<HeldCall> held) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('While you were at work', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${held.length} personal call${held.length == 1 ? '' : 's'} held so you could focus.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 14),
          for (final h in held)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(name: h.from, size: 40),
              title: Text(h.from),
              subtitle: Text('Tried to call at ${clock(h.at)}'),
              trailing: const Icon(Icons.call_rounded),
            ),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Got it')),
        ]),
      ),
    );
  }

  void _menu(AppState app) {
    final demo = app.backend;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Avatar(name: app.session!.profile.fullName, size: 40),
              title: Text(app.session!.profile.fullName),
              subtitle: Text(app.corporate
                  ? '${app.session!.membership?.title ?? ''} · ${app.session!.organization?.name ?? ''} · ${app.session!.membership?.employeeId ?? ''}'
                  : 'Personal profile'),
            ),
            ListTile(
            leading: const Icon(Icons.phone_iphone_rounded),
            title: const Text('Your phone number'),
            subtitle: Text(app.myPhone ?? 'Add it so friends who have your number find you'),
            onTap: () {
              Navigator.pop(sheet);
              showPhoneNumberSheet(context);
            },
          ),
          if (app.corporate && (app.session!.membership?.isAdmin ?? false))
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: const Text('Team & company'),
                subtitle: const Text('Add people, roles, who reports to whom'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TeamAdminScreen()));
                },
              ),
            if (app.corporate)
              ListTile(
                leading: const Icon(Icons.lock_reset_rounded),
                title: const Text('Change Work PIN'),
                onTap: () {
                  Navigator.pop(sheet);
                  showChangePin(context);
                },
              ),
            if (!app.corporate && !app.isDemo)
              ListTile(
                leading: const Icon(Icons.domain_add_rounded),
                title: const Text('Register your company'),
                subtitle: const Text('Bring your team onto Commit Call'),
                onTap: () async {
                  Navigator.pop(sheet);
                  if (await showRegisterCompany(context) && mounted) {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TeamAdminScreen(welcome: true)));
                  }
                },
              ),
            if (app.corporate && app.session!.membership?.corporateDid != null)
              ListTile(
                leading: const Icon(Icons.phone_in_talk_rounded),
                title: const Text('Your work number'),
                subtitle: Text(prettyPhone(app.session!.membership!.corporateDid)),
              ),
            if (demo is DemoBackend) ...[
              const Divider(),
              const SectionLabel('Demo tools', padding: EdgeInsets.fromLTRB(20, 12, 20, 4)),
              ListTile(
                leading: const Icon(Icons.business_rounded),
                title: const Text('Simulate a call from a client'),
                subtitle: const Text('Bello Foods calls your work line'),
                onTap: () {
                  Navigator.pop(sheet);
                  final msg = demo.simulateIncoming(fromClient: true);
                  if (msg != null) {
                    toast(context, msg, icon: Icons.voicemail_rounded);
                    app.refresh();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.emoji_people_rounded),
                title: const Text('Simulate a call from a friend'),
                subtitle: const Text('Chidi calls you app-to-app'),
                onTap: () {
                  Navigator.pop(sheet);
                  final msg = demo.simulateIncoming(fromClient: false);
                  if (msg != null) {
                    toast(context, msg, icon: Icons.do_not_disturb_on_rounded);
                    app.refresh();
                  }
                },
              ),
            ],
            const Divider(),
            StatefulBuilder(
              builder: (context, setSheet) => SwitchListTile(
                secondary: const Icon(Icons.fiber_manual_record_rounded),
                title: const Text('Record my personal calls'),
                subtitle: const Text('Kept only to find your commitments, then deleted.'),
                value: app.recordsPersonalCalls,
                onChanged: (v) async {
                  final err = await app.setRecordPersonalCalls(v);
                  setSheet(() {});
                  if (err != null && context.mounted) toast(context, err, icon: Icons.error_outline_rounded);
                },
              ),
            ),
            StatefulBuilder(
              builder: (context, setSheet) => SwitchListTile(
                secondary: const Icon(Icons.travel_explore_rounded),
                title: const Text('Let people find me'),
                subtitle: const Text('Anyone on Commit Call can search your name and call you. '
                    'Off: only people who know your email can.'),
                value: app.discoverable,
                onChanged: (v) async {
                  final err = await app.setDiscoverable(v);
                  setSheet(() {});
                  if (err != null && context.mounted) toast(context, err, icon: Icons.error_outline_rounded);
                },
              ),
            ),
            if (defaultTargetPlatform == TargetPlatform.android && !app.isDemo)
              StatefulBuilder(
                builder: (context, setSheet) => SwitchListTile(
                  secondary: const Icon(Icons.ring_volume_rounded),
                  title: const Text('Ring when the app is closed'),
                  subtitle: const Text('Calls reach you while you’re in other apps.'),
                  value: app.ringInBackground,
                  onChanged: (v) async {
                    await app.setRingInBackground(v);
                    setSheet(() {});
                  },
                ),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.danger),
              title: const Text('Sign out', style: TextStyle(color: AppColors.danger)),
              onTap: () {
                Navigator.pop(sheet);
                app.signOut();
              },
            ),
          ]),
        ),
      ),
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  String _greeting(DateTime now) => now.hour < 12
      ? 'Good morning'
      : now.hour < 17
          ? 'Good afternoon'
          : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final tabs = _tabs(app);
    if (_index >= tabs.length) _index = 0;
    final p = app.palette;
    final now = DateTime.now();
    return Backdrop(
      palette: p,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          // Phone-proportioned column on tablets and desktop instead of stretched content.
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${_days[now.weekday - 1]} · ${now.day} ${_months[now.month - 1]}'.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(height: 4),
                        Text('${_greeting(now)}, ${app.firstName}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.display(22, weight: FontWeight.w500)),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Tooltip(
                      message: 'Account',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _menu(app),
                        child: Avatar(name: app.session?.profile.fullName ?? '?', size: 42),
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
                  child: Row(children: [
                    ModeSwitch(mode: app.mode, busy: app.switching, onChanged: _switch),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        layoutBuilder: (current, previous) =>
                            Stack(alignment: Alignment.centerLeft, children: [...previous, if (current != null) current]),
                        child: app.corporate
                            ? Row(key: const ValueKey('work'), children: [
                                const RecordingDot(),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(app.session?.organization?.name ?? 'On the record',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12.5, color: AppColors.textDim, fontWeight: FontWeight.w600)),
                                ),
                              ])
                            : Text(app.recordsPersonalCalls ? 'Private' : 'Not recorded',
                                key: const ValueKey('personal'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: AppColors.textDim, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ]),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(position: Tween(begin: const Offset(0, .02), end: Offset.zero).animate(a), child: child),
                    ),
                    child: KeyedSubtree(key: ValueKey('${app.mode}-$_index-${tabs[_index].label}'), child: tabs[_index].build()),
                  ),
                ),
              ]),
            ),
          ),
        ),
        bottomNavigationBar: Dock(
          index: _index,
          onSelect: (i) => setState(() => _index = i),
          items: [for (final t in tabs) DockItem(t.label, t.icon, t.selectedIcon)],
        ),
      ),
    );
  }
}
