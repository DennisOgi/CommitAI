import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../call/call_controller.dart';
import '../core/config.dart';
import '../core/theme.dart';
import '../data/api_backend.dart';
import '../data/backend.dart';
import '../data/demo_backend.dart';
import '../models/models.dart';
import '../services/reminder_service.dart';

enum AuthStatus { loading, signedOut, offline, onboarding, ready }

/// Result of a sign-in / sign-up attempt: an error to show, or a neutral notice.
class AuthNotice {
  const AuthNotice(this.text, {this.isError = true});
  final String text;
  final bool isError;
}

/// Turns auth / network failures into sentences people can act on.
String friendlyAuthError(Object e) {
  // Our own server's errors already carry a precise, readable message (including
  // "Can't reach the Commit AI server" when it's down), so don't second-guess them.
  if (e is ApiException) return e.message;
  final raw = e is sb.AuthException ? e.message : e.toString();
  final m = raw.toLowerCase();
  if (m.contains('invalid login credentials')) return 'That email and password don’t match. Check them and try again.';
  if (m.contains('already registered') || m.contains('already been registered')) {
    return 'An account with this email already exists. Sign in instead, or reset your password.';
  }
  if (m.contains('email not confirmed')) return 'Confirm your email first. We sent you a link.';
  if (m.contains('password should be') || m.contains('weak password')) return 'Choose a stronger password: at least 8 characters.';
  if (m.contains('rate limit') || m.contains('too many')) return 'Too many attempts. Wait a minute and try again.';
  if (m.contains('socket') || m.contains('failed host lookup') || m.contains('connection') || m.contains('network')) {
    return 'You seem to be offline. Check your connection and try again.';
  }
  return 'Something went wrong. Please try again.';
}

sealed class ModeSwitchResult {}

class NeedsCorporateLogin extends ModeSwitchResult {}

class Switched extends ModeSwitchResult {
  Switched(this.held);
  final List<HeldCall> held;
}

class SwitchFailed extends ModeSwitchResult {
  SwitchFailed(this.message);
  final String message;
}

class AppState extends ChangeNotifier {
  AuthStatus status = AuthStatus.loading;
  Backend? backend;
  Session? session;
  CallController? calls;
  bool switching = false;

  /// Set by onboarding when the user chose "Enter my corporate ID": the home screen
  /// opens the corporate sign-in once it appears.
  bool pendingWorkSetup = false;

  /// Bumped whenever data may have changed (mode switch, call ended, review saved).
  int dataVersion = 0;

  /// Latest incoming call waiting for an answer.
  final ValueNotifier<IncomingCall?> incoming = ValueNotifier(null);

  String? _corpSession;
  StreamSubscription<IncomingCall>? _incomingSub;
  SharedPreferences? _prefs;
  Timer? _ringPoll;
  final Set<String> _seenRings = {};

  /// The corporate session is a bearer credential, so it lives in the
  /// platform keystore (Keychain / Android Keystore), not SharedPreferences.
  static const _secure = FlutterSecureStorage();
  static const _corpKey = 'corp_session';

  Future<String?> _readCorp() async {
    try {
      return await _secure.read(key: _corpKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCorp(String? value) async {
    try {
      if (value == null) {
        await _secure.delete(key: _corpKey);
      } else {
        await _secure.write(key: _corpKey, value: value);
      }
    } catch (_) {
      // Keystore unavailable: the session then only lives in memory.
    }
  }

  AppMode get mode => session?.mode ?? AppMode.personal;
  bool get corporate => mode == AppMode.corporate;
  /// Signed out and during onboarding the app wears the brand colour (saffron, as in the icon);
  /// once in, it follows the mode.
  ModePalette get palette => status != AuthStatus.ready || corporate ? ModePalette.corporate : ModePalette.personal;
  bool get isManager => corporate && (session?.membership?.isManager ?? false);
  bool get isDemo => backend is DemoBackend;
  String get firstName => (session?.profile.fullName ?? '').split(' ').first;

  Future<void> boot() async {
    _prefs = await SharedPreferences.getInstance();
    // One-time migration from the old plain-text location.
    if (_prefs!.getString('corp_session') case final legacy?) {
      await _writeCorp(legacy);
      await _prefs!.remove('corp_session');
    }
    _corpSession = await _readCorp();
    try {
      if (AppConfig.demoMode) {
        final persona = _prefs!.getString('demo_persona');
        if (persona != null) return await startDemo(persona);
      } else if (AppConfig.supabaseEnabled && sb.Supabase.instance.client.auth.currentSession != null) {
        return await _attach(_supabaseBackend());
      } else if (_prefs!.getString('dev_user') case final dev?) {
        return await startDev(dev);
      }
    } on ApiException catch (e) {
      if (e.status == 0 || e.status >= 500) {
        // Signed in, but the server is unreachable: don't throw the user out.
        status = AuthStatus.offline;
        notifyListeners();
        return;
      }
      // 401 / 404: the session is no longer valid.
      if (AppConfig.supabaseEnabled) await sb.Supabase.instance.client.auth.signOut().catchError((_) {});
    } catch (_) {
      // Fall through to sign-in.
    }
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  /// From the offline screen.
  Future<void> retryBoot() async {
    status = AuthStatus.loading;
    notifyListeners();
    await boot();
  }

  ApiBackend _supabaseBackend() => _apiBackend(() async => sb.Supabase.instance.client.auth.currentSession?.accessToken ?? '');

  ApiBackend _apiBackend(Future<String> Function() token) => ApiBackend(AppConfig.apiUrl, token);

  Future<void> startDemo(String persona) async {
    await _prefs?.setString('demo_persona', persona);
    await _attach(DemoBackend(persona: persona));
  }

  /// Local development against a DEV_AUTH server: "Bearer dev:<user id>".
  Future<void> startDev(String userId) async {
    await _prefs?.setString('dev_user', userId);
    await _attach(_apiBackend(() async => 'dev:$userId'));
  }

  Future<AuthNotice?> signInWithEmail(String email, String password) async {
    try {
      await sb.Supabase.instance.client.auth.signInWithPassword(email: email, password: password);
      await _attach(_supabaseBackend());
      return null;
    } catch (e) {
      return AuthNotice(friendlyAuthError(e));
    }
  }

  /// Signs the user straight in when the project doesn't require email confirmation;
  /// otherwise returns a notice asking them to confirm.
  Future<AuthNotice?> signUpWithEmail(String name, String email, String password) async {
    try {
      final r = await sb.Supabase.instance.client.auth.signUp(email: email, password: password, data: {'full_name': name});
      if (r.session == null) return AuthNotice('Check your inbox to confirm $email, then sign in.', isError: false);
      await _attach(_supabaseBackend());
      return null;
    } catch (e) {
      return AuthNotice(friendlyAuthError(e));
    }
  }

  Future<AuthNotice> sendPasswordReset(String email) async {
    try {
      await sb.Supabase.instance.client.auth.resetPasswordForEmail(email);
      return AuthNotice('If an account exists for $email, a reset link is on its way.', isError: false);
    } catch (e) {
      return AuthNotice(friendlyAuthError(e));
    }
  }

  String? get _userId => session?.profile.id;
  bool get _onboarded => _prefs?.getBool('onboarded:$_userId') ?? false;

  /// First run for this account is done (or skipped).
  Future<void> completeOnboarding() async {
    await _prefs?.setBool('onboarded:$_userId', true);
    status = AuthStatus.ready;
    notifyListeners();
  }

  Future<void> _attach(Backend b) async {
    backend = b;
    session = await b.me();
    calls?.dispose();
    calls = CallController(b, session!.profile.fullName);
    await _incomingSub?.cancel();
    _incomingSub = b.incoming.stream.listen((call) => incoming.value = call);
    _startRingPolling(b);
    unawaited(syncReminders());
    status = b is DemoBackend || _onboarded ? AuthStatus.ready : AuthStatus.onboarding;
    notifyListeners();
  }

  /// Without push (FCM) the app finds incoming calls by polling while it is open.
  void _startRingPolling(Backend b) {
    _ringPoll?.cancel();
    _seenRings.clear();
    if (b is DemoBackend || AppConfig.pushEnabled) return;
    _ringPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (backend != b || (calls?.busy ?? false) || incoming.value != null) return;
      try {
        for (final call in await b.ringing()) {
          if (_seenRings.add(call.callId)) b.incoming.add(call);
        }
      } catch (_) {
        // Offline or server restarting; try again on the next tick.
      }
    });
  }

  Future<void> signOut() async {
    if (corporate) await backend?.setMode(AppMode.personal).catchError((_) => <HeldCall>[]);
    await ReminderService.instance.clear();
    _ringPoll?.cancel();
    await _prefs?.remove('demo_persona');
    await _prefs?.remove('dev_user');
    await _writeCorp(null);
    _corpSession = null;
    if (AppConfig.supabaseEnabled) await sb.Supabase.instance.client.auth.signOut().catchError((_) {});
    await _incomingSub?.cancel();
    calls?.dispose();
    calls = null;
    backend = null;
    session = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  void refresh() {
    dataVersion++;
    notifyListeners();
    unawaited(syncReminders());
  }

  /// Re-schedule on-device deadline reminders for this mode's own commitments.
  Future<void> syncReminders() async {
    final b = backend;
    if (b == null || b is DemoBackend || !ReminderService.supported) return;
    try {
      await ReminderService.instance.sync(mode, await b.commitments());
    } catch (_) {
      // Offline: keep the reminders already scheduled.
    }
  }

  bool get recordsPersonalCalls => session?.profile.recordPersonalCalls ?? true;

  bool get discoverable => session?.profile.discoverable ?? true;

  /// The "Let people find me" switch.
  Future<String?> setDiscoverable(bool on) async {
    try {
      final saved = await backend!.setDiscoverable(on);
      session?.profile.discoverable = saved;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// The "Record my personal calls" switch.
  Future<String?> setRecordPersonalCalls(bool on) async {
    try {
      final saved = await backend!.setRecordPersonalCalls(on);
      session?.profile.recordPersonalCalls = saved;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// The mode toggle. Entering Work mode needs a corporate session; within its
  /// 12-hour window a biometric check replaces the PIN.
  Future<ModeSwitchResult> switchTo(AppMode target) async {
    if (target == mode || switching) return Switched(const []);
    if (calls?.busy ?? false) return SwitchFailed('Finish your current call before switching.');
    if (target == AppMode.corporate) {
      if (_corpSession == null) return NeedsCorporateLogin();
      // No biometric confirmation (cancelled, unavailable, not enrolled) → full corporate login.
      if (!await _confirmIdentity()) return NeedsCorporateLogin();
    }
    switching = true;
    notifyListeners();
    try {
      final held = await backend!.setMode(target, corpSession: _corpSession);
      session = await backend!.me();
      unawaited(syncReminders()); // the new mode has its own commitments
      return Switched(held);
    } on ApiException catch (e) {
      if (e.status == 401) {
        _corpSession = null;
        await _writeCorp(null);
        return NeedsCorporateLogin();
      }
      return SwitchFailed(e.message);
    } catch (e) {
      return SwitchFailed(e.toString());
    } finally {
      switching = false;
      dataVersion++;
      notifyListeners();
    }
  }

  Future<String?> corporateLogin(String code, String employeeId, String pin) =>
      _enterWork(() => backend!.corporateLogin(code, employeeId, pin));

  /// Register a company: the user becomes its admin, in Work mode.
  Future<String?> createCompany({required String name, required String pin, String? title}) =>
      _enterWork(() => backend!.createCompany(name: name, pin: pin, title: title));

  /// Accept an email invite with a PIN of the user's choosing.
  Future<String?> joinCompany(String membershipId, String pin) => _enterWork(() => backend!.joinCompany(membershipId, pin));

  Future<String?> changeWorkPin(String currentPin, String newPin) async {
    try {
      await backend!.changeWorkPin(currentPin, newPin);
      session?.membership?.mustChangePin = false;
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> _enterWork(Future<CorporateLoginResult> Function() go) async {
    try {
      final r = await go();
      _corpSession = r.corpSession;
      await _writeCorp(r.corpSession);
      session = r.session;
      dataVersion++;
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } on UnsupportedError catch (e) {
      return e.message ?? 'Not available in the demo.';
    } catch (e) {
      return e.toString();
    }
  }

  Future<bool> _confirmIdentity() async {
    if (isDemo) return true;
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) return false;
      return await auth.authenticate(
        localizedReason: 'Confirm it\'s you to switch to Work mode',
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return false; // fail closed: the corporate PIN is asked instead
    }
  }

  @override
  void dispose() {
    _ringPoll?.cancel();
    _incomingSub?.cancel();
    calls?.dispose();
    super.dispose();
  }
}

/// Makes [AppState] available to the tree; dependents rebuild on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;

  /// Read without subscribing (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
