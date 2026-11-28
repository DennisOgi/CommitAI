import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';

// ============================================================ shared bits ===

String roleLabel(MemberRole r) => switch (r) {
      MemberRole.admin => 'Admin',
      MemberRole.manager => 'Manager',
      MemberRole.employee => 'Employee',
    };

Color roleColor(MemberRole r) => switch (r) {
      MemberRole.admin => AppColors.warning,
      MemberRole.manager => ModePalette.corporate.accent,
      MemberRole.employee => AppColors.textDim,
    };

/// A sheet in the Work (corporate) look.
Future<T?> _workSheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Theme(
        data: buildTheme(ModePalette.corporate),
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), child: child),
        ),
      ),
    );

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    const p = ModePalette.corporate;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(gradient: LinearGradient(colors: p.gradient), borderRadius: BorderRadius.circular(13)),
          child: Icon(icon, color: p.onAccent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.titleLarge),
            Text(subtitle, style: t.bodyMedium),
          ]),
        ),
      ]),
    );
  }
}

/// "Choose a PIN" + "Type it again", 4–8 digits.
class _NewPinFields extends StatelessWidget {
  const _NewPinFields({required this.pin, required this.again, this.label = 'Choose a Work PIN (4–8 digits)'});
  final TextEditingController pin;
  final TextEditingController again;
  final String label;

  @override
  Widget build(BuildContext context) => Column(children: [
        TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.pin_rounded)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: again,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
          decoration: const InputDecoration(labelText: 'Type it again', prefixIcon: Icon(Icons.pin_rounded)),
        ),
      ]);
}

String? _pinProblem(String pin, String again) {
  if (pin.length < 4) return 'Your PIN needs at least 4 digits.';
  if (pin != again) return 'The two PINs don’t match.';
  if (RegExp(r'^(\d)\1+$').hasMatch(pin) || '0123456789'.contains(pin) || '9876543210'.contains(pin)) {
    return 'Pick a PIN that’s harder to guess.';
  }
  return null;
}

class _Error extends StatelessWidget {
  const _Error(this.text);
  final String? text;

  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
        );
}

// ======================================================= register company ===

/// Register a company. Returns true when the user is now its admin, in Work mode.
Future<bool> showRegisterCompany(BuildContext context) async => await _workSheet<bool>(context, const _RegisterCompany()) ?? false;

class _RegisterCompany extends StatefulWidget {
  const _RegisterCompany();

  @override
  State<_RegisterCompany> createState() => _RegisterCompanyState();
}

class _RegisterCompanyState extends State<_RegisterCompany> {
  final _name = TextEditingController();
  final _title = TextEditingController();
  final _pin = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    final problem = _name.text.trim().length < 2 ? 'Enter your company’s name.' : _pinProblem(_pin.text, _again.text);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = AppScope.read(context);
    final err = await app.createCompany(name: _name.text.trim(), pin: _pin.text, title: _title.text.trim());
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    HapticFeedback.mediumImpact();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SheetTitle(Icons.domain_add_rounded, 'Register your company', 'You’ll be its admin. Takes a minute.'),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Company name', prefixIcon: Icon(Icons.apartment_rounded)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your job title (optional)', prefixIcon: Icon(Icons.badge_rounded)),
        ),
        const SizedBox(height: 12),
        _NewPinFields(pin: _pin, again: _again),
        const SizedBox(height: 14),
        const _InfoBox('Next you’ll get a company code and can add your team: their roles, titles and who they report to.'),
        _Error(_error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create company'),
        ),
      ]);
}

class _InfoBox extends StatelessWidget {
  const _InfoBox(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: ModePalette.corporate.accentSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, size: 18, color: ModePalette.corporate.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
        ]),
      );
}

// ============================================================ join invite ===

/// Accept an email invite. Returns true when the user is now in Work mode.
Future<bool> showJoinInvite(BuildContext context, OrgInvite invite) async => await _workSheet<bool>(context, _JoinInvite(invite)) ?? false;

class _JoinInvite extends StatefulWidget {
  const _JoinInvite(this.invite);
  final OrgInvite invite;

  @override
  State<_JoinInvite> createState() => _JoinInviteState();
}

class _JoinInviteState extends State<_JoinInvite> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    final problem = _pinProblem(_pin.text, _again.text);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).joinCompany(widget.invite.membershipId, _pin.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    HapticFeedback.mediumImpact();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.invite;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SheetTitle(Icons.how_to_reg_rounded, 'Join ${i.organization}', '${i.title ?? roleLabel(i.role)} · Employee ID ${i.employeeId}'),
      _NewPinFields(pin: _pin, again: _again, label: 'Choose your Work PIN (4–8 digits)'),
      const SizedBox(height: 14),
      const _InfoBox('You’ll use this PIN to switch to Work mode. Work calls are recorded and the commitments '
          'you approve are shared with your managers. Your personal side stays private.'),
      _Error(_error),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _go,
        child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Join'),
      ),
    ]);
  }
}

// ============================================================= change PIN ===

/// Change the Work PIN. [forced] after signing in with a one-time PIN.
Future<void> showChangePin(BuildContext context, {bool forced = false}) => _workSheet<void>(context, _ChangePin(forced: forced));

class _ChangePin extends StatefulWidget {
  const _ChangePin({required this.forced});
  final bool forced;

  @override
  State<_ChangePin> createState() => _ChangePinState();
}

class _ChangePinState extends State<_ChangePin> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    final problem = _current.text.isEmpty ? 'Enter your current PIN.' : _pinProblem(_pin.text, _again.text);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).changeWorkPin(_current.text, _pin.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(const SnackBar(content: Text('Your Work PIN is changed.')));
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !widget.forced,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SheetTitle(Icons.lock_reset_rounded, widget.forced ? 'Choose your own PIN' : 'Change Work PIN',
              widget.forced ? 'Replace the one-time PIN your admin gave you.' : 'Used to switch to Work mode.'),
          TextField(
            controller: _current,
            obscureText: true,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
            decoration:
                InputDecoration(labelText: widget.forced ? 'One-time PIN' : 'Current PIN', prefixIcon: const Icon(Icons.password_rounded)),
          ),
          const SizedBox(height: 12),
          _NewPinFields(pin: _pin, again: _again, label: 'New PIN (4–8 digits)'),
          _Error(_error),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _go,
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save PIN'),
          ),
        ]),
      );
}

// ========================================================= admin: team ===

/// The admin's "Team & company" screen: everyone, add people, edit roles, settings.
class TeamAdminScreen extends StatefulWidget {
  const TeamAdminScreen({super.key, this.welcome = false});

  /// Just registered: open with a nudge to add the team.
  final bool welcome;

  @override
  State<TeamAdminScreen> createState() => _TeamAdminScreenState();
}

class _TeamAdminScreenState extends State<TeamAdminScreen> {
  int _version = 0;
  String _q = '';

  void _reload() => setState(() => _version++);

  Future<void> _add(List<OrgMember> members) async {
    final creds = await _workSheet<MemberCredentials>(context, _MemberForm(members: members));
    if (creds != null && mounted) {
      _reload();
      await showCredentials(context, [creds]);
    }
  }

  Future<void> _bulk(List<OrgMember> members) async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _BulkAddScreen(members: members)));
    if (done == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildTheme(ModePalette.corporate),
      child: Scaffold(
        appBar: AppBar(title: const Text('Team & company')),
        body: Loader<(OrgOverview, List<OrgMember>)>(
          key: ValueKey(_version),
          load: (b) async => (await b.orgOverview(), await b.orgMembers()),
          builder: (context, data, reload) {
            final (o, members) = data;
            final q = _q.toLowerCase();
            final shown = members
                .where((m) =>
                    q.isEmpty || [m.fullName, m.email, m.title, m.department, m.employeeId].any((s) => (s ?? '').toLowerCase().contains(q)))
                .toList();
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 110), children: [
                _CompanyCard(
                    o: o,
                    onSettings: () async {
                      if (await _workSheet<bool>(context, _CompanySettings(o: o)) == true) _reload();
                    }),
                if (widget.welcome && members.length <= 1) ...[
                  const SizedBox(height: 12),
                  const _InfoBox('Your company is ready. Add your team below: give each person a role and '
                      'say who they report to. They’ll get a one-time PIN to sign in with.'),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _add(members),
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Add person'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _bulk(members),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Paste a list'),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                if (members.length > 6)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      onChanged: (v) => setState(() => _q = v),
                      decoration: const InputDecoration(hintText: 'Search your team', prefixIcon: Icon(Icons.search_rounded)),
                    ),
                  ),
                SectionLabel('${o.members} ${o.members == 1 ? 'person' : 'people'} · ${o.joined} signed in',
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
                for (final m in shown)
                  _MemberTile(
                    m: m,
                    onTap: () async {
                      final changed = await _workSheet<bool>(context, _MemberEdit(member: m, members: members));
                      if (changed == true) _reload();
                    },
                  ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _CompanyCard extends StatelessWidget {
  const _CompanyCard({required this.o, required this.onSettings});
  final OrgOverview o;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    const p = ModePalette.corporate;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: p.gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(o.org.name, style: AppType.display(24, weight: FontWeight.w600, color: p.onAccent))),
          IconButton(
            tooltip: 'Company settings',
            onPressed: onSettings,
            icon: Icon(Icons.settings_rounded, color: p.onAccent),
          ),
        ]),
        const SizedBox(height: 10),
        Text('COMPANY CODE',
            style: TextStyle(color: p.onAccent.withValues(alpha: .7), fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Row(children: [
          Text(o.org.corpCode, style: AppType.mono(26, color: p.onAccent)),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: o.org.corpCode));
              toast(context, 'Company code copied', icon: Icons.copy_rounded);
            },
            icon: Icon(Icons.copy_rounded, size: 20, color: p.onAccent),
          ),
        ]),
        Text('Your team types this when they switch to Work.', style: TextStyle(color: p.onAccent.withValues(alpha: .75), fontSize: 12.5)),
      ]),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.m, required this.onTap});
  final OrgMember m;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (m.title != null) m.title!,
      if (m.managerName != null) 'reports to ${m.managerName!.split(' ').first}',
    ].join(' · ');
    return Opacity(
      opacity: m.active ? 1 : .5,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        onTap: onTap,
        leading: Avatar(name: m.fullName),
        title: Text(m.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(sub.isEmpty ? m.employeeId : sub, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!m.active)
            const Pill('Inactive', color: AppColors.textFaint, dense: true)
          else if (!m.joined)
            const Pill('Not signed in', color: AppColors.textDim, dense: true)
          else
            Pill(roleLabel(m.role), color: roleColor(m.role), dense: true),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
        ]),
      ),
    );
  }
}

// ---- add / edit one person ----

class _MemberForm extends StatefulWidget {
  const _MemberForm({required this.members});
  final List<OrgMember> members;

  @override
  State<_MemberForm> createState() => _MemberFormState();
}

class _MemberFormState extends State<_MemberForm> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _title = TextEditingController();
  final _dept = TextEditingController();
  MemberRole _role = MemberRole.employee;
  String? _manager;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Enter their name.');
    final email = _email.text.trim();
    if (email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return setState(() => _error = 'That email doesn’t look right.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final creds = await AppScope.read(context).backend!.addMember({
        'full_name': _name.text.trim(),
        if (email.isNotEmpty) 'email': email,
        'role': _role.name,
        if (_title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        if (_dept.text.trim().isNotEmpty) 'department': _dept.text.trim(),
        if (_manager != null) 'manager_id': _manager,
      });
      if (mounted) Navigator.pop(context, creds);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SheetTitle(Icons.person_add_alt_1_rounded, 'Add a person', 'They’ll get a one-time PIN to sign in.'),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_rounded)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email (optional)',
            helperText: 'If they sign up with this email, they can join with one tap.',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 12),
        _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _title,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Job title'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _dept,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Department'),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _ManagerPicker(members: widget.members, value: _manager, onChanged: (v) => setState(() => _manager = v)),
        _Error(_error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add'),
        ),
      ]);
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.value, required this.onChanged});
  final MemberRole value;
  final ValueChanged<MemberRole> onChanged;

  static const _help = {
    MemberRole.employee: 'Their work calls and commitments go to their manager.',
    MemberRole.manager: 'Sees the commitments of everyone who reports to them.',
    MemberRole.admin: 'Sees everyone and manages the team and company settings.',
  };

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<MemberRole>(
          segments: [for (final r in MemberRole.values.reversed) ButtonSegment(value: r, label: Text(roleLabel(r)))],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(_help[value]!, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
        ),
      ]);
}

class _ManagerPicker extends StatelessWidget {
  const _ManagerPicker({required this.members, required this.value, required this.onChanged, this.exclude});
  final List<OrgMember> members;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? exclude;

  @override
  Widget build(BuildContext context) {
    final options = members.where((m) => m.active && m.id != exclude && m.role != MemberRole.employee).toList();
    return DropdownButtonFormField<String?>(
      initialValue: options.any((m) => m.id == value) ? value : null,
      decoration: const InputDecoration(labelText: 'Reports to', prefixIcon: Icon(Icons.account_tree_rounded)),
      items: [
        const DropdownMenuItem(value: null, child: Text('No one')),
        for (final m in options) DropdownMenuItem(value: m.id, child: Text('${m.fullName} · ${roleLabel(m.role)}')),
      ],
      onChanged: onChanged,
    );
  }
}

class _MemberEdit extends StatefulWidget {
  const _MemberEdit({required this.member, required this.members});
  final OrgMember member;
  final List<OrgMember> members;

  @override
  State<_MemberEdit> createState() => _MemberEditState();
}

class _MemberEditState extends State<_MemberEdit> {
  late final _title = TextEditingController(text: widget.member.title);
  late final _dept = TextEditingController(text: widget.member.department);
  late MemberRole _role = widget.member.role;
  late String? _manager = widget.member.managerId;
  bool _busy = false;
  String? _error;

  Future<void> _patch(Map<String, dynamic> patch, {bool close = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).backend!.updateMember(widget.member.id, patch);
      if (mounted && close) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPin() async {
    final m = widget.member;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Reset ${m.fullName.split(' ').first}’s PIN?'),
        content: const Text('They’ll get a new one-time PIN and choose their own after signing in. Their old PIN stops working.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Reset PIN')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      final creds = await AppScope.read(context).backend!.resetMemberPin(m.id);
      if (!mounted) return;
      final nav = Navigator.of(context);
      await showCredentials(context, [creds]);
      nav.pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final me = AppScope.of(context).session?.membership?.id == m.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Avatar(name: m.fullName, size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.fullName, style: Theme.of(context).textTheme.titleLarge),
            Text([m.employeeId, if (m.email != null) m.email!].join(' · '), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(m.joined ? 'Signed in on the app' : 'Hasn’t signed in yet',
                style: TextStyle(fontSize: 12.5, color: m.joined ? AppColors.success : AppColors.textDim, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: TextField(controller: _title, decoration: const InputDecoration(labelText: 'Job title'))),
        const SizedBox(width: 10),
        Expanded(child: TextField(controller: _dept, decoration: const InputDecoration(labelText: 'Department'))),
      ]),
      const SizedBox(height: 12),
      _ManagerPicker(members: widget.members, value: _manager, exclude: m.id, onChanged: (v) => setState(() => _manager = v)),
      _Error(_error),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _patch({
                  'role': _role.name,
                  'title': _title.text.trim(),
                  'department': _dept.text.trim(),
                  'manager_id': _manager ?? '',
                }),
        child: const Text('Save changes'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _busy ? null : _resetPin, icon: const Icon(Icons.lock_reset_rounded), label: const Text('Reset PIN')),
      if (!me)
        TextButton.icon(
          onPressed: _busy ? null : () => _patch({'active': !m.active}),
          icon: Icon(m.active ? Icons.person_off_rounded : Icons.person_rounded, color: m.active ? AppColors.danger : null),
          label:
              Text(m.active ? 'Deactivate (left the company)' : 'Reactivate', style: TextStyle(color: m.active ? AppColors.danger : null)),
        ),
    ]);
  }
}

// ---- paste a list ----

class _BulkAddScreen extends StatefulWidget {
  const _BulkAddScreen({required this.members});
  final List<OrgMember> members;

  @override
  State<_BulkAddScreen> createState() => _BulkAddScreenState();
}

class _BulkAddScreenState extends State<_BulkAddScreen> {
  final _text = TextEditingController();
  bool _busy = false;
  List<(MemberCredentials?, String?, String)>? _results;

  /// One person per line: name, email, role, title, department, manager's name or email.
  /// Commas or tabs (pasted from a spreadsheet). Only the name is required.
  List<Map<String, dynamic>> _parse() {
    final rows = <Map<String, dynamic>>[];
    for (final line in _text.text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final f = line.split(line.contains('\t') ? '\t' : ',').map((s) => s.trim()).toList();
      String at(int i) => i < f.length ? f[i] : '';
      if (rows.isEmpty && at(0).toLowerCase() == 'name') continue; // header row
      final role = at(2).toLowerCase();
      final mgr = at(5).toLowerCase();
      final manager = mgr.isEmpty
          ? null
          : widget.members.where((m) => m.fullName.toLowerCase() == mgr || (m.email ?? '').toLowerCase() == mgr).firstOrNull;
      rows.add({
        'full_name': at(0),
        if (at(1).contains('@')) 'email': at(1),
        'role': role.startsWith('admin')
            ? 'admin'
            : role.startsWith('manag')
                ? 'manager'
                : 'employee',
        if (at(3).isNotEmpty) 'title': at(3),
        if (at(4).isNotEmpty) 'department': at(4),
        if (manager != null) 'manager_id': manager.id,
      });
    }
    return rows;
  }

  Future<void> _go() async {
    final rows = _parse();
    if (rows.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await AppScope.read(context).backend!.addMembers(rows);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final ok = [
      for (final r in results ?? const <(MemberCredentials?, String?, String)>[])
        if (r.$1 != null) r.$1!
    ];
    return Theme(
      data: buildTheme(ModePalette.corporate),
      child: PopScope(
        canPop: true,
        onPopInvokedWithResult: (_, __) {},
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Paste a list'),
            leading:
                results == null ? null : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, true)),
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            if (results == null) ...[
              const _InfoBox('One person per line, copied from a spreadsheet or typed:\n'
                  'Name, Email, Role, Job title, Department, Manager\n'
                  'Only the name is needed. Role is Employee, Manager or Admin. '
                  'Manager is the name or email of someone already on the team.'),
              const SizedBox(height: 14),
              TextField(
                controller: _text,
                minLines: 8,
                maxLines: 20,
                decoration: const InputDecoration(
                  hintText:
                      'Ada Obi, ada@acme.com, Manager, Sales lead, Sales\nTunde Bello, tunde@acme.com, Employee, Account manager, Sales, Ada Obi',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy || _parse().isEmpty ? null : _go,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.group_add_rounded),
                label: Text('Add ${_parse().length} ${_parse().length == 1 ? 'person' : 'people'}'),
              ),
            ] else ...[
              Text('${ok.length} added${results.length > ok.length ? ' · ${results.length - ok.length} not added' : ''}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text('Send each person their sign-in details. The one-time PINs are only shown now.',
                  style: TextStyle(color: AppColors.textDim)),
              const SizedBox(height: 12),
              if (ok.isNotEmpty)
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text: [
                      'Company code: ${ok.first.corpCode}',
                      for (final c in ok) '${c.member.fullName} · Employee ID ${c.member.employeeId} · one-time PIN ${c.tempPin}',
                    ].join('\n')));
                    toast(context, 'Copied everyone’s sign-in details', icon: Icons.copy_rounded);
                  },
                  icon: const Icon(Icons.copy_all_rounded),
                  label: const Text('Copy all sign-in details'),
                ),
              const SizedBox(height: 8),
              for (final (c, err, name) in results)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(c != null ? Icons.check_circle_rounded : Icons.error_rounded,
                      color: c != null ? AppColors.success : AppColors.danger),
                  title: Text(name),
                  subtitle: Text(c != null ? '${c.member.employeeId} · PIN ${c.tempPin}' : err ?? 'Not added',
                      style: c != null ? AppType.mono(13) : null),
                  trailing: c == null
                      ? null
                      : IconButton(
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: c.shareText));
                            toast(context, 'Copied ${name.split(' ').first}’s sign-in details', icon: Icons.copy_rounded);
                          },
                        ),
                ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
            ],
          ]),
        ),
      ),
    );
  }
}

// ---- sign-in details to hand over ----

Future<void> showCredentials(BuildContext context, List<MemberCredentials> creds) => showDialog<void>(
      context: context,
      builder: (d) {
        final c = creds.first;
        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 110, child: Text(k, style: const TextStyle(color: AppColors.textDim))),
                Expanded(child: SelectableText(v, style: AppType.mono(17))),
              ]),
            );
        return AlertDialog(
          icon: const Icon(Icons.key_rounded, size: 30),
          title: Text('${c.member.fullName.split(' ').first}’s sign-in details'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            row('Company code', c.corpCode),
            row('Employee ID', c.member.employeeId),
            row('One-time PIN', c.tempPin),
            const SizedBox(height: 12),
            Text(
              c.member.email != null
                  ? 'If they sign up with ${c.member.email}, they can also just tap Join. '
                      'The PIN is only shown now, so copy it before closing.'
                  : 'They’ll choose their own PIN after signing in. The PIN is only shown now, so copy it before closing.',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textDim),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: c.shareText));
                toast(d, 'Copied. Paste it into WhatsApp, SMS or email.', icon: Icons.copy_rounded);
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy message'),
            ),
          ],
        );
      },
    );

// ---- company settings ----

class _CompanySettings extends StatefulWidget {
  const _CompanySettings({required this.o});
  final OrgOverview o;

  @override
  State<_CompanySettings> createState() => _CompanySettingsState();
}

class _CompanySettingsState extends State<_CompanySettings> {
  late final _name = TextEditingController(text: widget.o.org.name);
  late final _disclosure = TextEditingController(text: widget.o.org.disclosure);
  late bool _announce = widget.o.announce;
  late bool _ring = widget.o.offDutyRings;
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).backend!.updateOrg({
        'name': _name.text.trim(),
        if (_disclosure.text.trim().length >= 10) 'recording_disclosure': _disclosure.text.trim(),
        'announce_recording': _announce,
        'off_duty_policy': _ring ? 'ring' : 'voicemail',
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SheetTitle(Icons.settings_rounded, 'Company settings', 'Applies to everyone in Work mode.'),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Company name')),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Announce recording on work calls'),
          subtitle: const Text('Commit Call tells both sides the call is recorded.'),
          value: _announce,
          onChanged: (v) => setState(() => _announce = v),
        ),
        if (_announce)
          TextField(
            controller: _disclosure,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'What it says'),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ring staff who are off duty'),
          subtitle: const Text('Off: work calls to someone in Personal mode go to their missed calls instead.'),
          value: _ring,
          onChanged: (v) => setState(() => _ring = v),
        ),
        _Error(_error),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ]);
}
