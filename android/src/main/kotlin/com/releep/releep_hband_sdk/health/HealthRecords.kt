package com.releep.releep_hband_sdk.health

import com.veepoo.protocol.model.datas.TimeData
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Builds records in the exact shape of the backend `data[]` items
 * (`api/smartwatch_vp_insert/{type}`):
 * - `time` = local (Thai) time "yyyy-MM-dd HH:mm:ss", no timezone suffix
 * - `source` = "online" (measured now) / "offline" (synced history)
 */
object HealthRecords {

    // Backend `{type}` names.
    const val HEART_RATE = "heartrate"
    const val SPO2 = "spo2"
    const val BLOOD_PRESSURE = "bloodpressure"
    const val BODY_TEMP = "bodytemp"
    const val RESPIRATORY = "respiratory"
    const val HRV = "hrv"
    const val FATIGUE = "fatigue"
    const val STEP_COUNT = "stepcount"
    const val CALORIE = "calorie"
    const val BATTERY = "battery"
    const val SLEEP = "sleep"
    const val SPORT = "sport"
    const val ECG = "ecg"
    const val BLOOD_GLUCOSE = "bloodglucose"
    const val RR_INTERVAL = "rrinterval"
    const val HEART_WARNING = "heartwarning"
    const val STRESS = "stress"

    val ALL_TYPES = listOf(
        HEART_RATE, SPO2, BLOOD_PRESSURE, BODY_TEMP, RESPIRATORY, HRV, FATIGUE, STEP_COUNT,
        CALORIE, BATTERY, SLEEP, SPORT, ECG, BLOOD_GLUCOSE, RR_INTERVAL, HEART_WARNING, STRESS,
    )

    const val ONLINE = "online"
    const val OFFLINE = "offline"

    /** Backend limit for ECG / RR arrays. */
    const val MAX_ARRAY = 200_000

    private fun format() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    fun now(): String = format().format(Date())

    fun format(millis: Long): String = format().format(Date(millis))

    /** [date] "yyyy-MM-dd" is used when [time] carries no year (5-minute data). */
    fun time(date: String?, time: TimeData?): String? {
        if (time == null) return null
        if (time.year > 0 && time.month > 0 && time.day > 0) {
            return String.format(
                Locale.US, "%04d-%02d-%02d %02d:%02d:%02d",
                time.year, time.month, time.day, time.hour, time.minute, time.second,
            )
        }
        val d = date?.takeIf { it.length >= 10 }?.substring(0, 10) ?: return null
        return String.format(Locale.US, "%s %02d:%02d:00", d, time.hour, time.minute)
    }

    fun millis(time: TimeData?): Long? {
        if (time == null || time.year <= 0) return null
        return Calendar.getInstance().apply {
            set(time.year, time.month - 1, time.day, time.hour, time.minute, time.second)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    fun averageNonZero(values: IntArray?): Int? {
        val v = values?.filter { it > 0 } ?: return null
        return if (v.isEmpty()) null else v.average().toInt()
    }

    fun clip(values: IntArray?): List<Int>? =
        values?.takeIf { it.isNotEmpty() }?.let { it.take(MAX_ARRAY) }

    /** Fatigue value (SDK) → backend status good / middle / bad. */
    fun fatigueStatus(value: Int): String = when {
        value <= 1 -> "good"
        value == 2 -> "middle"
        else -> "bad"
    }

    /** Stress 0–100 (SDK scale) → backend status. */
    fun stressStatus(value: Int): String = when {
        value < 40 -> "good"
        value < 70 -> "middle"
        else -> "bad"
    }
}

/**
 * Collects records per type; a later record with the same `time` replaces the
 * earlier one (the backend also de-duplicates on `time`).
 */
class RecordBag {
    private val byType = LinkedHashMap<String, LinkedHashMap<String, MutableMap<String, Any?>>>()

    fun put(type: String, record: MutableMap<String, Any?>, key: String? = null) {
        val k = key ?: (record["time"] ?: record["startTime"])?.toString() ?: return
        byType.getOrPut(type) { LinkedHashMap() }[k] = record
    }

    /** Adds only if nothing is stored for that time yet. */
    fun putIfAbsent(type: String, record: MutableMap<String, Any?>) {
        val k = record["time"]?.toString() ?: return
        val bucket = byType.getOrPut(type) { LinkedHashMap() }
        if (!bucket.containsKey(k)) bucket[k] = record
    }

    fun records(type: String): List<MutableMap<String, Any?>> = byType[type]?.values?.toList() ?: emptyList()

    fun toMap(): Map<String, List<Map<String, Any?>>> =
        byType.mapValues { (_, v) -> v.values.sortedBy { (it["time"] ?: it["startTime"]).toString() } }

    fun counts(): Map<String, Int> = byType.mapValues { it.value.size }
}
