package com.releep.releep_hband_sdk.core

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.os.Looper
import android.util.Log
import com.inuker.bluetooth.library.Code
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.base.IBleWriteResponse
import com.veepoo.protocol.listener.data.IContactOptListener
import com.veepoo.protocol.listener.data.IDeviceBTConnectionListener
import com.veepoo.protocol.listener.data.IDeviceBTInfoListener
import com.veepoo.protocol.listener.data.ISOSCallTimesListener
import com.veepoo.protocol.model.datas.BTInfo
import com.veepoo.protocol.model.datas.Contact
import com.veepoo.protocol.model.enums.EContactOpt
import com.veepoo.protocol.shareprence.VpSpGetUtil

/**
 * Watch ↔ phone call features:
 *
 *  - Contacts on the watch, incl. SOS (emergency) contacts and the SOS call count.
 *    When SOS is pressed the watch itself dials its SOS contacts.
 *  - Call Bluetooth ("BT", Bluetooth Classic / HFP). The watch places that call through
 *    the phone over this link, so it must be paired and connected — BLE alone is not enough.
 *
 * All callbacks are delivered on the main thread.
 */
object PhoneFeatures {

    private const val TAG = "HBandPhone"
    private const val OP_TIMEOUT_MS = 15_000L
    private const val AUTO_PAIR_INTERVAL_MS = 30_000L
    private const val AUTO_PAIR_MAX_ATTEMPTS = 3

    private val main = Handler(Looper.getMainLooper())

    /** Receives every call-Bluetooth state change (see [btStateMap]). */
    var btListener: ((Map<String, Any?>) -> Unit)? = null

    private var btSupported: Boolean? = null
    private var lastBtInfo: BTInfo? = null
    private var btLink: String? = null // connecting · connected · disconnected · timeout
    private var opRunning = false
    private var autoPairAttempts = 0
    private var lastAutoPairAt = 0L
    private var autoPairPaused = false // user disconnected BT on purpose → wait for the next session
    private val autoPairRetry = Runnable { maybeAutoPair() }

    // ===================================================================
    // Call Bluetooth
    // ===================================================================

    /** Registers the SDK's BT listeners. The watch reports its BT state right after the password check. */
    fun init() {
        val manager = VPOperateManager.getInstance()
        manager.registerBTInfoListener(btInfoListener)
        manager.registerBTConnectionListener(btConnectionListener)
    }

    fun reset() {
        lastBtInfo = null
        btLink = null
        btSupported = null
        autoPairAttempts = 0
        main.removeCallbacks(autoPairRetry)
        main.removeCallbacks(defaultSosCallTimes)
    }

    /**
     * Called by [HBandManager] once the BLE session is ready (MAC saved, password checked).
     * The watch's first BT report arrives during the password sync, i.e. before this point,
     * so the auto-pair decision is (re)evaluated here as well as on every report.
     */
    fun onSessionReady() {
        autoPairAttempts = 0
        autoPairPaused = false
        main.removeCallbacks(autoPairRetry)
        maybeAutoPair()
        defaultAttempts = 0
        main.removeCallbacks(defaultSosCallTimes)
        // Let the first sync / app commands start first.
        main.postDelayed(defaultSosCallTimes, 5_000L)
    }

    // ===================================================================
    // Default SOS call count
    // ===================================================================

    /** SOS call count given to a newly paired watch. The factory value is often 3, so
     *  one SOS press made the watch dial its contact three times. */
    const val DEFAULT_SOS_CALL_TIMES = 1
    private const val DEFAULT_MAX_ATTEMPTS = 5
    private const val DEFAULT_RETRY_MS = 20_000L
    private var defaultAttempts = 0
    private val defaultSosCallTimes = Runnable { applyDefaultSosCallTimes() }

    /** Once per paired watch: SOS call count → [DEFAULT_SOS_CALL_TIMES]. A count changed later is kept. */
    private fun applyDefaultSosCallTimes() {
        val ctx = HBandManager.appContext() ?: return
        val watch = WatchSession.mac(ctx)
        if (!HBandManager.isReady() || watch.isEmpty() || WatchSession.sosDefaultAppliedFor(ctx) == watch) return
        defaultAttempts++
        readSosCallTimes(ctx) { value, error ->
            if (value == null) return@readSosCallTimes defaultFailed(ctx, watch, error)
            val current = value["times"] as? Int ?: 0
            val low = maxOf(value["min"] as? Int ?: 1, 1)
            val high = value["max"] as? Int ?: 0
            val wanted = if (high >= low) DEFAULT_SOS_CALL_TIMES.coerceIn(low, high) else DEFAULT_SOS_CALL_TIMES
            if (current == wanted) {
                WatchSession.setSosDefaultAppliedFor(ctx, watch)
                Log.i(TAG, "SOS call times already $current")
                return@readSosCallTimes
            }
            setSosCallTimes(ctx, wanted) { _, setError ->
                if (setError != null) return@setSosCallTimes defaultFailed(ctx, watch, setError)
                WatchSession.setSosDefaultAppliedFor(ctx, watch)
                Log.i(TAG, "SOS call times: $current -> $wanted (range $low-$high)")
                HBandManager.note("SOS call count set to $wanted (was $current)")
            }
        }
    }

    private fun defaultFailed(ctx: Context, watch: String, error: String?) {
        Log.w(TAG, "SOS call times default failed: $error (attempt $defaultAttempts)")
        when (error) {
            "UNSUPPORTED" -> WatchSession.setSosDefaultAppliedFor(ctx, watch) // nothing to set on this watch
            "BUSY", "TIMEOUT", "FAILED", "WRITE_FAILED" ->
                if (defaultAttempts < DEFAULT_MAX_ATTEMPTS) main.postDelayed(defaultSosCallTimes, DEFAULT_RETRY_MS)
            else -> Unit // NOT_READY → tried again at the next session ready
        }
    }

    /**
     * Auto-pairs call Bluetooth so the user never has to open the phone's Bluetooth settings.
     * The first time Android still shows its own "Pair with …?" dialog (one tap); after the
     * bond exists the SDK reconnects silently. Retries every 30 s, at most 3× per BLE session.
     */
    private fun maybeAutoPair() {
        val ctx = HBandManager.appContext() ?: return
        if (autoPairPaused || !WatchSession.isAutoPairBt(ctx) || !HBandManager.isReady()) return
        val info = lastBtInfo ?: return
        if (btSupported == false || info.status == BTInfo.BTStatus.CONNECTED) return
        if (!info.isBTOpen) {
            Log.i(TAG, "Auto-pair skipped: call Bluetooth is switched off on the watch")
            return
        }
        if (btLink == "connecting" || autoPairAttempts >= AUTO_PAIR_MAX_ATTEMPTS) return
        if (!hasConnectPermission(ctx)) {
            Log.w(TAG, "Auto-pair skipped: BLUETOOTH_CONNECT not granted")
            return
        }
        val wait = lastAutoPairAt + AUTO_PAIR_INTERVAL_MS - SystemClock.elapsedRealtime()
        if (wait > 0) {
            main.removeCallbacks(autoPairRetry)
            main.postDelayed(autoPairRetry, wait)
            return
        }
        autoPairAttempts++
        lastAutoPairAt = SystemClock.elapsedRealtime()
        HBandManager.note("Pairing call Bluetooth automatically (attempt $autoPairAttempts/$AUTO_PAIR_MAX_ATTEMPTS)")
        if (connectBt(ctx) != null) return
        // Re-check later in case the attempt times out without a new report.
        main.removeCallbacks(autoPairRetry)
        main.postDelayed(autoPairRetry, AUTO_PAIR_INTERVAL_MS)
    }

    private fun hasConnectPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    fun btState(context: Context): Map<String, Any?> = btStateMap(context)

    private var pendingBtRead: (() -> Unit)? = null

    fun readBtInfo(context: Context, done: (Map<String, Any?>?, String?) -> Unit) {
        if (!HBandManager.isReady()) return done(null, "NOT_READY")
        val finish = once(done)
        val timeout = Runnable { finish(btStateMap(context), null) }
        main.postDelayed(timeout, OP_TIMEOUT_MS)
        pendingBtRead = {
            main.removeCallbacks(timeout)
            finish(btStateMap(context), null)
        }
        VPOperateManager.getInstance().readBTInfo(IBleWriteResponse { code ->
            if (code != Code.REQUEST_SUCCESS) main.post {
                main.removeCallbacks(timeout)
                pendingBtRead = null
                finish(null, "WRITE_FAILED")
            }
        }, btInfoListener)
    }

    /**
     * Starts Bluetooth Classic pairing / connection with the watch. Android shows the system
     * pairing dialog the first time. Progress arrives through [btListener].
     */
    fun connectBt(context: Context): String? {
        if (!HBandManager.isReady()) return "NOT_READY"
        if (btSupported == false) return "UNSUPPORTED"
        autoPairPaused = false
        val mac = WatchSession.mac(context).takeIf { it.isNotEmpty() } ?: return "NOT_READY"
        VPOperateManager.getInstance().connectBT(mac, btConnectionListener)
        return null
    }

    fun disconnectBt(context: Context): String? {
        val mac = WatchSession.mac(context).takeIf { it.isNotEmpty() } ?: return "NOT_READY"
        autoPairPaused = true
        main.removeCallbacks(autoPairRetry)
        VPOperateManager.getInstance().disconnectBT(mac, btConnectionListener)
        return null
    }

    private val btInfoListener = object : IDeviceBTInfoListener {
        override fun onDeviceBTFunctionNotSupport() {
            main.post {
                btSupported = false
                publishBt()
            }
        }

        override fun onDeviceBTInfoSettingSuccess(btInfo: BTInfo) = onBtInfo(btInfo)
        override fun onDeviceBTInfoSettingFailed() {}
        override fun onDeviceBTInfoReadSuccess(btInfo: BTInfo) = onBtInfo(btInfo)
        override fun onDeviceBTInfoReadFailed() {
            main.post {
                pendingBtRead?.invoke()
                pendingBtRead = null
            }
        }

        override fun onDeviceBTInfoReport(btInfo: BTInfo) = onBtInfo(btInfo)
    }

    private fun onBtInfo(info: BTInfo) {
        main.post {
            val previous = lastBtInfo?.status
            btSupported = true
            lastBtInfo = info
            if (info.status == BTInfo.BTStatus.CONNECTED) btLink = "connected"
            else if (btLink == "connected") btLink = "disconnected"
            pendingBtRead?.invoke()
            pendingBtRead = null
            if (previous != info.status) {
                HBandManager.note(
                    if (info.status == BTInfo.BTStatus.CONNECTED) "Call Bluetooth connected — SOS calls go through this phone"
                    else "Call Bluetooth not connected (${info.status.name.lowercase()}) — the watch cannot place SOS calls"
                )
            }
            publishBt()
            if (info.status == BTInfo.BTStatus.CONNECTED) main.removeCallbacks(autoPairRetry)
            else maybeAutoPair()
        }
    }

    private val btConnectionListener = object : IDeviceBTConnectionListener {
        override fun onDeviceBTConnecting() = setLink("connecting")
        override fun onDeviceBTConnected() = setLink("connected")
        override fun onDeviceBTDisconnected() = setLink("disconnected")
        override fun onDeviceBTConnectTimeout() = setLink("timeout")
    }

    private fun setLink(link: String) {
        main.post {
            btLink = link
            publishBt()
            when (link) {
                "connected" -> main.removeCallbacks(autoPairRetry)
                "timeout", "disconnected" -> maybeAutoPair()
            }
        }
    }

    private fun publishBt() {
        val ctx = HBandManager.appContext() ?: return
        btListener?.invoke(btStateMap(ctx))
    }

    private fun btStateMap(context: Context): Map<String, Any?> {
        val info = lastBtInfo
        val supported = btSupported ?: flag { VpSpGetUtil.getVpSpVariInstance(context).isSupportBTFunction }
        return mapOf(
            "supported" to supported,
            "known" to (info != null),
            // disconnected · connected · broadcasting (= waiting to be paired)
            "status" to info?.status?.name?.lowercase(),
            "btOpen" to info?.isBTOpen,
            "autoConnect" to info?.isAutoCon,
            "audioOpen" to info?.isAudioOpen,
            "hasPairInfo" to info?.isHavePairInfo,
            "link" to btLink,
        )
    }

    // ===================================================================
    // Contacts / SOS contacts
    // ===================================================================

    fun contactSupport(context: Context): Map<String, Any?> {
        val sp = VpSpGetUtil.getVpSpVariInstance(context)
        return mapOf(
            "contacts" to flag { sp.isSupportContactFunction },
            "sosContacts" to flag { sp.isSupportSOSContactFunction },
            "contactType" to (try { sp.contactType } catch (_: Throwable) { 0 }),
        )
    }

    fun readContacts(context: Context, done: (List<Map<String, Any?>>?, String?) -> Unit) {
        val error = precheck(context)
        if (error != null) return done(null, error)
        runOp(done) { listener, response -> VPOperateManager.getInstance().readContact(-1, listener, response) }
    }

    fun addContact(
        context: Context,
        name: String,
        phone: String,
        sos: Boolean,
        done: (List<Map<String, Any?>>?, String?) -> Unit,
    ) {
        val error = precheck(context)
        if (error != null) return done(null, error)
        val sosSupported = flag { VpSpGetUtil.getVpSpVariInstance(context).isSupportSOSContactFunction }
        if (sos && !sosSupported) return done(null, "UNSUPPORTED")
        val contact = Contact(0, name, phone, sos && sosSupported, sosSupported)
        runOp(done) { listener, response -> VPOperateManager.getInstance().addContact(contact, listener, response) }
    }

    fun deleteContact(context: Context, id: Int, done: (List<Map<String, Any?>>?, String?) -> Unit) {
        withContact(context, id, done) { contact, listener, response ->
            VPOperateManager.getInstance().deleteContact(contact, listener, response)
        }
    }

    fun setSosContact(context: Context, id: Int, enabled: Boolean, done: (List<Map<String, Any?>>?, String?) -> Unit) {
        if (!flag { VpSpGetUtil.getVpSpVariInstance(context).isSupportSOSContactFunction }) {
            return done(null, "UNSUPPORTED")
        }
        withContact(context, id, done) { contact, listener, response ->
            VPOperateManager.getInstance().setContactSOSState(enabled, contact, listener, response)
        }
    }

    /** Reads the list first so the SDK gets the full contact (with its id) it expects. */
    private fun withContact(
        context: Context,
        id: Int,
        done: (List<Map<String, Any?>>?, String?) -> Unit,
        op: (Contact, IContactOptListener, IBleWriteResponse) -> Unit,
    ) {
        readContactsRaw(context) { list, error ->
            if (error != null) return@readContactsRaw done(null, error)
            val contact = list?.firstOrNull { it.contactID == id } ?: return@readContactsRaw done(null, "NOT_FOUND")
            runOp(done) { listener, response -> op(contact, listener, response) }
        }
    }

    private fun readContactsRaw(context: Context, done: (List<Contact>?, String?) -> Unit) {
        val error = precheck(context)
        if (error != null) return done(null, error)
        runRaw(done) { listener, response -> VPOperateManager.getInstance().readContact(-1, listener, response) }
    }

    fun readSosCallTimes(context: Context, done: (Map<String, Any?>?, String?) -> Unit) {
        val error = precheck(context, sos = true)
        if (error != null) return done(null, error)
        runCallTimes(done) { listener, response -> VPOperateManager.getInstance().readSOSCallTimes(listener, response) }
    }

    fun setSosCallTimes(context: Context, times: Int, done: (Map<String, Any?>?, String?) -> Unit) {
        val error = precheck(context, sos = true)
        if (error != null) return done(null, error)
        runCallTimes(done) { listener, response ->
            VPOperateManager.getInstance().setSOSCallTimes(times, listener, response)
        }
    }

    // ===================================================================
    // Plumbing
    // ===================================================================

    private fun precheck(context: Context, sos: Boolean = false): String? {
        if (!HBandManager.isReady()) return "NOT_READY"
        if (HBandManager.isBusy() || opRunning) return "BUSY"
        val sp = VpSpGetUtil.getVpSpVariInstance(context)
        val supported = if (sos) flag { sp.isSupportSOSContactFunction } else flag { sp.isSupportContactFunction }
        return if (supported) null else "UNSUPPORTED"
    }

    /** Runs a contact op; on success re-reads the list so callers always get the current contacts. */
    private fun runOp(
        done: (List<Map<String, Any?>>?, String?) -> Unit,
        op: (IContactOptListener, IBleWriteResponse) -> Unit,
    ) {
        runRaw({ list, error -> done(list?.map { it.toMap() }, error) }, op)
    }

    private fun runRaw(done: (List<Contact>?, String?) -> Unit, op: (IContactOptListener, IBleWriteResponse) -> Unit) {
        opRunning = true
        val finish = once<List<Contact>?> { list, error ->
            opRunning = false
            done(list, error)
        }
        val timeout = Runnable { finish(null, "TIMEOUT") }
        main.postDelayed(timeout, OP_TIMEOUT_MS)
        fun end(list: List<Contact>?, error: String?) {
            main.post {
                main.removeCallbacks(timeout)
                finish(list, error)
            }
        }

        val listener = object : IContactOptListener {
            override fun onContactOptSuccess(opt: EContactOpt, crc: Int) {
                if (opt == EContactOpt.READ) return
                // Re-read so the caller gets ids assigned by the watch.
                main.post {
                    VPOperateManager.getInstance().readContact(-1, this, IBleWriteResponse { code ->
                        if (code != Code.REQUEST_SUCCESS) end(null, "WRITE_FAILED")
                    })
                }
            }

            override fun onContactOptFailed(opt: EContactOpt) = end(null, "FAILED")
            override fun onContactReadSuccess(contactList: List<Contact>) = end(contactList, null)
            override fun onContactReadASSameCRC() = end(emptyList(), null)
            override fun onContactReadFailed() = end(null, "FAILED")
        }
        try {
            op(listener, IBleWriteResponse { code -> if (code != Code.REQUEST_SUCCESS) end(null, "WRITE_FAILED") })
        } catch (e: Exception) {
            Log.e(TAG, "contact op failed: $e")
            end(null, "FAILED")
        }
    }

    private fun runCallTimes(done: (Map<String, Any?>?, String?) -> Unit, op: (ISOSCallTimesListener, IBleWriteResponse) -> Unit) {
        opRunning = true
        val finish = once<Map<String, Any?>?> { value, error ->
            opRunning = false
            done(value, error)
        }
        val timeout = Runnable { finish(null, "TIMEOUT") }
        main.postDelayed(timeout, OP_TIMEOUT_MS)
        fun end(value: Map<String, Any?>?, error: String?) {
            main.post {
                main.removeCallbacks(timeout)
                finish(value, error)
            }
        }

        val listener = object : ISOSCallTimesListener {
            override fun onSOSCallTimesSettingSuccess(times: Int) = end(mapOf("times" to times), null)
            override fun onSOSCallTimesSettingFailed() = end(null, "FAILED")
            override fun onSOSCallTimesReadSuccess(times: Int, minTimes: Int, maxTimes: Int) =
                end(mapOf("times" to times, "min" to minTimes, "max" to maxTimes), null)

            override fun onSOSCallTimesReadFailed() = end(null, "FAILED")
        }
        try {
            op(listener, IBleWriteResponse { code -> if (code != Code.REQUEST_SUCCESS) end(null, "WRITE_FAILED") })
        } catch (e: Exception) {
            Log.e(TAG, "SOS call times op failed: $e")
            end(null, "FAILED")
        }
    }

    private fun <T> once(done: (T, String?) -> Unit): (T, String?) -> Unit {
        var called = false
        return { value, error ->
            if (!called) {
                called = true
                done(value, error)
            }
        }
    }

    private fun Contact.toMap(): Map<String, Any?> = mapOf(
        "id" to contactID,
        "name" to name,
        "phone" to phoneNumber,
        "sos" to isSettingSOS,
    )

    private inline fun flag(block: () -> Boolean): Boolean = try {
        block()
    } catch (_: Throwable) {
        false
    }
}
