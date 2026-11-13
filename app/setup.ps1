# Commit AI — one-time platform setup (Windows PowerShell).
# Generates the android/ and ios/ folders around the existing lib/ and applies
# the permissions and settings a calling app needs.
#
#   cd D:\CommitAI\app
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "1/5  flutter create (existing files are kept)" -ForegroundColor Cyan
flutter create --platforms android,ios --org com.commitai --project-name commit_ai . | Out-Null

function Patch($path, $find, $replace) {
  if (-not (Test-Path $path)) { Write-Warning "missing $path"; return }
  $text = Get-Content $path -Raw
  if ($text.Contains($replace)) { return }
  if (-not $text.Contains($find)) { Write-Warning "anchor not found in $path : $find"; return }
  # Replace the FIRST occurrence only. (Replacing all of them put the Info.plist keys into
  # every nested <dict>, which App Store validation rejects.)
  $i = $text.IndexOf($find)
  $text = $text.Substring(0, $i) + $replace + $text.Substring($i + $find.Length)
  Set-Content -Path $path -Value $text -NoNewline
}

Write-Host "2/5  Android permissions" -ForegroundColor Cyan
$manifest = "android/app/src/main/AndroidManifest.xml"
$perms = @"
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL"/>
    <uses-permission android:name="android.permission.USE_BIOMETRIC"/>
"@
Patch $manifest '<manifest xmlns:android="http://schemas.android.com/apk/res/android">' $perms
Patch $manifest 'android:label="commit_ai"' 'android:label="Commit AI"'

Write-Host "3/5  Android minSdk 24 + FlutterFragmentActivity (needed by local_auth)" -ForegroundColor Cyan
Patch "android/app/build.gradle.kts" "minSdk = flutter.minSdkVersion" "minSdk = 24"
Patch "android/app/build.gradle" "minSdkVersion flutter.minSdkVersion" "minSdkVersion 24"
$activity = Get-ChildItem -Recurse -Path android/app/src/main -Filter MainActivity.kt | Select-Object -First 1
if ($activity) {
  Patch $activity.FullName "import io.flutter.embedding.android.FlutterActivity" "import io.flutter.embedding.android.FlutterFragmentActivity"
  Patch $activity.FullName "class MainActivity : FlutterActivity()" "class MainActivity : FlutterFragmentActivity()"
}

Write-Host "4/5  iOS Info.plist + deployment target" -ForegroundColor Cyan
$plist = "ios/Runner/Info.plist"
$keys = @"
<dict>
	<key>NSMicrophoneUsageDescription</key>
	<string>Commit AI uses the microphone for your calls.</string>
	<key>NSFaceIDUsageDescription</key>
	<string>Confirm it's you before switching to Work mode.</string>
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
		<string>voip</string>
		<string>remote-notification</string>
	</array>
"@
Patch $plist "<dict>" $keys
if (Test-Path "ios/Podfile") {
  Patch "ios/Podfile" "# platform :ios, '12.0'" "platform :ios, '14.0'"
  Patch "ios/Podfile" "# platform :ios, '13.0'" "platform :ios, '14.0'"
}

Write-Host "5/5  flutter pub get" -ForegroundColor Cyan
flutter pub get

Write-Host ""
Write-Host "Done. Try the offline demo:" -ForegroundColor Green
Write-Host "   flutter run"
Write-Host "Against your server:" -ForegroundColor Green
Write-Host "   flutter run --dart-define=API_URL=http://10.0.2.2:8000"
