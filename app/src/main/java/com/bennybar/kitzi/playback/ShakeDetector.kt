package com.bennybar.kitzi.playback

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlin.math.sqrt

/**
 * A deliberate shake: two strong jolts within half a second. Only listens while
 * started — the sleep timer starts it for the last minute of a timer, so the
 * accelerometer isn't kept awake the rest of the time.
 */
class ShakeDetector(context: Context) : SensorEventListener {

    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private var onShake: (() -> Unit)? = null
    private var lastJoltAt = 0L
    private var lastShakeAt = 0L

    fun start(onShake: () -> Unit) {
        if (this.onShake != null) return
        val sensor = accelerometer ?: return
        this.onShake = onShake
        sensors.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
    }

    fun stop() {
        if (onShake == null) return
        onShake = null
        sensors.unregisterListener(this)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val (x, y, z) = event.values
        val g = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
        if (g < JOLT_G) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastShakeAt < COOLDOWN_MS) return
        if (now - lastJoltAt <= PAIR_WINDOW_MS) {
            lastShakeAt = now
            onShake?.invoke()
        }
        lastJoltAt = now
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private companion object {
        const val JOLT_G = 2.5f
        const val PAIR_WINDOW_MS = 500L
        const val COOLDOWN_MS = 1_500L
    }
}
