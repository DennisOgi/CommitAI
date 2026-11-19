package com.commitai.commit_ai

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "commitai/call_service").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // Keeps the microphone alive while a call is on and the screen is locked / app in background.
                    "start" -> {
                        val intent = Intent(this, CallService::class.java)
                        intent.putExtra("peer", call.argument<String>("peer") ?: "")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    }
                    "stop" -> stopService(Intent(this, CallService::class.java))
                    "ring" -> CallAlerts.startRinging(
                        this,
                        call.argument<String>("caller") ?: "Incoming call",
                        call.argument<Boolean>("work") ?: false,
                    )
                    "stopRing" -> CallAlerts.stopRinging(this)
                    "ringback" -> CallAlerts.startRingback()
                    "stopRingback" -> CallAlerts.stopRingback()
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(true)
            } catch (e: Exception) {
                result.error("call_service", e.message, null)
            }
        }
    }

    override fun onDestroy() {
        CallAlerts.stopRinging(this)
        CallAlerts.stopRingback()
        super.onDestroy()
    }
}
