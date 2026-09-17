package com.example.cps_emulator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * "Keep broadcasting with screen off": a `connectedDevice` foreground service
 * holding a partial wake lock, so Android neither freezes the app process nor
 * lets the CPU sleep while the screen is off. All BLE work stays in the main
 * Flutter engine (its 500 ms notify timer keeps running); this service only
 * shows the ongoing notification. It deliberately runs no Dart: a second
 * Flutter engine would attach every plugin again, and universal_ble clears
 * its process-wide GATT caches when that engine is destroyed.
 *
 * It is started with startService() while the app is in the foreground and
 * promotes itself with startForeground(). If promotion fails (e.g. a missing
 * permission) it reports the error and stops, which is safe; a service
 * started with startForegroundService() would crash the app instead.
 */
class BroadcastKeepAliveService : Service() {

    companion object {
        private const val TAG = "BroadcastKeepAlive"

        const val ACTION_START = "com.example.cps_emulator.action.KEEP_ALIVE_START"
        private const val ACTION_STOP_BROADCAST =
            "com.example.cps_emulator.action.STOP_BROADCAST"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        private const val CHANNEL_ID = "broadcasting"
        private const val NOTIFICATION_ID = 0x1818
        private const val WAKE_LOCK_TAG = "GottaBikeWatts:broadcast"

        // A safety net for a lock that is somehow never released.
        private const val WAKE_LOCK_TIMEOUT_MS = 12 * 60 * 60 * 1000L

        /** Receives the outcome of an ACTION_START: null = running. */
        var onStartResult: ((String?) -> Unit)? = null

        /** The user tapped Stop in the notification. */
        var onStopRequested: (() -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_STOP_BROADCAST -> {
                // Flutter stops advertising and then this service; stop here
                // too in case the Flutter side is gone.
                onStopRequested?.invoke()
                stopSelf()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun start(intent: Intent) {
        val error = try {
            val notification = buildNotification(
                intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                intent.getStringExtra(EXTRA_TEXT).orEmpty(),
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireWakeLock()
            null
        } catch (e: Exception) {
            // SecurityException (Android 14+ needs a granted Bluetooth
            // permission for this type) or ForegroundServiceStartNotAllowed.
            Log.e(TAG, "Could not start in the foreground", e)
            stopSelf()
            e.message ?: e.javaClass.simpleName
        }
        onStartResult?.invoke(error)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Broadcasting",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Shown while the sensor broadcasts with the screen off."
                        setShowBadge(false)
                    },
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val openApp = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, flags)
        }
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, BroadcastKeepAliveService::class.java)
                .setAction(ACTION_STOP_BROADCAST),
            flags,
        )

        builder
            .setSmallIcon(R.drawable.ic_stat_broadcast)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null as Icon?, "Stop", stop).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The app was swiped away: its Flutter engine, and so the broadcast,
        // is gone.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
