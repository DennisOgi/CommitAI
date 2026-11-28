import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/backend.dart';
import 'screens/auth/onboarding_screen.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/call/incoming_call_screen.dart';
import 'screens/home/home_shell.dart';
import 'services/push_service.dart';
import 'state/app_state.dart';
import 'widgets/common.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class CommitApp extends StatefulWidget {
  const CommitApp({super.key});

  @override
  State<CommitApp> createState() => _CommitAppState();
}

class _CommitAppState extends State<CommitApp> {
  final state = AppState();
  Backend? _pushedFor;

  @override
  void initState() {
    super.initState();
    state.boot();
    state.incoming.addListener(_onIncoming);
    state.addListener(_onState);
  }

  void _onState() {
    final b = state.backend;
    if (b != null && b != _pushedFor) {
      _pushedFor = b;
      PushService.init(b).catchError((_) {});
    }
  }

  void _onIncoming() {
    final call = state.incoming.value;
    if (call == null) return;
    state.incoming.value = null;
    final ctx = navigatorKey.currentContext;
    if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.clearSnackBars(); // nothing may cover the call
    navigatorKey.currentState?.push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => IncomingCallScreen(call: call),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  void dispose() {
    state.incoming.removeListener(_onIncoming);
    state.removeListener(_onState);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          title: 'Commit Call',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: buildTheme(state.palette),
          themeAnimationDuration: const Duration(milliseconds: 450),
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: KeyedSubtree(
              key: ValueKey(state.status),
              child: switch (state.status) {
                AuthStatus.loading => const SplashScreen(),
                AuthStatus.signedOut => const WelcomeScreen(),
                AuthStatus.offline => const OfflineScreen(),
                AuthStatus.onboarding => const OnboardingScreen(),
                AuthStatus.ready => const HomeShell(),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown while the app restores the session. Matches the native launch screen
/// (ink background, the mark centred) so there is no visible jump.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CommitLogo(size: 96),
            const SizedBox(height: 20),
            // Same lettering as the native launch screen, so there's no visible jump.
            const Text('Commit Call',
                style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.3)),
            const SizedBox(height: 32),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                minHeight: 2,
                borderRadius: BorderRadius.circular(2),
                backgroundColor: AppColors.outline,
              ),
            ),
          ]),
        ),
      );
}

/// The server can't be reached while restoring a signed-in session. The user stays
/// signed in; they just retry.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: EmptyState(
            icon: Icons.wifi_off_rounded,
            title: 'Can’t reach Commit Call',
            body: 'Check your internet connection. You’re still signed in; we’ll pick up where you left off.',
            action: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                onPressed: app.retryBoot,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
              TextButton(onPressed: app.signOut, child: const Text('Sign out')),
            ]),
          ),
        ),
      ),
    );
  }
}

//// The Commit mark: the blue rounded square with the phone, as on the app icon.
class CommitLogo extends StatelessWidget {
  const CommitLogo({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Commit Call',
        image: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * .22),
            boxShadow: [BoxShadow(color: const Color(0xFF0046DC).withValues(alpha: .35), blurRadius: size * .35, offset: Offset(0, size * .08))],
          ),
          child: Image.asset('assets/branding/logo_mark.png', width: size, height: size, filterQuality: FilterQuality.medium),
        ),
      );
}

/// The horizontal "phone | Commit" logo.
class CommitWordmark extends StatelessWidget {
  const CommitWordmark({super.key, this.height = 40});
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Commit Call',
        image: true,
        child: Image.asset('assets/branding/logo_wordmark.png', height: height, filterQuality: FilterQuality.medium),
      );
}
