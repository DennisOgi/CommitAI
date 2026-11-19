package com.commitai.commit_ai

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Keeps the microphone alive while a call is on and the screen is locked / app in background.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "commitai/call_service").setMethodCallHandler { call, result ->
            val intent = Intent(this, CallService::class.java)
            try {
                when (call.method) {
                    "start" -> {
                        intent.putExtra("peer", call.argument<String>("peer") ?: "")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("call_service", e.message, null)
            }
        }
    }
}
