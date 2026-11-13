/// Build-time configuration:
///
///   flutter run \
///     --dart-define=API_URL=https://api.your-domain.com \
///     --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=...
///
/// With no API_URL the app runs fully offline in demo mode, with a
/// simulated company, simulated calls and simulated AI.
class AppConfig {
  static const apiUrl = String.fromEnvironment('API_URL');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const pushEnabled = bool.fromEnvironment('PUSH_ENABLED');

  /// Legal pages linked from sign-up. Required for store submission of an app that records calls.
  static const termsUrl = String.fromEnvironment('TERMS_URL');
  static const privacyUrl = String.fromEnvironment('PRIVACY_URL');

  /// Show the seeded dev-server users on the sign-in screen (servers with DEV_AUTH=true).
  /// On by default in debug builds, off in release builds unless DEV_LOGIN=true.
  static const devLogin = bool.fromEnvironment('DEV_LOGIN', defaultValue: !bool.fromEnvironment('dart.vm.product'));

  static bool get demoMode => apiUrl.isEmpty;
  static bool get supabaseEnabled => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
