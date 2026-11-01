package dev.baseplatform.base_models

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app running while long work is in progress, model downloads and
 * on-device AI answers: an ongoing notification ("PhoneDots · downloading
 * Gemma 4 E2B · 34%") from a foreground service, plus a partial wake lock, so
 * Android neither pauses the app when it goes to the background nor lets the
 * phone sleep mid-download or mid-answer. Everything is counted: the service
 * stops when the last job ends.
 *
 * ```kotlin
 * KeepAwake.during(context, "download", "downloading Gemma 4 E2B") { update -> ... update(0.4) ... }
 * ```
 *
 * Synced from baseApp (packages/base_models/android); change it there.
 */
object KeepAwake {
    /** What the work is, for the right foreground-service type on Android 14+. */
    enum class Kind { DOWNLOAD, AI }

    private data class Job(val kind: Kind, val text: String, val progress: Double?)

    private val jobs = LinkedHashMap<String, Job>()
    private var wakeLock: PowerManager.WakeLock? = null

    /** Starts (or updates) [key]; the notification shows the newest job. */
    @Synchronized
    fun begin(context: Context, key: String, text: String, kind: Kind = Kind.DOWNLOAD) {
        jobs[key] = Job(kind, text, null)
        refresh(context.applicationContext)
    }

    /** Progress 0..1 for [key] (shown as a bar and a percentage). */
    @Synchronized
    fun update(context: Context, key: String, progress: Double?, text: String? = null) {
        val job = jobs[key] ?: return
        val next = job.copy(progress = progress, text = text ?: job.text)
        val percentMoved = ((next.progress ?: 0.0) * 100).toInt() != ((job.progress ?: 0.0) * 100).toInt()
        jobs[key] = next
        if (percentMoved || text != null) refresh(context.applicationContext)
    }

    @Synchronized
    fun end(context: Context, key: String) {
        if (jobs.remove(key) == null) return
        refresh(context.applicationContext)
    }

    /** Runs [block] with [key] kept awake; [block] gets an update(progress) function. */
    fun <T> during(context: Context, key: String, text: String, kind: Kind = Kind.DOWNLOAD, block: ((Double?) -> Unit) -> T): T {
        begin(context, key, text, kind)
        try {
            return block { p -> update(context, key, p) }
        } finally {
            end(context, key)
        }
    }

    @Synchronized
    fun isActive() = jobs.isNotEmpty()

    private fun refresh(context: Context) {
        if (jobs.isEmpty()) {
            context.stopService(Intent(context, KeepAwakeService::class.java))
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            return
        }
        if (wakeLock == null) {
            val pm = context.getSystemService(PowerManager::class.java)
            // Bounded, in case an app never ends a job; renewed with every refresh.
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "${context.packageName}:keepawake").apply { setReferenceCounted(false) }
        }
        wakeLock?.acquire(60 * 60 * 1000L)
        val intent = Intent(context, KeepAwakeService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        } catch (e: Exception) {
            // Android 12+ refuses a foreground start from the background; the wake
            // lock still holds, and the next start from the foreground shows it.
        }
        KeepAwakeService.current?.show()
    }

    internal fun notification(context: Context): Pair<Notification, Int> {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Downloads and answers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while a model downloads or the AI writes an answer, so the work isn't stopped."
                setShowBadge(false)
            })
        }
        val (job, count, type) = synchronized(this) {
            val newest = jobs.values.lastOrNull()
            val type = if (jobs.values.any { it.kind == Kind.AI }) Kind.AI else Kind.DOWNLOAD
            Triple(newest, jobs.size, type)
        }
        val app = context.applicationInfo.loadLabel(context.packageManager).toString()
        val percent = job?.progress?.let { (it.coerceIn(0.0, 1.0) * 100).toInt() }
        val title = buildString {
            append(app)
            append(" · ")
            append(job?.text ?: "working")
            if (percent != null) append(" · $percent%")
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        builder
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(if (count > 1) "and ${count - 1} more; keep going in the background" else "keeps going in the background")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent ?: 0, percent == null)
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            builder.setContentIntent(android.app.PendingIntent.getActivity(context, 0, launch, android.app.PendingIntent.FLAG_IMMUTABLE))
        }
        val serviceType = when {
            Build.VERSION.SDK_INT < 29 -> 0
            type == Kind.AI && Build.VERSION.SDK_INT >= 34 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        }
        return builder.build() to serviceType
    }

    internal const val CHANNEL = "base.keepawake"
    internal const val ID = 0x4b41 // "KA"
}

/** The foreground service behind [KeepAwake]. Declared in this library's manifest. */
class KeepAwakeService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        show()
        if (!KeepAwake.isActive()) stopSelf()
        return START_NOT_STICKY
    }

    fun show() {
        val (notification, type) = KeepAwake.notification(this)
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(KeepAwake.ID, notification, type) else startForeground(KeepAwake.ID, notification)
        } catch (e: Exception) {
            // Not allowed right now (started from the background on Android 12+).
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    /** Android 15 caps dataSync time; when it runs out, stop rather than be killed. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    companion object {
        @Volatile
        internal var current: KeepAwakeService? = null
    }
}
