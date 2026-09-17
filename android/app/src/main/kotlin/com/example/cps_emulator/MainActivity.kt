package com.example.cps_emulator

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts Flutter plus the `gotta.bike/keep_alive` channel that drives
 * [BroadcastKeepAliveService] (see `lib/screen_off_mode.dart`).
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "gotta.bike/keep_alive"
        private const val NOTIFICATION_PERMISSION_REQUEST = 0x1818
    }

    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "notificationsAllowed" -> result.success(notificationsAllowed())
                "requestNotifications" -> requestNotifications(result)
                "start" -> startKeepAlive(
                    call.argument<String>("title").orEmpty(),
                    call.argument<String>("text").orEmpty(),
                    result,
                )
                "stop" -> {
                    stopKeepAlive()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        this.channel = channel
        BroadcastKeepAliveService.onStopRequested = {
            runOnUiThread { this.channel?.invokeMethod("stopRequested", null) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        BroadcastKeepAliveService.onStopRequested = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // The broadcast lives in this activity's Flutter engine, so leaving
        // the app ends it.
        if (isFinishing) stopKeepAlive()
        super.onDestroy()
    }

    private fun startKeepAlive(title: String, text: String, result: MethodChannel.Result) {
        var replied = false
        fun reply(error: String?) {
            if (replied) return
            replied = true
            BroadcastKeepAliveService.onStartResult = null
            result.success(error)
        }
        BroadcastKeepAliveService.onStartResult = { error -> runOnUiThread { reply(error) } }
        try {
            startService(
                Intent(this, BroadcastKeepAliveService::class.java)
                    .setAction(BroadcastKeepAliveService.ACTION_START)
                    .putExtra(BroadcastKeepAliveService.EXTRA_TITLE, title)
                    .putExtra(BroadcastKeepAliveService.EXTRA_TEXT, text),
            )
        } catch (e: Exception) {
            // IllegalStateException when the app is no longer in the foreground.
            reply(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun stopKeepAlive() {
        stopService(Intent(this, BroadcastKeepAliveService::class.java))
    }

    // Covers both the Android 13+ runtime permission and the app's
    // notification toggle in system settings.
    private fun notificationsAllowed(): Boolean =
        getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(notificationsAllowed())
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "A notification permission request is already open.", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            pendingPermissionResult?.success(notificationsAllowed())
            pendingPermissionResult = null
        }
    }
}
