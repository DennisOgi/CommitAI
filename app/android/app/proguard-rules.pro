# Daily / WebRTC use JNI and reflection; keep them intact in minified release builds.
-keep class co.daily.** { *; }
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
-keep class com.hiennv.flutter_callkit_incoming.** { *; }
-dontwarn com.google.android.play.core.**
