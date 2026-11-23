package io.remls.transcripts

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager

// Keeps the app's process and CPU awake while a job runs, behind an ongoing
// notification that shows the job's status.
class JobService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Working"
        startForeground(
            NOTIFICATION_ID,
            statusNotification(this, text),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "transcripts:jobs")
                .apply { acquire(MAX_AWAKE_MS) }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TEXT = "text"
        const val STATUS_CHANNEL = "jobs"
        const val RESULT_CHANNEL = "results"
        private const val NOTIFICATION_ID = 1
        private const val MAX_AWAKE_MS = 6L * 60 * 60 * 1000

        fun createChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(STATUS_CHANNEL, "Running jobs", NotificationManager.IMPORTANCE_LOW),
            )
            manager.createNotificationChannel(
                NotificationChannel(RESULT_CHANNEL, "Finished jobs", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }

        private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )

        fun statusNotification(context: Context, text: String): Notification =
            Notification.Builder(context, STATUS_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_lines)
                .setContentTitle("Transcripts is working")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(openApp(context))
                .build()

        fun resultNotification(context: Context, title: String, text: String): Notification =
            Notification.Builder(context, RESULT_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_lines)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .setContentIntent(openApp(context))
                .build()
    }
}
