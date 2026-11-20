package com.releep.releep_hband_sdk.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.releep.releep_hband_sdk.core.WatchSession

/** Restarts the guard after a reboot, but only when a watch session is saved. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (WatchSession.isConfigured(context) && WatchSession.isGuardEnabled(context)) {
            GuardService.start(context)
        }
    }
}
