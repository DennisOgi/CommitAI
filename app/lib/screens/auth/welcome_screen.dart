import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// First screen for signed-out users: what Commit AI is, then a clear way in.
/// Personal identity is an email account; the corporate identity is layered on later
/// from the mode switch.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _busy = false;
  AuthNotice? _notice;

  // Seeded users of a local dev server (DEV_AUTH=true). Never shown in release builds.
  static const _devUsers = {
    'Ada Okafor · Account Manager': '00000000-0000-4000-a000-000000000001',
    'Ngozi Adeyemi · Head of Sales': '00000000-0000-4000-a000-000000000004',
    'Ibrahim Bello · Client': '00000000-0000-4000-a000-000000000006',
    'Chidi Nwosu · Friend': '00000000-0000-4000-a000-000000000005',
  };

  Future<void> _run(Future<AuthNotice?> Function() f) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    final n = await f();
    if (mounted) {
      setState(() {
        _busy = false;
        _notice = n;
      });
    }
  }

  void _openAuth(bool signUp) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AuthScreen(signUp: signUp)));

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: _Glow(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: CustomScrollView(slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
                  sliver: SliverList.list(children: [
                    const Align(alignment: Alignment.centerLeft, child: CommitWordmark(height: 44)),
                    const SizedBox(height: 36),
                    Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'Every commitment\nmade on a call,\n'),
                        TextSpan(
                          text: 'kept.',
                          style: AppType.display(44, weight: FontWeight.w500, style: FontStyle.italic, color: ModePalette.corporate.accent),
                        ),
                      ]),
                      style: AppType.display(44, weight: FontWeight.w400),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Call clients from one app, over the internet or to any mobile or landline. '
                      'Commit AI records work calls, catches what was agreed, and keeps your team in the loop. '
                      'Personal calls stay personal.',
                      style: t.bodyLarge?.copyWith(color: AppColors.textDim),
                    ),
                    const SizedBox(height: 24),
                    const _FeatureRow(n: '01', text: 'One phone, two identities: Personal and Work'),
                    const _FeatureRow(n: '02', text: 'AI pulls out commitments, deadlines and the exact quote'),
                    const _FeatureRow(n: '03', text: 'Managers see what’s due, what slipped, and who to nudge'),
                    const SizedBox(height: 28),
                  ]),
                ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (AppConfig.demoMode)
                        ..._demo(app)
                      else if (AppConfig.supabaseEnabled) ...[
                        FilledButton(onPressed: () => _openAuth(true), child: const Text('Create account')),
                        const SizedBox(height: 10),
                        OutlinedButton(onPressed: () => _openAuth(false), child: const Text('I already have an account')),
                        const SizedBox(height: 14),
                        const LegalLine(),
                      ] else if (AppConfig.devLogin)
                        ..._dev(app)
                      else
                        const Text(
                          'Sign-in isn’t configured in this build. It needs SUPABASE_URL and SUPABASE_ANON_KEY.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.danger),
                        ),
                      if (_notice != null) ...[const SizedBox(height: 12), NoticeText(_notice!)],
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _demo(AppState app) => [
        Text('EXPLORE THE DEMO AS', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 10),
        _PersonaCard(
          name: 'Ada Okafor',
          role: 'Account Manager · makes client calls',
          busy: _busy,
          onTap: () => _run(() async {
            await app.startDemo('ada');
            return null;
          }),
        ),
        const SizedBox(height: 10),
        _PersonaCard(
          name: 'Ngozi Adeyemi',
          role: 'Head of Sales · sees the team dashboard',
          busy: _busy,
          onTap: () => _run(() async {
            await app.startDemo('ngozi');
            return null;
          }),
        ),
        const SizedBox(height: 14),
        const Text('Work mode: company LUMEN · ID EMP-1042 (Ada) or EMP-1001 (Ngozi) · PIN 1234',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
      ];

  List<Widget> _dev(AppState app) => [
        Text('DEV SERVER · SIGN IN AS', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 10),
        for (final e in _devUsers.entries) ...[
          _PersonaCard(
            name: e.key.split(' · ').first,
            role: e.key.split(' · ').last,
            busy: _busy,
            onTap: () => _run(() async {
              try {
                await app.startDev(e.value);
                return null;
              } catch (err) {
                return const AuthNotice('Couldn’t reach ${AppConfig.apiUrl}. Is the server running?');
              }
            }),
          ),
          const SizedBox(height: 10),
        ],
      ];
}

/// Email sign-in / sign-up, with password reset. One focused screen, keyboard-friendly,
/// password-manager aware.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.signUp});
  final bool signUp;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late bool _signUp = widget.signUp;
  bool _busy = false;
  bool _showPassword = false;
  AuthNotice? _notice;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    TextInput.finishAutofillContext();
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _notice = null;
    });
    final n = _signUp
        ? await app.signUpWithEmail(_name.text.trim(), _email.text.trim(), _password.text, phone: _phone.text.trim())
        : await app.signInWithEmail(_email.text.trim(), _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = n;
    });
    // Signed in: the app's root swaps to onboarding / home; drop this route.
    if (n == null && Navigator.of(context).canPop()) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (!_emailRe.hasMatch(email)) {
      setState(() => _notice = const AuthNotice('Enter your email above, then tap “Forgot password?” again.'));
      return;
    }
    setState(() => _busy = true);
    final n = await AppScope.read(context).sendPasswordReset(email);
    if (mounted) {
      setState(() {
        _busy = false;
        _notice = n;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Column(
                      key: ValueKey(_signUp),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_signUp ? 'Create your account' : 'Welcome back', style: AppType.display(32, weight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        Text(
                          _signUp
                              ? 'This is your personal account. You’ll join your company’s workspace afterwards with your corporate ID.'
                              : 'Sign in with the email you used to create your account.',
                          style: t.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (_signUp) ...[
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.name],
                      decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline_rounded)),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        hintText: 'e.g. 0803 123 4567',
                        helperText: 'Friends who have your number will see you on Commit AI',
                        prefixIcon: Icon(Icons.phone_iphone_rounded),
                      ),
                      validator: (v) {
                        final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                        if (digits.isEmpty) return 'Enter your phone number';
                        return digits.length < 10 || digits.length > 15 ? 'That number doesn’t look complete' : null;
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email_rounded)),
                    validator: (v) => _emailRe.hasMatch((v ?? '').trim()) ? null : 'Enter a valid email address',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: !_showPassword,
                    textInputAction: TextInputAction.done,
                    autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: _signUp ? 'At least 8 characters' : null,
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        tooltip: _showPassword ? 'Hide password' : 'Show password',
                        icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                        onPressed: () => setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                    validator: (v) {
                      final p = v ?? '';
                      if (p.isEmpty) return 'Enter your password';
                      if (_signUp && p.length < 8) return 'Use at least 8 characters';
                      return null;
                    },
                  ),
                  if (!_signUp)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(onPressed: _busy ? null : _forgot, child: const Text('Forgot password?')),
                    )
                  else
                    const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary))
                        : Text(_signUp ? 'Create account' : 'Sign in'),
                  ),
                  if (_notice != null) ...[const SizedBox(height: 14), NoticeText(_notice!)],
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _signUp = !_signUp;
                              _notice = null;
                            }),
                    child: Text(_signUp ? 'Already have an account? Sign in' : 'New to Commit AI? Create an account'),
                  ),
                  if (_signUp) ...[const SizedBox(height: 6), const LegalLine()],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An error (red) or a neutral notice (e.g. "check your inbox").
class NoticeText extends StatelessWidget {
  const NoticeText(this.notice, {super.key});
  final AuthNotice notice;

  @override
  Widget build(BuildContext context) {
    final color = notice.isError ? AppColors.danger : AppColors.success;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(notice.isError ? Icons.error_outline_rounded : Icons.mark_email_read_outlined, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(notice.text, style: TextStyle(color: color, fontWeight: FontWeight.w600, height: 1.35))),
        ]),
      ),
    );
  }
}

/// "By continuing you agree to the Terms and Privacy Policy", when the build has those URLs.
class LegalLine extends StatelessWidget {
  const LegalLine({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppConfig.termsUrl.isEmpty && AppConfig.privacyUrl.isEmpty) return const SizedBox.shrink();
    const style = TextStyle(fontSize: 12, color: AppColors.textFaint, height: 1.4);
    final link = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700);
    Widget a(String label, String url) => InkWell(
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Text(label, style: link),
        );
    return Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
      const Text('By continuing you agree to the ', style: style),
      if (AppConfig.termsUrl.isNotEmpty) a('Terms', AppConfig.termsUrl),
      if (AppConfig.termsUrl.isNotEmpty && AppConfig.privacyUrl.isNotEmpty) const Text(' and ', style: style),
      if (AppConfig.privacyUrl.isNotEmpty) a('Privacy Policy', AppConfig.privacyUrl),
      const Text('.', style: style),
    ]);
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned(
          top: -120,
          right: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                  colors: [ModePalette.corporate.glow.withValues(alpha: .32), ModePalette.corporate.glow.withValues(alpha: 0)]),
            ),
          ),
        ),
        Positioned(
          top: 220,
          left: -140,
          child: Container(
            width: 340,
            height: 340,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                  colors: [ModePalette.personal.glow.withValues(alpha: .22), ModePalette.personal.glow.withValues(alpha: 0)]),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ]);
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.n, required this.text});
  final String n;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.outline, width: .8))),
        child: Row(children: [
          SizedBox(width: 38, child: Text(n, style: AppType.mono(12, color: ModePalette.corporate.accent, weight: FontWeight.w600))),
          Expanded(child: Text(text, style: const TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w500))),
        ]),
      );
}

class _PersonaCard extends StatelessWidget {
  const _PersonaCard({required this.name, required this.role, required this.onTap, required this.busy});
  final String name;
  final String role;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Avatar(name: name),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(role, style: Theme.of(context).textTheme.bodyMedium),
                ]),
              ),
              const Icon(Icons.arrow_forward_rounded, color: AppColors.textFaint),
            ]),
          ),
        ),
      );
}
