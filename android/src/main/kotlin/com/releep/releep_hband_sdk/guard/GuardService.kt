package com.releep.releep_hband_sdk.guard

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import com.releep.releep_hband_sdk.core.GuardNotifications
import com.releep.releep_hband_sdk.core.HBandManager
import com.releep.releep_hband_sdk.core.WatchSession

/**
 * Foreground service (type connectedDevice) that keeps the watch link, the
 * SOS frame poller and the reconnect watchdog alive in the background —
 * the standard companion-app pattern. START_STICKY + restart on swipe-away.
 */
class GuardService : Service() {

    companion object {
        private const val TAG = "HBandGuard"

        fun start(context: Context) {
            val intent = Intent(context, GuardService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // e.g. ForegroundServiceStartNotAllowedException from background on Android 12+
                Log.e(TAG, "start failed: $e")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GuardService::class.java))
        }

        @Volatile
        var isRunning = false
            private set
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        goForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        if (!WatchSession.isConfigured(this) || !WatchSession.isGuardEnabled(this)) {
            // Nothing to guard (forgotten watch / guard switched off).
            stopSelf()
            return START_NOT_STICKY
        }
        HBandManager.startMonitoring(this)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The user swiped the app away: bring the guard back and schedule a
        // best-effort backup restart. Non-exact alarm — setExact needs the
        // SCHEDULE_EXACT_ALARM permission (crashed the original demo).
        try {
            if (WatchSession.isConfigured(this) && WatchSession.isGuardEnabled(this)) {
                start(this)
                scheduleRestartAlarm()
            }
        } catch (_: Exception) {
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun scheduleRestartAlarm() {
        val am = getSystemService(AlarmManager::class.java) ?: return
        val intent = Intent(this, GuardService::class.java)
        val pending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                this, 2, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                this, 2, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        am.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + 1500, pending
        )
    }

    private fun goForeground() {
        val notification = GuardNotifications.serviceNotification(this, "Monitoring SOS & fall alerts")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                GuardNotifications.SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(GuardNotifications.SERVICE_NOTIFICATION_ID, notification)
        }
    }
}
