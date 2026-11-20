package com.releep.releep_hband_sdk.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Notification channels + builders for the guard service and emergency alerts. */
object GuardNotifications {

    const val SERVICE_CHANNEL = "hband_guard_service"
    const val ALERT_CHANNEL = "hband_sos_alerts"
    const val SERVICE_NOTIFICATION_ID = 0x4842

    /** Intent extra set when the app is opened from an emergency notification. */
    const val EXTRA_EMERGENCY_EVENT_ID = "hband_emergency_event_id"

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(SERVICE_CHANNEL, "Watch guard", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Keeps the watch connection alive" }
        )
        nm.createNotificationChannel(
            NotificationChannel(ALERT_CHANNEL, "SOS alerts", NotificationManager.IMPORTANCE_HIGH)
                .apply {
                    description = "Emergency alerts from the watch"
                    enableVibration(true)
                }
        )
    }

    private fun launchIntent(context: Context, eventId: String?): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (eventId != null) intent.putExtra(EXTRA_EMERGENCY_EVENT_ID, eventId)
        return PendingIntent.getActivity(
            context,
            eventId?.hashCode() ?: 1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun builder(context: Context, channel: String): Notification.Builder {
        ensureChannels(context)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
    }

    private fun smallIcon(context: Context): Int =
        context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_sys_data_bluetooth

    fun serviceNotification(context: Context, text: String): Notification =
        builder(context, SERVICE_CHANNEL)
            .setSmallIcon(smallIcon(context))
            .setContentTitle("Watch guard")
            .setContentText(text)
            .setContentIntent(launchIntent(context, null))
            .setOngoing(true)
            .build()

    /** High-priority, full-screen-intent notification so the alert shows on the lock screen. */
    fun postEmergency(context: Context, eventId: String, title: String, text: String) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val pending = launchIntent(context, eventId)
        val notification = builder(context, ALERT_CHANNEL)
            .setSmallIcon(smallIcon(context))
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pending)
            .setFullScreenIntent(pending, true)
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .apply {
                @Suppress("DEPRECATION")
                setPriority(Notification.PRIORITY_MAX)
            }
            .build()
        try {
            nm.notify(eventId.hashCode(), notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted — the in-app alert still fires.
        }
    }
}
