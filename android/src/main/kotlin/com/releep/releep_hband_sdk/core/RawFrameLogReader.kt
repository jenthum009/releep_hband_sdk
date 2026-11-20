package com.releep.releep_hband_sdk.core

import com.inuker.bluetooth.library.log.LogType
import com.inuker.bluetooth.library.log.VPLocalLogger
import java.io.File
import java.io.RandomAccessFile

/**
 * Reads the tail of the SDK's own BLE log files. With VPLocalLogger running,
 * the vpbluetooth SDK writes every frame the watch sends to ble_change.txt
 * and every command the app sends to ble_write.txt.
 */
object RawFrameLogReader {

    private const val TAIL_BYTES = 64 * 1024

    /** Last [maxLines] frames the watch sent, newest last; null if unavailable. */
    fun incoming(maxLines: Int): List<String>? = read(LogType.BLE_CHANGE, maxLines)

    /** Last [maxLines] commands the app sent to the watch, newest last. */
    fun outgoing(maxLines: Int): List<String>? = read(LogType.BLE_WRITE, maxLines)

    private fun read(type: LogType, maxLines: Int): List<String>? = try {
        readTail(VPLocalLogger.getInstance().getFilePathByLogType(type), maxLines)
    } catch (t: Throwable) {
        null
    }

    private fun readTail(path: String?, maxLines: Int): List<String>? {
        if (path == null) return null
        val file = File(path)
        if (!file.exists() || file.length() == 0L) return null
        RandomAccessFile(file, "r").use { raf ->
            val length = file.length()
            val start = maxOf(0L, length - TAIL_BYTES)
            raf.seek(start)
            val buf = ByteArray((length - start).toInt())
            raf.readFully(buf)
            val lines = String(buf, Charsets.UTF_8).split("\n")
            // Skip the first line if we started mid-file (it may be partial).
            val from = maxOf(if (start > 0) 1 else 0, lines.size - maxLines)
            return lines.subList(minOf(from, lines.size), lines.size)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }
    }
}
