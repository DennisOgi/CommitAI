package com.commitai.commit_ai

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager

/**
 * Phone-call sounds and the incoming-call alert:
 * - incoming: the user's ringtone + vibration (respecting silent / vibrate mode) and a
 *   full-screen "Incoming call" notification that wakes the screen and shows over the lock screen;
 * - outgoing: the standard ringback tone through the earpiece while the other phone rings.
 */
object CallAlerts {
    private const val CHANNEL = "commitai_incoming_calls"
    private const val NOTIFICATION_ID = 4202
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var ringback: ToneGenerator? = null

    fun startRinging(activity: Activity, caller: String, work: Boolean) {
        stopRinging(activity)
        val ctx = activity.applicationContext
        val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = audio.ringerMode
        if (mode == AudioManager.RINGER_MODE_NORMAL) {
            try {
                val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ringtone = RingtoneManager.getRingtone(ctx, uri)?.apply {
                    audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
                    play()
                }
            } catch (_: Exception) {
            }
        }
        if (mode != AudioManager.RINGER_MODE_SILENT) {
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            val pattern = longArrayOf(0, 900, 1100)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(pattern, 0)
                }
            } catch (_: Exception) {
            }
        }
        showOverLockScreen(activity, true)
        postNotification(ctx, caller, work)
    }

    fun stopRinging(activity: Activity) {
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
        activity.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        showOverLockScreen(activity, false)
    }

    fun startRingback() {
        stopRingback()
        try {
            ringback = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70).apply {
                startTone(ToneGenerator.TONE_SUP_RINGTONE)
            }
        } catch (_: Exception) {
        }
    }

    fun stopRingback() {
        try {
            ringback?.stopTone()
            ringback?.release()
        } catch (_: Exception) {
        }
        ringback = null
    }

    private fun showOverLockScreen(activity: Activity, on: Boolean) {
        activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                activity.setShowWhenLocked(on)
                activity.setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
            }
        }
    }

    private fun postNotification(ctx: Context, caller: String, work: Boolean) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Silent channel: the looping ringtone above is the sound, like a real call.
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
        }
        val open = PendingIntent.getActivity(
            ctx, 1,
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(ctx).setPriority(Notification.PRIORITY_MAX)
        }
        val n = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(caller)
            .setContentText(if (work) "Incoming work call · Commit AI" else "Incoming call · Commit AI")
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(true)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            .build()
        try {
            nm.notify(NOTIFICATION_ID, n)
        } catch (_: SecurityException) {
        }
    }
}
