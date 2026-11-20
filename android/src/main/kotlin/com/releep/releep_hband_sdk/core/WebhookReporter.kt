package com.releep.releep_hband_sdk.core

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Date
import java.util.concurrent.Executors

/**
 * Posts watch events as JSON to a configurable webhook. Runs natively so
 * events are delivered even while the Flutter UI is not running (background
 * guard). URL + on/off switch are persisted.
 */
object WebhookReporter {

    private const val TAG = "HBandWebhook"
    private const val PREFS = "releep_hband_webhook"
    private const val KEY_URL = "url"
    private const val KEY_ENABLED = "enabled"

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun interface Callback {
        fun onResult(success: Boolean, httpCode: Int, message: String)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun url(context: Context): String = prefs(context).getString(KEY_URL, "") ?: ""

    /** Delivery needs both the switch ON and a URL configured. */
    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false) && url(context).isNotEmpty()

    fun configure(context: Context, url: String?, enabled: Boolean?) {
        val editor = prefs(context).edit()
        if (url != null) editor.putString(KEY_URL, url.trim())
        if (enabled != null) editor.putBoolean(KEY_ENABLED, enabled)
        editor.apply()
    }

    fun toMap(context: Context): Map<String, Any?> = mapOf(
        "url" to url(context),
        "enabled" to prefs(context).getBoolean(KEY_ENABLED, false),
    )

    /**
     * Fire-and-forget POST. Body = {event, timestamp, timestampIso, ...payload}.
     * When [force] is true the on/off switch is ignored (used by "test webhook").
     */
    fun report(
        context: Context,
        eventType: String,
        payload: JSONObject?,
        force: Boolean = false,
        callback: Callback? = null,
    ) {
        val target = url(context)
        if (target.isEmpty() || (!force && !isEnabled(context))) {
            callback?.let { cb -> mainHandler.post { cb.onResult(false, 0, "webhook off") } }
            return
        }
        val body = JSONObject()
        body.put("event", eventType)
        body.put("timestamp", System.currentTimeMillis())
        body.put("timestampIso", Date().toString())
        body.put("platform", "android")
        payload?.keys()?.forEach { key -> body.put(key, payload.opt(key)) }
        executor.execute { post(target, body.toString(), callback) }
    }

    private fun post(target: String, json: String, callback: Callback?) {
        var connection: HttpURLConnection? = null
        var code = -1
        var error: String? = null
        try {
            connection = (URL(target).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
            connection.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            code = connection.responseCode
        } catch (e: Exception) {
            error = e.message ?: e.javaClass.simpleName
            Log.e(TAG, "POST failed: $e")
        } finally {
            connection?.disconnect()
        }
        val success = code in 200..299
        Log.i(TAG, (if (success) "OK" else "FAIL") + " http=$code" + (error?.let { " err=$it" } ?: ""))
        callback?.let { cb ->
            mainHandler.post {
                cb.onResult(success, code, if (success) "HTTP $code" else (error ?: "HTTP $code"))
            }
        }
    }
}
