package com.commitai.commit_ai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * "Ready for calls": keeps Commit Call running while it's in the background so incoming calls
 * still ring when the user is in WhatsApp or another app. Without it Android freezes the app a
 * few seconds after it leaves the screen and it can't notice incoming calls until reopened.
 * (With Firebase push configured, push wakes the app instead and this isn't needed.)
 */
class StandbyService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Ready for calls", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Keeps Commit Call able to ring when it's in the background"
                    setShowBadge(false)
                }
            )
        }
        val open = PendingIntent.getActivity(
            this, 2,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        }
        val n = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Commit Call")
            .setContentText("Ready for calls")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(ID, n)
            }
        } catch (_: Exception) {
            stopSelf()
        }
        return START_STICKY
    }

    companion object {
        const val CHANNEL = "commitai_standby"
        const val ID = 4203
    }
}
