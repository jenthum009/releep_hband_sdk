package com.releep.releep_hband_sdk.core

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.inuker.bluetooth.library.Code
import com.inuker.bluetooth.library.Constants
import com.inuker.bluetooth.library.log.VPLocalLogger
import com.inuker.bluetooth.library.search.SearchResult
import com.inuker.bluetooth.library.search.response.SearchResponse
import com.inuker.bluetooth.library.utils.BluetoothUtils
import com.releep.releep_hband_sdk.guard.GuardService
import com.releep.releep_hband_sdk.health.HealthMeasure
import com.releep.releep_hband_sdk.health.HealthRecords
import com.releep.releep_hband_sdk.health.HealthSync
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.base.IABleConnectStatusListener
import com.veepoo.protocol.listener.base.IBleWriteResponse
import com.veepoo.protocol.listener.data.ICustomSettingDataListener
import com.veepoo.protocol.listener.data.IDeviceControlPhoneModelState
import com.veepoo.protocol.listener.data.IDeviceFuctionDataListener
import com.veepoo.protocol.listener.data.IPwdDataListener
import com.veepoo.protocol.listener.data.IRemindEventListener
import com.veepoo.protocol.listener.data.ISocialMsgDataListener
import com.veepoo.protocol.model.datas.DeviceFunctionPackage1
import com.veepoo.protocol.model.datas.DeviceFunctionPackage2
import com.veepoo.protocol.model.datas.DeviceFunctionPackage3
import com.veepoo.protocol.model.datas.DeviceFunctionPackage4
import com.veepoo.protocol.model.datas.DeviceFunctionPackage5
import com.veepoo.protocol.model.datas.FunctionDeviceSupportData
import com.veepoo.protocol.model.datas.FunctionSocailMsgData
import com.veepoo.protocol.model.datas.PwdData
import com.veepoo.protocol.model.datas.RemindEvent
import com.veepoo.protocol.model.enums.EPwdStatus
import com.veepoo.protocol.model.enums.ERemindEvent
import com.veepoo.protocol.shareprence.VpSpGetUtil
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Native core of the plugin (ported from the Guard demo's EventMonitor).
 *
 * - Scan / connect / password check / disconnect / forget.
 * - Saved session + silent auto-restore + a 15 s reconnect watchdog.
 * - SOS / fall detection, three channels combined because firmwares differ:
 *   1. Raw frame signature "8F,08,03," read from the SDK's ble_change.txt log
 *      (the tested VIGOR firmware sends this for both SOS press and fall).
 *   2. ISOSListener — SDK push event (other firmwares).
 *   3. IRemindEventListener — fall push, when isSupportRemindEvent().
 *   4. CallSosDetector — opt-in: an outgoing call through the watch's call
 *      Bluetooth (watches that only dial and send nothing over BLE).
 * - Every event goes to the in-memory feed, the Flutter listener, the webhook
 *   and (for emergencies) a full-screen notification.
 *
 * All state changes happen on the main thread.
 */
@SuppressLint("StaticFieldLeak") // only the application context is stored
object HBandManager {

    private const val TAG = "HBandManager"

    // ---- event types (shared with iOS + Dart) ----
    const val EVENT_EMERGENCY_ALARM = "EMERGENCY_ALARM"
    const val EVENT_SOS_PRESSED = "SOS_PRESSED"
    const val EVENT_FALL_DETECTED = "FALL_DETECTED"
    const val EVENT_SEDENTARY = "SEDENTARY_REMIND"
    const val EVENT_STATUS = "STATUS"

    // ---- connection states (shared with iOS + Dart) ----
    const val STATE_DISCONNECTED = "disconnected"
    const val STATE_CONNECTING = "connecting"
    const val STATE_VERIFYING = "verifying"
    const val STATE_READY = "ready"
    const val STATE_PASSWORD_FAILED = "passwordFailed"
    const val STATE_FAILED = "failed"

    private const val SOS_FRAME_SIGNATURE = "8F,08,03,"
    private val FRAME_LINE = Regex("^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})\\|\\|")
    private const val EMERGENCY_DEDUPE_MS = 10_000L
    private const val FRAME_FRESH_MS = 5_000L
    private const val WATCHDOG_MS = 15_000L
    private const val CONNECT_TIMEOUT_MS = 45_000L
    private const val MAX_EVENTS = 100
    private const val EVENT_PREFS = "releep_hband_guard_events"
    private const val EVENT_PREFS_KEY = "emergencies"

    interface Listener {
        fun onScanResult(device: Map<String, Any?>)
        fun onScanFinished()
        fun onConnectionChanged(state: Map<String, Any?>)
        fun onEvent(event: Map<String, Any?>)
    }

    data class GuardEvent(
        val id: String,
        val type: String,
        val timestamp: Long,
        val detail: String,
        val extra: JSONObject,
        @Volatile var webhookStatus: String = "not sent",
        @Volatile var acknowledged: Boolean = false,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id,
            "type" to type,
            "timestamp" to timestamp,
            "detail" to detail,
            "webhookStatus" to webhookStatus,
            "acknowledged" to acknowledged,
            "data" to jsonToMap(extra),
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val frameExecutor = Executors.newSingleThreadScheduledExecutor()
    private var framePoll: ScheduledFuture<*>? = null

    private var app: Context? = null
    var listener: Listener? = null

    private val events = ArrayDeque<GuardEvent>()
    private var persistedEventsLoaded = false

    @Volatile private var sdkReady = false
    @Volatile private var monitoring = false
    @Volatile private var linkConnected = false
    @Volatile private var sessionSynced = false
    @Volatile private var restoreInProgress = false
    @Volatile private var lastEmergencyAt = 0L
    @Volatile private var lastFrameLineSeen: String? = null
    private var watchdogStarted = false
    private var state = STATE_DISCONNECTED
    private var stateMessage: String? = null
    private var currentMac: String? = null
    private var currentName: String? = null
    private var scanning = false
    private val scannedAddresses = HashSet<String>()

    /** Some firmwares report SOS through the combined phone-control callback. */
    private val deviceControlPhoneListener = object : IDeviceControlPhoneModelState {
        override fun sos() {
            main.post { onSdkSos("sdk-device-control-listener") }
        }
        override fun knocknotify(type: Int) = Unit
        override fun nextMusic() = Unit
        override fun previousMusic() = Unit
        override fun pauseAndPlayMusic() = Unit
        override fun pauseMusic() = Unit
        override fun playMusic() = Unit
        override fun voiceUp() = Unit
        override fun voiceDown() = Unit
        override fun oprateMusicSuccess() = Unit
        override fun oprateMusicFail() = Unit
        override fun inPttModel() = Unit
        override fun outPttModel() = Unit
        override fun rejectPhone() = Unit
        override fun cliencePhone() = Unit
        override fun appAnswerCall() = Unit
        override fun inMultiEcgModel() = Unit
        override fun outMultiEcgModel() = Unit
    }

    private var pendingConnect: ((Map<String, Any?>) -> Unit)? = null
    private val connectTimeout = Runnable {
        if (pendingConnect != null) {
            setState(STATE_FAILED, "Connection timed out")
            finishConnect(false, "Connection timed out")
        }
    }

    // ===================================================================
    // Init
    // ===================================================================

    /** Initialises the SDK once. Safe to call from the plugin, service or boot receiver. */
    fun init(context: Context) {
        if (app == null) app = context.applicationContext
        loadPersistedEvents(context.applicationContext)
        if (sdkReady) return
        val ctx = app ?: return
        try {
            VPOperateManager.getInstance().init(ctx)
            VPOperateManager.getInstance().setAutoConnectBTBySdk(false)
            // Needed for the frame-signature SOS channel: the SDK writes every
            // incoming frame to ble_change.txt only while this logger runs.
            VPLocalLogger.startMonitor(ctx)
            PhoneFeatures.init()
            sdkReady = true
        } catch (e: Exception) {
            Log.e(TAG, "SDK init failed: $e")
        }
    }

    fun isBluetoothEnabled(): Boolean = try {
        BluetoothUtils.isBluetoothEnabled()
    } catch (_: Exception) {
        false
    }

    // ===================================================================
    // Scan
    // ===================================================================

    private val stopScanRunnable = Runnable { stopScan() }

    fun startScan(context: Context, timeoutSeconds: Int) {
        init(context)
        if (scanning) stopScan()
        scannedAddresses.clear()
        scanning = true
        VPOperateManager.getInstance().startScanDevice(object : SearchResponse {
            override fun onSearchStarted() {}

            override fun onDeviceFounded(device: SearchResult) {
                main.post {
                    val address = device.address ?: return@post
                    if (!scannedAddresses.add(address)) return@post
                    listener?.onScanResult(
                        mapOf(
                            "deviceId" to address,
                            "name" to (device.name?.takeIf { it.isNotEmpty() } ?: "Unknown"),
                            "rssi" to device.rssi,
                        )
                    )
                }
            }

            override fun onSearchStopped() {
                main.post { onScanEnded() }
            }

            override fun onSearchCanceled() {
                main.post { onScanEnded() }
            }
        })
        main.removeCallbacks(stopScanRunnable)
        main.postDelayed(stopScanRunnable, timeoutSeconds.coerceIn(3, 120) * 1000L)
    }

    fun stopScan() {
        main.removeCallbacks(stopScanRunnable)
        if (!scanning) return
        try {
            VPOperateManager.getInstance().stopScanDevice()
        } catch (_: Exception) {
        }
        onScanEnded()
    }

    private fun onScanEnded() {
        if (!scanning) return
        scanning = false
        listener?.onScanFinished()
    }

    // ===================================================================
    // Connect / password
    // ===================================================================

    /**
     * Connects to [mac], verifies [password] and — on success — saves the
     * session and arms the guard. [done] receives {success, state, message}.
     */
    fun connect(
        context: Context,
        mac: String,
        name: String?,
        password: String,
        is24Hour: Boolean,
        done: (Map<String, Any?>) -> Unit,
    ) {
        init(context)
        stopScan()
        if (pendingConnect != null) {
            done(result(false, "Another connection is in progress"))
            return
        }
        pendingConnect = done
        main.removeCallbacks(connectTimeout)
        main.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)

        // Switching watches: drop the old link first.
        val previous = currentMac
        if (previous != null && previous != mac && linkConnected) {
            try {
                VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse { })
            } catch (_: Exception) {
            }
        }
        currentMac = mac
        currentName = name
        sessionSynced = false
        setState(STATE_CONNECTING, null)
        val manager = VPOperateManager.getInstance()
        // Manual pairing → let the watch show its "confirm connection" prompt.
        manager.setDeviceShowConfirm(true)
        manager.registerConnectStatusListener(mac, connectStatusListener)
        manager.connectDevice(mac, name ?: "", { code, _, _ ->
            main.post {
                if (code == Code.REQUEST_SUCCESS) {
                    linkConnected = true
                } else {
                    setState(STATE_FAILED, "Connect failed (code $code)")
                    finishConnect(false, "Connect failed (code $code)")
                }
            }
        }, { notifyState ->
            main.post {
                if (notifyState == Code.REQUEST_SUCCESS) {
                    setState(STATE_VERIFYING, null)
                    confirmPassword(mac, name, password, is24Hour, silent = false)
                } else {
                    setState(STATE_FAILED, "BLE notify setup failed")
                    finishConnect(false, "BLE notify setup failed")
                }
            }
        })
    }

    private fun confirmPassword(
        mac: String,
        name: String?,
        password: String,
        is24Hour: Boolean,
        silent: Boolean,
    ) {
        val ctx = app ?: return
        val manager = VPOperateManager.getInstance()
        // Veepoo recommends installing device-control callbacks before
        // password verification. Some firmwares only use this callback for SOS.
        registerSosListeners(manager)
        manager.confirmDevicePwd(
            IBleWriteResponse { code ->
                if (code != Code.REQUEST_SUCCESS) {
                    main.post {
                        if (silent) restoreFailed() else {
                            setState(STATE_FAILED, "Password command write failed")
                            finishConnect(false, "Password command write failed")
                        }
                    }
                }
            },
            object : IPwdDataListener {
                override fun onPwdDataChange(pwdData: PwdData?) {
                    pwdData ?: return
                    main.post {
                        if (pwdData.getmStatus() == EPwdStatus.CHECK_FAIL) {
                            // Wrong password: drop the link, report it.
                            try {
                                VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse { })
                            } catch (_: Exception) {
                            }
                            setState(STATE_PASSWORD_FAILED, "Wrong watch password")
                            if (silent) restoreFailed() else finishConnect(false, "Wrong watch password")
                            return@post
                        }
                        WatchSession.saveIdentity(
                            ctx, pwdData.deviceNumber, pwdData.deviceVersion, pwdData.deviceTestVersion
                        )
                    }
                }

                override fun onConnectionConfirmTimeout() {
                    main.post {
                        setState(STATE_FAILED, "Not confirmed on the watch in time")
                        if (silent) restoreFailed() else finishConnect(false, "Not confirmed on the watch in time")
                    }
                }
            },
            emptyFunctionListener,
            emptySocialListener,
            ICustomSettingDataListener {
                // Last callback of the sync — the session is fully usable now.
                main.post { onSessionReady(mac, name, password) }
            },
            password,
            is24Hour,
        )
    }

    private fun onSessionReady(mac: String, name: String?, password: String) {
        val ctx = app ?: return
        sessionSynced = true
        restoreInProgress = false
        linkConnected = true
        WatchSession.save(ctx, mac, name, password)
        setState(STATE_READY, null)
        recordStatus("Watch session ready (${name ?: mac})")
        finishConnect(true, null)
        PhoneFeatures.onSessionReady()
        if (WatchSession.isGuardEnabled(ctx)) {
            startMonitoring(ctx)
            GuardService.start(ctx)
        }
    }

    private fun finishConnect(success: Boolean, message: String?) {
        main.removeCallbacks(connectTimeout)
        val cb = pendingConnect ?: return
        pendingConnect = null
        cb(result(success, message))
    }

    private fun result(success: Boolean, message: String?) = mapOf(
        "success" to success,
        "state" to state,
        "message" to message,
    )

    /** Drops the link but keeps the saved session (the watchdog will NOT reconnect). */
    fun disconnect(context: Context) {
        init(context)
        cancelHealthWork()
        stopGuard(context)
        try {
            VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse { })
        } catch (_: Exception) {
        }
        linkConnected = false
        sessionSynced = false
        setState(STATE_DISCONNECTED, null)
    }

    /** Disconnects, clears the saved session and stops every background loop. */
    fun forgetWatch(context: Context) {
        init(context)
        cancelHealthWork()
        stopMonitoring()
        try {
            VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse { })
        } catch (_: Exception) {
        }
        main.removeCallbacksAndMessages(null)
        watchdogStarted = false
        linkConnected = false
        sessionSynced = false
        restoreInProgress = false
        pendingConnect = null
        currentMac = null
        currentName = null
        clearEvents()
        PhoneFeatures.reset()
        WatchSession.forget(context)
        GuardService.stop(context)
        setState(STATE_DISCONNECTED, null)
        recordStatus("Watch forgotten — scan and connect a new watch")
    }

    // ===================================================================
    // Guard (monitoring + background service)
    // ===================================================================

    fun startGuard(context: Context): Boolean {
        init(context)
        if (!WatchSession.isConfigured(context)) return false
        WatchSession.setGuardEnabled(context, true)
        startMonitoring(context)
        GuardService.start(context)
        return true
    }

    fun stopGuard(context: Context) {
        WatchSession.setGuardEnabled(context, false)
        stopMonitoring()
        GuardService.stop(context)
    }

    fun isGuardRunning(): Boolean = monitoring

    /** Registers SDK listeners, the frame poller and the watchdog. Idempotent. */
    fun startMonitoring(context: Context) {
        init(context)
        main.post { startMonitoringOnMain() }
    }

    private fun startMonitoringOnMain() {
        val ctx = app ?: return
        if (!WatchSession.isConfigured(ctx)) return
        val manager = VPOperateManager.getInstance()
        try {
            registerSosListeners(manager)
            val remindSupported = try {
                VpSpGetUtil.getVpSpVariInstance(ctx).isSupportRemindEvent
            } catch (_: Exception) {
                false
            }
            if (remindSupported) manager.setReminderEventReportListener(remindListener)
            if (currentMac == null) {
                currentMac = WatchSession.mac(ctx)
                currentName = WatchSession.name(ctx)
            }
            manager.registerConnectStatusListener(currentMac, connectStatusListener)
            if (!monitoring) {
                recordStatus(
                    "Monitoring started" +
                        if (remindSupported) " (fall push supported)" else " (fall push not supported by firmware)"
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "startMonitoring failed: $e")
        }
        monitoring = true
        CallSosDetector.start(ctx)
        startFramePolling()
        startWatchdog()
        main.postDelayed({ autoRestoreConnection() }, 800)
    }

    private fun registerSosListeners(manager: VPOperateManager) {
        manager.settingDeviceControlPhone(deviceControlPhoneListener)
        manager.settingSOSListener { main.post { onSdkSos("sdk-sos-listener") } }
    }

    private fun stopMonitoring() {
        if (!monitoring) return
        monitoring = false
        framePoll?.cancel(false)
        framePoll = null
        CallSosDetector.stop()
        try {
            VPOperateManager.getInstance().removeReminderEventReportListener()
        } catch (_: Exception) {
        }
        recordStatus("Monitoring stopped")
    }

    private fun startWatchdog() {
        if (watchdogStarted) return
        watchdogStarted = true
        main.postDelayed(object : Runnable {
            override fun run() {
                if (!watchdogStarted) return
                if (monitoring) {
                    refreshLinkState()
                    if (!(linkConnected && sessionSynced) && !restoreInProgress && pendingConnect == null && !isBusy()) {
                        autoRestoreConnection()
                    }
                }
                main.postDelayed(this, WATCHDOG_MS)
            }
        }, WATCHDOG_MS)
    }

    /** Reconnects to the saved watch and re-runs the password check silently. */
    private fun autoRestoreConnection() {
        val ctx = app ?: return
        if (!monitoring || !WatchSession.isConfigured(ctx)) return
        if (restoreInProgress || pendingConnect != null) return
        refreshLinkState()
        if (linkConnected && sessionSynced) return
        val mac = WatchSession.mac(ctx)
        val name = WatchSession.name(ctx)
        val password = WatchSession.password(ctx)
        currentMac = mac
        currentName = name
        restoreInProgress = true
        recordStatus("Auto-restoring watch session…")
        val manager = VPOperateManager.getInstance()
        // Reconnect → no confirmation prompt on the watch.
        manager.setDeviceShowConfirm(false)
        if (linkConnected) {
            setState(STATE_VERIFYING, null)
            confirmPassword(mac, name, password, true, silent = true)
            return
        }
        setState(STATE_CONNECTING, null)
        manager.connectDevice(mac, name, { code, _, _ ->
            main.post {
                if (code == Code.REQUEST_SUCCESS) linkConnected = true else restoreFailed()
            }
        }, { notifyState ->
            main.post {
                if (notifyState == Code.REQUEST_SUCCESS) {
                    setState(STATE_VERIFYING, null)
                    confirmPassword(mac, name, password, true, silent = true)
                } else {
                    restoreFailed()
                }
            }
        })
    }

    private fun restoreFailed() {
        restoreInProgress = false
        if (state != STATE_PASSWORD_FAILED) setState(STATE_DISCONNECTED, "Watch not reachable — retrying")
    }

    private fun refreshLinkState() {
        val mac = currentMac ?: return
        try {
            linkConnected = VPOperateManager.getInstance().isDeviceConnected(mac)
            if (!linkConnected) sessionSynced = false
        } catch (_: Exception) {
        }
    }

    private val connectStatusListener = object : IABleConnectStatusListener() {
        override fun onConnectStatusChanged(mac: String?, status: Int) {
            main.post {
                when (status) {
                    Constants.STATUS_CONNECTED -> linkConnected = true
                    Constants.STATUS_DISCONNECTED -> {
                        linkConnected = false
                        sessionSynced = false
                        // A sync waiting on a dead link would stay BUSY until
                        // every step timed out — end it now.
                        activeSync?.abort("watch disconnected")
                        if (state == STATE_READY) {
                            setState(STATE_DISCONNECTED, "Watch disconnected")
                            recordStatus("Watch disconnected — auto-reconnecting")
                        }
                    }
                }
            }
        }
    }

    // ===================================================================
    // SOS / fall detection
    // ===================================================================

    private fun startFramePolling() {
        if (framePoll != null) return
        framePoll = frameExecutor.scheduleWithFixedDelay({
            try {
                scanRawFrames()
            } catch (e: Exception) {
                Log.e(TAG, "frame poll error: $e")
            }
        }, 800, 800, TimeUnit.MILLISECONDS)
    }

    private fun scanRawFrames() {
        val lines = RawFrameLogReader.incoming(30) ?: return
        val now = System.currentTimeMillis()
        val fileFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        for (line in lines.asReversed()) {
            if (!line.contains(SOS_FRAME_SIGNATURE)) continue
            if (line == lastFrameLineSeen) return
            val match = FRAME_LINE.find(line) ?: continue
            val frameTime = try {
                fileFormat.parse(match.groupValues[1])?.time ?: continue
            } catch (_: Exception) {
                continue
            }
            // Only react to frames that just arrived; the log tail keeps old SOS lines.
            if (now - frameTime in 0..FRAME_FRESH_MS) {
                lastFrameLineSeen = line
                main.post { onEmergencyFrame(line) }
            }
            return
        }
    }

    private fun onEmergencyFrame(rawLine: String) {
        emitEmergency(
            EVENT_EMERGENCY_ALARM,
            "Emergency alarm from watch (SOS press or fall detection)",
            JSONObject()
                .put("detection", "frame-signature")
                .put("possibleTriggers", JSONArray().put("SOS button press").put("fall detection"))
                .put("rawFrame", rawLine),
        )
    }

    private fun onSdkSos(detection: String) {
        emitEmergency(
            EVENT_SOS_PRESSED,
            "SOS button pressed on watch",
            JSONObject().put("detection", detection),
        )
    }

    /** From [CallSosDetector]: the watch placed an outgoing call over call Bluetooth. */
    fun onCallSos() {
        emitEmergency(
            EVENT_SOS_PRESSED,
            "SOS call placed by watch",
            JSONObject().put("detection", "hfp-outgoing-call"),
        )
    }

    /** Applies the call-SOS setting / permission change while the guard runs. */
    fun syncCallSosDetector(context: Context) {
        init(context)
        main.post {
            val ctx = app ?: return@post
            if (monitoring) CallSosDetector.start(ctx)
            if (!WatchSession.isCallSosDetection(ctx)) CallSosDetector.stop()
        }
    }

    private val remindListener = object : IRemindEventListener {
        override fun onRemindEventRead(data: ArrayList<RemindEvent>) {
            // Historical read — not re-reported.
        }

        override fun onRemindEventReport(data: ArrayList<RemindEvent>) {
            main.post { data.forEach { onRemindEvent(it) } }
        }
    }

    private fun onRemindEvent(event: RemindEvent) {
        val type = event.remindEvent
        val payload = JSONObject()
            .put("detection", "sdk-remind-event")
            .put("remindEvent", type?.name ?: "UNKNOWN")
            .put("eventTimestampSeconds", event.timestamp)
            .put("attitude", event.attitude)
        if (type == ERemindEvent.FALL) {
            emitEmergency(EVENT_FALL_DETECTED, "Fall detected by watch", payload)
        } else {
            record(EVENT_SEDENTARY, "Sedentary reminder", payload, alert = false)
        }
    }

    /** Emergency events from any channel share one 10 s dedupe window. */
    private fun emitEmergency(type: String, detail: String, payload: JSONObject) {
        val now = System.currentTimeMillis()
        if (now - lastEmergencyAt < EMERGENCY_DEDUPE_MS) return
        lastEmergencyAt = now
        record(type, detail, payload, alert = true)
    }

    /** Pushes a fake emergency through the whole pipeline (feed + webhook + alert). */
    fun simulateEmergency(context: Context, label: String?): Map<String, Any?> {
        init(context)
        val event = record(
            EVENT_EMERGENCY_ALARM,
            label ?: "SIMULATED emergency",
            JSONObject().put("detection", "simulated").put("simulated", true),
            alert = true,
        )
        return event.toMap()
    }

    // ===================================================================
    // Feed
    // ===================================================================

    fun events(): List<Map<String, Any?>> = synchronized(events) {
        events.reversed().map { it.toMap() }
    }

    fun clearEvents() {
        synchronized(events) { events.clear() }
        persistEmergencyEvents()
    }

    fun acknowledge(id: String): Boolean {
        val changed = synchronized(events) {
            events.firstOrNull { it.id == id }?.let { it.acknowledged = true; true } ?: false
        }
        if (changed) persistEmergencyEvents()
        return changed
    }

    /**
     * Emergency events must survive a killed Flutter engine/process so the app
     * can deliver them to its API on the next start. Status/feed noise remains
     * in memory only.
     */
    private fun loadPersistedEvents(context: Context) {
        if (persistedEventsLoaded) return
        synchronized(events) {
            if (persistedEventsLoaded) return
            persistedEventsLoaded = true
            val raw = context.getSharedPreferences(EVENT_PREFS, Context.MODE_PRIVATE)
                .getString(EVENT_PREFS_KEY, null) ?: return
            try {
                val array = JSONArray(raw)
                for (i in 0 until array.length()) {
                    val item = array.optJSONObject(i) ?: continue
                    val id = item.optString("id")
                    val type = item.optString("type")
                    if (id.isEmpty() || !isEmergencyType(type) || events.any { it.id == id }) continue
                    events.addLast(
                        GuardEvent(
                            id = id,
                            type = type,
                            timestamp = item.optLong("timestamp"),
                            detail = item.optString("detail"),
                            extra = item.optJSONObject("data") ?: JSONObject(),
                            webhookStatus = item.optString("webhookStatus", "not sent"),
                            acknowledged = item.optBoolean("acknowledged", false),
                        )
                    )
                }
                while (events.size > MAX_EVENTS) events.removeFirst()
            } catch (e: Exception) {
                Log.e(TAG, "Could not restore emergency events: $e")
            }
        }
    }

    private fun persistEmergencyEvents() {
        val context = app ?: return
        val array = JSONArray()
        synchronized(events) {
            events.filter { isEmergencyType(it.type) && it.extra.optBoolean("simulated") != true }
                .forEach { event ->
                    array.put(
                        JSONObject()
                            .put("id", event.id)
                            .put("type", event.type)
                            .put("timestamp", event.timestamp)
                            .put("detail", event.detail)
                            .put("data", event.extra)
                            .put("webhookStatus", event.webhookStatus)
                            .put("acknowledged", event.acknowledged)
                    )
                }
        }
        context.getSharedPreferences(EVENT_PREFS, Context.MODE_PRIVATE)
            .edit().putString(EVENT_PREFS_KEY, array.toString()).apply()
    }

    private fun isEmergencyType(type: String): Boolean =
        type == EVENT_EMERGENCY_ALARM || type == EVENT_SOS_PRESSED || type == EVENT_FALL_DETECTED

    fun appContext(): Context? = app

    /** Adds a status line to the feed (used by [PhoneFeatures]). */
    fun note(text: String) = recordStatus(text)

    private fun recordStatus(text: String) {
        record(EVENT_STATUS, text, JSONObject(), alert = false, report = false)
    }

    private fun record(
        type: String,
        detail: String,
        payload: JSONObject,
        alert: Boolean,
        report: Boolean = true,
    ): GuardEvent {
        val ctx = app
        val event = GuardEvent(
            id = UUID.randomUUID().toString(),
            type = type,
            timestamp = System.currentTimeMillis(),
            detail = detail,
            extra = payload,
            acknowledged = !alert,
        )
        synchronized(events) {
            events.addLast(event)
            while (events.size > MAX_EVENTS) events.removeFirst()
        }
        Log.i(TAG, "EVENT $type: $detail")
        if (report && ctx != null) {
            payload.put("watch", watchInfo(ctx))
            if (WebhookReporter.isEnabled(ctx)) {
                event.webhookStatus = "sending…"
                WebhookReporter.report(ctx, type, payload) { success, _, message ->
                    event.webhookStatus = if (success) "sent ($message)" else "failed ($message)"
                    listener?.onEvent(event.toMap())
                }
            } else {
                event.webhookStatus = "webhook off"
            }
        }
        if (alert && ctx != null && WatchSession.isEmergencyNotification(ctx)) {
            GuardNotifications.postEmergency(ctx, event.id, "🆘 Emergency from watch", detail)
        }
        if (alert) persistEmergencyEvents()
        listener?.onEvent(event.toMap())
        return event
    }

    // ===================================================================
    // Info
    // ===================================================================

    fun watchInfo(context: Context): JSONObject {
        val number = WatchSession.deviceNumber(context)
        return JSONObject()
            .put("sn", if (number > 0) number.toString() else "unknown")
            .put("mac", WatchSession.mac(context))
            .put("name", WatchSession.name(context))
            .put("firmware", WatchSession.firmware(context))
            .put("firmwareTest", WatchSession.firmwareTest(context))
    }

    fun connectionState(): Map<String, Any?> = mapOf(
        "state" to state,
        "deviceId" to currentMac,
        "name" to currentName,
        "message" to stateMessage,
        "guardRunning" to monitoring,
    )

    private fun setState(newState: String, message: String?) {
        if (state == newState && stateMessage == message) return
        state = newState
        stateMessage = message
        listener?.onConnectionChanged(connectionState())
    }

    fun readBattery(context: Context, done: (Map<String, Any?>?) -> Unit) {
        init(context)
        if (!sessionSynced) {
            done(null)
            return
        }
        var answered = false
        val timeout = Runnable { if (!answered) { answered = true; done(null) } }
        main.postDelayed(timeout, 8_000)
        VPOperateManager.getInstance().readBattery(IBleWriteResponse { }) { data ->
            main.post {
                if (answered) return@post
                answered = true
                main.removeCallbacks(timeout)
                done(
                    mapOf(
                        "isPercent" to data.isPercent,
                        "percent" to data.batteryPercent,
                        "level" to data.batteryLevel,
                        "isLow" to data.isLowBattery,
                        "charging" to (data.powerModel == 1),
                    )
                )
            }
        }
    }

    /** Last [lines] raw frames in/out, for the diagnostics screen. */
    fun rawFrames(lines: Int): Map<String, Any?> = mapOf(
        "incoming" to (RawFrameLogReader.incoming(lines) ?: emptyList<String>()),
        "outgoing" to (RawFrameLogReader.outgoing(lines) ?: emptyList<String>()),
    )

    // ===================================================================
    // Health data (sync history / manual measurement)
    // ===================================================================

    private var activeSync: HealthSync? = null
    private var activeMeasure: HealthMeasure? = null

    /** A sync or measurement owns the SDK — it can only run one command at a time. */
    fun isBusy(): Boolean = activeSync != null || activeMeasure != null

    fun isReady(): Boolean = sessionSynced && linkConnected

    /** Backend `imei`: the watch MAC in upper case. */
    fun imei(context: Context): String? = WatchSession.mac(context).takeIf { it.isNotEmpty() }?.uppercase()

    fun syncHealth(
        context: Context,
        days: Int,
        types: Set<String>,
        onProgress: (Map<String, Any?>) -> Unit,
        done: (Map<String, Any?>?, String?) -> Unit,
    ) {
        init(context)
        if (!isReady()) return done(null, "NOT_READY")
        if (isBusy()) return done(null, "BUSY")
        val sync = HealthSync(context, days, types, onProgress) { result ->
            activeSync = null
            done(result, null)
        }
        activeSync = sync
        sync.start()
    }

    fun cancelSync() {
        activeSync?.cancel()
    }

    private fun cancelHealthWork() {
        activeSync?.cancel()
        activeMeasure?.stop()
    }

    fun startMeasure(
        context: Context,
        type: String,
        onUpdate: (Map<String, Any?>) -> Unit,
        done: (Map<String, Any?>?, String?) -> Unit,
    ) {
        init(context)
        if (type !in HealthMeasure.TYPES) return done(null, "UNSUPPORTED_TYPE")
        if (!isReady()) return done(null, "NOT_READY")
        if (isBusy()) return done(null, "BUSY")
        val measure = HealthMeasure(type, onUpdate) { result ->
            activeMeasure = null
            done(result, null)
        }
        activeMeasure = measure
        measure.start()
    }

    fun stopMeasure() {
        activeMeasure?.stop()
    }

    /** Which data the connected watch reports as supported. */
    fun capabilities(context: Context): Map<String, Any?> {
        val sp = VpSpGetUtil.getVpSpVariInstance(context)
        fun flag(block: () -> Boolean): Boolean = try { block() } catch (_: Throwable) { false }
        return mapOf(
            "spo2" to flag { sp.isSupportSpo2h },
            "hrv" to flag { sp.isSupportHRV },
            "bodytemp" to flag { sp.isSupportReadTempture },
            "bodytempMeasure" to flag { sp.isSupportCheckTemptureByApp },
            "bloodpressure" to flag { sp.isSupportBp },
            "ecg" to flag { sp.isSupportECG },
            "bloodglucose" to flag { sp.isSupportBloodGlucose || sp.isSupportBloodGlucoseDetect },
            "respiratory" to flag { sp.isSupportBreath },
            "sport" to flag { sp.isSupportSportModel },
            "preciseSleep" to flag { sp.isSupportPreciseSleep },
            "stress" to flag { sp.isSupportStress },
            "reminderEvent" to flag { sp.isSupportRemindEvent },
            "originProtocolVersion" to (try { sp.originProtocolVersion } catch (_: Throwable) { 0 }),
            "watchDays" to WatchSession.watchDays(context),
            "measurements" to mapOf(
                HealthRecords.HEART_RATE to true,
                HealthRecords.BLOOD_PRESSURE to flag { sp.isSupportBp },
                HealthRecords.SPO2 to flag { sp.isSupportSpo2h },
                HealthRecords.BODY_TEMP to flag { sp.isSupportCheckTemptureByApp },
                HealthRecords.FATIGUE to true,
                HealthRecords.BLOOD_GLUCOSE to flag { sp.isSupportBloodGlucoseDetect || sp.isSupportBloodGlucose },
                HealthRecords.ECG to flag { sp.isSupportECG },
                "ptt" to flag { sp.isSupportECG },
                HealthRecords.STRESS to flag { sp.isSupportStress },
                HealthRecords.HRV to flag { sp.isSupportHrvAppDetect },
                HealthRecords.RESPIRATORY to flag { sp.isSupportBreath },
                HealthMeasure.BLOOD_COMPONENT to flag { sp.isSupportBloodComponentDetect || sp.isSupportBloodComponent },
                HealthMeasure.BODY_COMPOSITION to flag { sp.isSupportBodyComponent },
                HealthMeasure.GSR to flag { sp.isSupportGSR },
                HealthMeasure.MET to flag { sp.isSupportMetAppDetect },
                HealthMeasure.EMOTION to flag { sp.isSupportEmotionAppDetect },
                HealthMeasure.CHECKUP to flag { sp.isSupportMiniCheckup },
            ).filterValues { it }.keys.toList(),
        )
    }

    // ===================================================================
    // Helpers
    // ===================================================================

    private val emptyFunctionListener = object : IDeviceFuctionDataListener {
        override fun onFunctionSupportDataChange(data: FunctionDeviceSupportData?) {
            val ctx = app ?: return
            data?.let { WatchSession.saveWatchDays(ctx, it.wathcDay) }
        }
        override fun onDeviceFunctionPackage1Report(data: DeviceFunctionPackage1?) {}
        override fun onDeviceFunctionPackage2Report(data: DeviceFunctionPackage2?) {}
        override fun onDeviceFunctionPackage3Report(data: DeviceFunctionPackage3?) {}
        override fun onDeviceFunctionPackage4Report(data: DeviceFunctionPackage4?) {}
        override fun onDeviceFunctionPackage5Report(data: DeviceFunctionPackage5?) {}
    }

    private val emptySocialListener = object : ISocialMsgDataListener {
        override fun onSocialMsgSupportDataChange(data: FunctionSocailMsgData?) {}
        override fun onSocialMsgSupportDataChange2(data: FunctionSocailMsgData?) {}
    }

    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        json.keys().forEach { key -> map[key] = unwrap(json.opt(key)) }
        return map
    }

    private fun unwrap(value: Any?): Any? = when (value) {
        is JSONObject -> jsonToMap(value)
        is JSONArray -> (0 until value.length()).map { unwrap(value.opt(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}
