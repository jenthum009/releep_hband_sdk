package com.releep.releep_hband_sdk.core

import android.content.Context

/**
 * Persists the paired watch (MAC, name, password + identity read during the
 * password check) so the guard can re-establish the connection after process
 * death, reboot or swipe-away without user interaction.
 */
object WatchSession {

    private const val PREFS = "releep_hband_session"
    private const val KEY_MAC = "mac"
    private const val KEY_NAME = "name"
    private const val KEY_PASSWORD = "password"
    private const val KEY_DEVICE_NUMBER = "deviceNumber"
    private const val KEY_FIRMWARE = "firmware"
    private const val KEY_FIRMWARE_TEST = "firmwareTest"
    private const val KEY_GUARD_ENABLED = "guardEnabled"
    private const val KEY_WATCH_DAYS = "watchDays"
    private const val KEY_AUTO_PAIR_BT = "autoPairCallBluetooth"
    private const val KEY_CALL_SOS = "callSosDetection"
    private const val KEY_EMERGENCY_NOTIFICATION = "emergencyNotification"
    private const val KEY_SOS_DEFAULT_FOR = "sosDefaultAppliedFor"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isConfigured(context: Context): Boolean = mac(context).isNotEmpty()

    fun mac(context: Context): String = prefs(context).getString(KEY_MAC, "") ?: ""

    fun name(context: Context): String = prefs(context).getString(KEY_NAME, "") ?: ""

    fun password(context: Context): String =
        prefs(context).getString(KEY_PASSWORD, DEFAULT_PASSWORD) ?: DEFAULT_PASSWORD

    fun deviceNumber(context: Context): Int = prefs(context).getInt(KEY_DEVICE_NUMBER, -1)

    fun firmware(context: Context): String = prefs(context).getString(KEY_FIRMWARE, "") ?: ""

    fun firmwareTest(context: Context): String =
        prefs(context).getString(KEY_FIRMWARE_TEST, "") ?: ""

    /** How many days of history the watch keeps (reported during the password sync). */
    fun watchDays(context: Context): Int = prefs(context).getInt(KEY_WATCH_DAYS, 3)

    fun saveWatchDays(context: Context, days: Int) {
        if (days > 0) prefs(context).edit().putInt(KEY_WATCH_DAYS, days).apply()
    }

    /** Whether background guarding should run whenever a session exists. */
    fun isGuardEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_GUARD_ENABLED, true)

    fun setGuardEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_GUARD_ENABLED, enabled).apply()
    }

    /** Whether call Bluetooth (Classic / HFP) is paired automatically after the BLE session is ready. */
    fun isAutoPairBt(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AUTO_PAIR_BT, true)

    fun setAutoPairBt(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_AUTO_PAIR_BT, enabled).apply()
    }

    /** Whether an outgoing call through the watch's call Bluetooth counts as SOS (see CallSosDetector). */
    fun isCallSosDetection(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CALL_SOS, true)

    fun setCallSosDetection(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CALL_SOS, enabled).apply()
    }

    /** Whether the plugin posts its own notification for an emergency (kept across [forget]). */
    fun isEmergencyNotification(context: Context): Boolean =
        prefs(context).getBoolean(KEY_EMERGENCY_NOTIFICATION, true)

    fun setEmergencyNotification(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_EMERGENCY_NOTIFICATION, enabled).apply()
    }

    /** Watch (MAC) that already got the default SOS call count. */
    fun sosDefaultAppliedFor(context: Context): String =
        prefs(context).getString(KEY_SOS_DEFAULT_FOR, "") ?: ""

    fun setSosDefaultAppliedFor(context: Context, mac: String) {
        prefs(context).edit().putString(KEY_SOS_DEFAULT_FOR, mac).apply()
    }

    fun save(context: Context, mac: String, name: String?, password: String?) {
        if (mac.isEmpty()) return
        prefs(context).edit()
            .putString(KEY_MAC, mac)
            .putString(KEY_NAME, name ?: "")
            .putString(KEY_PASSWORD, if (password.isNullOrEmpty()) DEFAULT_PASSWORD else password)
            .apply()
    }

    fun saveIdentity(context: Context, deviceNumber: Int, firmware: String?, firmwareTest: String?) {
        val editor = prefs(context).edit()
        if (deviceNumber > 0) editor.putInt(KEY_DEVICE_NUMBER, deviceNumber)
        if (!firmware.isNullOrEmpty()) editor.putString(KEY_FIRMWARE, firmware)
        if (!firmwareTest.isNullOrEmpty()) editor.putString(KEY_FIRMWARE_TEST, firmwareTest)
        editor.apply()
    }

    /** Clears everything (used by "Forget / change watch"). */
    fun forget(context: Context) {
        val callSos = isCallSosDetection(context)
        val notification = isEmergencyNotification(context)
        prefs(context).edit().clear()
            .putBoolean(KEY_CALL_SOS, callSos)
            .putBoolean(KEY_EMERGENCY_NOTIFICATION, notification)
            .apply()
    }

    fun toMap(context: Context): Map<String, Any?>? {
        if (!isConfigured(context)) return null
        return mapOf(
            "deviceId" to mac(context),
            "name" to name(context),
            "deviceNumber" to deviceNumber(context),
            "firmware" to firmware(context),
            "firmwareTest" to firmwareTest(context),
            "guardEnabled" to isGuardEnabled(context),
            "watchDays" to watchDays(context),
            "autoPairCallBluetooth" to isAutoPairBt(context),
            "callSosDetection" to isCallSosDetection(context),
        )
    }

    const val DEFAULT_PASSWORD = "0000"
}
