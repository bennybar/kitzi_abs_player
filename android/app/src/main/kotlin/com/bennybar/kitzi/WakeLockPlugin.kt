package com.bennybar.kitzi

import android.content.Context
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class WakeLockPlugin: FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var wakeLock: PowerManager.WakeLock? = null
    private var partialWakeLock: PowerManager.WakeLock? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.bennybar.kitzi/wake_lock")
        channel.setMethodCallHandler(this)
        context = binding.applicationContext
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "acquireWakeLock" -> {
                acquireWakeLock()
                result.success(null)
            }
            "releaseWakeLock" -> {
                releaseWakeLock()
                result.success(null)
            }
            "acquirePartialWakeLock" -> {
                acquirePartialWakeLock()
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun acquireWakeLock() {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE,
            "Kitzi:WakeLock"
        )
        wakeLock?.acquire(10*60*1000L) // 10 minutes timeout
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
    }

    private fun acquirePartialWakeLock() {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        partialWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Kitzi:PartialWakeLock"
        )
        partialWakeLock?.acquire()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        releaseWakeLock()
        partialWakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
    }
}
