package com.bennybar.kitzi.data

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/**
 * A 15-minute diagnostic logger: captures this app's logcat output to a file in
 * app storage while a session is active, auto-stopping after 15 minutes. Backs
 * the `logging_session_active` setting — the Kotlin equivalent of Flutter's
 * session_logger_service.
 */
object SessionLogger {
    private const val MAX_DURATION_MS = 15L * 60 * 1000

    private val scope = CoroutineScope(SupervisorJob())
    private var process: Process? = null
    private var stopJob: Job? = null

    var currentFile: File? = null
        private set

    val isRunning: Boolean get() = process != null

    fun start(context: Context) {
        if (process != null) return
        val file = File(context.filesDir, "kitzi-session-log-${System.currentTimeMillis()}.txt")
        currentFile = file
        runCatching {
            val pid = android.os.Process.myPid()
            process = ProcessBuilder("logcat", "-v", "time", "--pid=$pid")
                .redirectErrorStream(true)
                .redirectOutput(file)
                .start()
        }.onFailure { currentFile = null }

        stopJob = scope.launch {
            delay(MAX_DURATION_MS)
            stop()
            runCatching { Services.prefs.putBoolean("logging_session_active", false) }
        }
    }

    fun stop() {
        stopJob?.cancel(); stopJob = null
        process?.destroy(); process = null
    }

    /** Existing session-log files, newest first. */
    fun logFiles(context: Context): List<File> =
        context.filesDir.listFiles { f -> f.name.startsWith("kitzi-session-log-") }
            ?.sortedByDescending { it.lastModified() }
            .orEmpty()

    fun clearLogs(context: Context) {
        stop()
        logFiles(context).forEach { it.delete() }
        currentFile = null
    }
}
