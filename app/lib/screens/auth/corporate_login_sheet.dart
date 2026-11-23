import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart' show navigatorKey;
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../team/company_screens.dart';

/// Corporate sign-in: company code + employee ID + PIN on a custom keypad.
/// Returns true when the user is now in Work mode.
Future<bool> showCorporateLogin(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _CorporateLoginSheet(),
  );
  return ok ?? false;
}

class _CorporateLoginSheet extends StatefulWidget {
  const _CorporateLoginSheet();

  @override
  State<_CorporateLoginSheet> createState() => _CorporateLoginSheetState();
}

class _CorporateLoginSheetState extends State<_CorporateLoginSheet> {
  final _code = TextEditingController();
  final _emp = TextEditingController();
  String _pin = '';
  bool _busy = false;
  String? _error;
  bool _onPin = false;
  late final Future<List<OrgInvite>> _invites = AppScope.read(context).backend!.invites().catchError((_) => <OrgInvite>[]);

  /// After entering Work mode: a one-time PIN from the admin must be replaced straight away.
  void _afterWork() {
    final app = AppScope.read(context);
    Navigator.pop(context, true);
    final ctx = navigatorKey.currentContext;
    if (ctx != null && (app.session?.membership?.mustChangePin ?? false)) {
      showChangePin(ctx, forced: true);
    }
  }

  Future<void> _join(OrgInvite invite) async {
    if (await showJoinInvite(context, invite) && mounted) _afterWork();
  }

  Future<void> _register() async {
    if (!await showRegisterCompany(context) || !mounted) return;
    Navigator.pop(context, true);
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const TeamAdminScreen(welcome: true)));
  }

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).corporateLogin(_code.text.trim(), _emp.text.trim(), _pin);
    if (!mounted) return;
    if (err == null) {
      HapticFeedback.mediumImpact();
      _afterWork();
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _busy = false;
        _error = err;
        _pin = '';
      });
    }
  }

  void _key(String k) {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '⌫') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 8) {
        _pin += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const p = ModePalette.corporate;
    final t = Theme.of(context).textTheme;
    return Theme(
      data: buildTheme(p),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          // Scrolls instead of overflowing on short windows / landscape phones.
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(gradient: LinearGradient(colors: p.gradient), borderRadius: BorderRadius.circular(13)),
                  child: Icon(Icons.work_rounded, color: p.onAccent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Switch to Work', style: t.titleLarge),
                    Text('Sign in with your corporate ID', style: t.bodyMedium),
                  ]),
                ),
              ]),
              const SizedBox(height: 22),
              if (!_onPin) ...[
                FutureBuilder<List<OrgInvite>>(
                  future: _invites,
                  builder: (context, snap) => Column(children: [
                    for (final i in snap.data ?? const <OrgInvite>[])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Material(
                          color: p.accentSoft,
                          borderRadius: BorderRadius.circular(16),
                          child: ListTile(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            leading: Icon(Icons.mark_email_unread_rounded, color: p.accent),
                            title: Text('You’ve been added to ${i.organization}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('${i.title ?? 'Team member'} · tap to join, no codes needed'),
                            trailing: FilledButton(onPressed: () => _join(i), child: const Text('Join')),
                            onTap: () => _join(i),
                          ),
                        ),
                      ),
                    if ((snap.data ?? const []).isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('or sign in with your company code', style: TextStyle(color: AppColors.textDim, fontSize: 13)),
                      ),
                  ]),
                ),
                TextField(
                  controller: _code,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Company code', prefixIcon: Icon(Icons.apartment_rounded)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _emp,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Employee ID', prefixIcon: Icon(Icons.badge_rounded)),
                  onSubmitted: (_) => setState(() => _onPin = true),
                ),
                const SizedBox(height: 16),
                _Notice(),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    if (_code.text.trim().isEmpty || _emp.text.trim().isEmpty) {
                      setState(() => _error = 'Enter your company code and employee ID');
                      return;
                    }
                    FocusScope.of(context).unfocus();
                    setState(() {
                      _onPin = true;
                      _error = null;
                    });
                  },
                  child: const Text('Continue'),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: _register,
                  icon: const Icon(Icons.domain_add_rounded, size: 18),
                  label: const Text('New company? Register it here'),
                ),
              ] else ...[
                Center(child: Text('${_code.text.toUpperCase()} · ${_emp.text.toUpperCase()}', style: t.bodyMedium)),
                const SizedBox(height: 14),
                Center(child: Text('Enter your PIN', style: t.titleMedium)),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_pin.length < 4 ? 4 : _pin.length, (i) {
                    final filled = i < _pin.length;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.symmetric(horizontal: 9),
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled ? p.accent : Colors.transparent,
                        border: Border.all(color: filled ? p.accent : AppColors.textFaint, width: 2),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 18),
                if (_busy) const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
                _Keypad(onKey: _key),
                const SizedBox(height: 10),
                FilledButton(onPressed: _pin.length >= 4 && !_busy ? _submit : null, child: const Text('Sign in')),
                TextButton(onPressed: () => setState(() => _onPin = false), child: const Text('Change company or ID')),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: ModePalette.corporate.accentSoft, borderRadius: BorderRadius.circular(14)),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_rounded, size: 18, color: AppColors.warning),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Personal calls are only recorded temporarily for extraction of commitments and thereafter deleted.',
              style: TextStyle(fontSize: 13, color: AppColors.text, height: 1.4),
            ),
          ),
        ]),
      );
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey});
  final ValueChanged<String> onKey;

  @override
  Widget build(BuildContext context) {
    // Fixed-size keys: the pad keeps its proportions on any sheet width (phone, tablet, desktop).
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', '⌫'],
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final k in row)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: k.isEmpty
                      ? null
                      : Material(
                          color: k == '⌫' ? Colors.transparent : AppColors.surfaceHigh,
                          shape: const CircleBorder(side: BorderSide(color: AppColors.outline, width: .8)),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => onKey(k),
                            child: Center(
                              child: k == '⌫'
                                  ? const Icon(Icons.backspace_outlined, color: AppColors.textDim, semanticLabel: 'Delete')
                                  : Text(k, style: AppType.mono(24)),
                            ),
                          ),
                        ),
                ),
              ),
          ]),
        ),
    ]);
  }
}
