package com.releep.releep_hband_sdk.core

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log

/**
 * SOS detection for watches that send nothing over BLE when SOS is pressed and
 * only dial the SOS contact through call Bluetooth (seen on VANTA, fw 00.91.01).
 *
 * An outgoing call (IDLE → OFFHOOK without RINGING) while the saved watch is
 * connected as the phone's HFP headset is reported as SOS. The phone number is
 * not available without READ_CALL_LOG, so any outgoing call in that state counts —
 * meant for SOS-only watches. On by default; switch off with [WatchSession.setCallSosDetection].
 *
 * Runs only while the guard is monitoring; all callbacks arrive on the main thread.
 */
object CallSosDetector {

    private const val TAG = "HBandCallSos"

    private var telephony: TelephonyManager? = null
    private var callback: Any? = null // TelephonyCallback (API 31+) or PhoneStateListener
    private var headset: BluetoothHeadset? = null
    private var lastState = TelephonyManager.CALL_STATE_IDLE

    fun hasPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED

    val isRunning: Boolean get() = callback != null

    fun start(context: Context) {
        if (callback != null) return
        val ctx = context.applicationContext
        if (!WatchSession.isCallSosDetection(ctx)) return
        if (!hasPermission(ctx)) {
            Log.w(TAG, "Not started: READ_PHONE_STATE not granted")
            return
        }
        val tm = ctx.getSystemService(TelephonyManager::class.java) ?: return
        lastState = TelephonyManager.CALL_STATE_IDLE
        try {
            callback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) = onCallState(state)
                }
                tm.registerTelephonyCallback(ctx.mainExecutor, cb)
                cb
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) = onCallState(state)
                }
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                listener
            }
            telephony = tm
        } catch (e: Exception) {
            Log.e(TAG, "Call state listener failed: $e")
            callback = null
            return
        }
        openHeadsetProxy(ctx)
        Log.i(TAG, "Call-based SOS detection started")
    }

    fun stop() {
        val tm = telephony
        val cb = callback
        if (tm != null && cb != null) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && cb is TelephonyCallback) {
                    tm.unregisterTelephonyCallback(cb)
                } else if (cb is PhoneStateListener) {
                    @Suppress("DEPRECATION")
                    tm.listen(cb, PhoneStateListener.LISTEN_NONE)
                }
            } catch (_: Exception) {
            }
        }
        callback = null
        telephony = null
        headset?.let { proxy ->
            try {
                (HBandManager.appContext()?.getSystemService(BluetoothManager::class.java))
                    ?.adapter?.closeProfileProxy(BluetoothProfile.HEADSET, proxy)
            } catch (_: Exception) {
            }
        }
        headset = null
    }

    private fun openHeadsetProxy(context: Context) {
        if (headset != null) return
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        try {
            adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (callback == null) {
                        adapter.closeProfileProxy(BluetoothProfile.HEADSET, proxy)
                        return
                    }
                    headset = proxy as? BluetoothHeadset
                }

                override fun onServiceDisconnected(profile: Int) {
                    headset = null
                }
            }, BluetoothProfile.HEADSET)
        } catch (e: SecurityException) {
            Log.w(TAG, "Headset proxy unavailable: $e")
        }
    }

    private fun onCallState(state: Int) {
        val previous = lastState
        lastState = state
        // IDLE → OFFHOOK = outgoing call; incoming calls pass through RINGING.
        if (previous != TelephonyManager.CALL_STATE_IDLE || state != TelephonyManager.CALL_STATE_OFFHOOK) return
        val ctx = HBandManager.appContext() ?: return
        if (!isWatchHeadsetConnected(ctx)) {
            Log.i(TAG, "Outgoing call ignored: watch is not the connected call headset")
            return
        }
        HBandManager.onCallSos()
    }

    @SuppressLint("MissingPermission")
    private fun isWatchHeadsetConnected(context: Context): Boolean {
        val proxy = headset ?: return false
        val mac = WatchSession.mac(context)
        val name = WatchSession.name(context)
        return try {
            proxy.connectedDevices.any { device ->
                device.address.equals(mac, ignoreCase = true) ||
                    (name.isNotEmpty() && device.name == name)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot read headset devices: $e")
            false
        }
    }
}
