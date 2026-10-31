package ai.phonedots.phonedots

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.BatteryManager
import android.os.StatFs
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeParseException

/** Phone actions for skills. Anything that sends or calls opens a composer for the user to finish. */
class DeviceBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

  init {
    MethodChannel(messenger, "phonedots/device").setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "invoke") return result.notImplemented()
    val action = call.argument<String>("action")!!
    val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
    if (action == "video.frames") {
      // Decoding frames takes a moment; keep it off the UI thread.
      Thread {
        val out = try {
          videoSheet(args.str("path"), args.int("frames", 6))
        } catch (e: Throwable) {
          mapOf("error" to (e.message ?: e.javaClass.simpleName))
        }
        activity.runOnUiThread { result.success(out) }
      }.start()
      return
    }
    val out = try {
      invoke(action, args)
    } catch (e: ActivityNotFoundException) {
      mapOf("error" to "No app on this phone can handle that.")
    } catch (e: SecurityException) {
      mapOf("error" to "Permission denied: ${e.message}")
    } catch (e: Throwable) {
      mapOf("error" to (e.message ?: e.javaClass.simpleName))
    }
    result.success(out)
  }

  private fun Map<String, Any?>.str(k: String, d: String = "") = (this[k] ?: d).toString()
  private fun Map<String, Any?>.int(k: String, d: Int = 0) = (this[k] as? Number)?.toInt() ?: this[k]?.toString()?.toIntOrNull() ?: d

  private fun start(intent: Intent, done: String): Map<String, Any?> {
    activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    return mapOf("ok" to true, "message" to done)
  }

  /** Requests [permission] if needed; returns an error map when not yet granted. */
  private fun need(permission: String, what: String): Map<String, Any?>? {
    if (activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return null
    activity.requestPermissions(arrayOf(permission), 7)
    return mapOf("error" to "Allow $what access in the prompt, then ask again.")
  }

  private fun millis(iso: String): Long = try {
    LocalDateTime.parse(iso.take(19)).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
  } catch (e: DateTimeParseException) {
    throw IllegalArgumentException("Could not read the date \"$iso\"")
  }

  private fun invoke(action: String, a: Map<String, Any?>): Map<String, Any?> = when (action) {
    "timer.set" -> start(
      Intent(AlarmClock.ACTION_SET_TIMER)
        .putExtra(AlarmClock.EXTRA_LENGTH, a.int("seconds"))
        .putExtra(AlarmClock.EXTRA_MESSAGE, a.str("label", "PhoneDots"))
        .putExtra(AlarmClock.EXTRA_SKIP_UI, true),
      "Timer started",
    )
    "alarm.set" -> start(
      Intent(AlarmClock.ACTION_SET_ALARM)
        .putExtra(AlarmClock.EXTRA_HOUR, a.int("hour"))
        .putExtra(AlarmClock.EXTRA_MINUTES, a.int("minute"))
        .putExtra(AlarmClock.EXTRA_MESSAGE, a.str("label", "PhoneDots"))
        .putExtra(AlarmClock.EXTRA_SKIP_UI, true),
      "Alarm set",
    )
    "calendar.create" -> {
      val begin = millis(a.str("start"))
      val end = if (a.str("end").isNotEmpty()) millis(a.str("end")) else begin + 3_600_000
      start(
        Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
          .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
          .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
          .putExtra(CalendarContract.Events.TITLE, a.str("title"))
          .putExtra(CalendarContract.Events.EVENT_LOCATION, a.str("location"))
          .putExtra(CalendarContract.Events.DESCRIPTION, a.str("notes")),
        "Opened the calendar with the event ready to save",
      )
    }
    "calendar.list" -> need(Manifest.permission.READ_CALENDAR, "calendar") ?: listEvents(a.int("days", 1))
    "contacts.search" -> need(Manifest.permission.READ_CONTACTS, "contacts") ?: searchContacts(a.str("name"))
    "phone.dial" -> start(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(a.str("number"))}")), "Dialer opened")
    "sms.compose" -> start(
      Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(a.str("to"))}")).putExtra("sms_body", a.str("body")),
      "Message drafted. Tap send in Messages.",
    )
    "email.compose" -> start(
      Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${Uri.encode(a.str("to"))}"))
        .putExtra(Intent.EXTRA_SUBJECT, a.str("subject"))
        .putExtra(Intent.EXTRA_TEXT, a.str("body")),
      "Email drafted",
    )
    "app.open" -> openApp(a.str("name"))
    "url.open" -> start(Intent(Intent.ACTION_VIEW, Uri.parse(a.str("url"))), "Opened")
    "maps.navigate" -> {
      val mode = when (a.str("mode")) { "walking" -> "w"; "cycling" -> "b"; "transit" -> "r"; else -> "d" }
      try {
        start(Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${Uri.encode(a.str("destination"))}&mode=$mode")), "Navigation started")
      } catch (e: ActivityNotFoundException) {
        start(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${Uri.encode(a.str("destination"))}")), "Opened in maps")
      }
    }
    "torch" -> {
      val cm = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      val id = cm.cameraIdList.firstOrNull { cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true }
        ?: return mapOf("error" to "This phone has no flashlight")
      val on = a["on"] == true || a["on"].toString() == "true"
      cm.setTorchMode(id, on)
      mapOf("ok" to true, "on" to on)
    }
    "settings.open" -> start(
      Intent(
        when (a.str("page")) {
          "wifi" -> Settings.ACTION_WIFI_SETTINGS
          "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
          "dnd" -> "android.settings.ZEN_MODE_SETTINGS"
          "display" -> Settings.ACTION_DISPLAY_SETTINGS
          "sound" -> Settings.ACTION_SOUND_SETTINGS
          "battery" -> Intent.ACTION_POWER_USAGE_SUMMARY
          "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
          "apps" -> Settings.ACTION_APPLICATION_SETTINGS
          "app" -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
          else -> Settings.ACTION_SETTINGS
        }
      ).apply { if (a.str("page") == "app") data = Uri.parse("package:${activity.packageName}") },
      "Settings opened",
    )
    "volume.set" -> {
      val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
      val stream = when (a.str("stream")) { "ring" -> AudioManager.STREAM_RING; "alarm" -> AudioManager.STREAM_ALARM; else -> AudioManager.STREAM_MUSIC }
      val max = am.getStreamMaxVolume(stream)
      am.setStreamVolume(stream, (max * a.int("percent").coerceIn(0, 100) / 100.0).toInt(), AudioManager.FLAG_SHOW_UI)
      mapOf("ok" to true)
    }
    "battery" -> {
      val bm = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
      mapOf("level" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY), "charging" to bm.isCharging)
    }
    "storage" -> {
      val s = StatFs(activity.filesDir.path)
      val gb = 1_000_000_000.0
      val free = s.availableBytes / gb
      val total = s.totalBytes / gb
      mapOf("free_gb" to "%.1f".format(free), "total_gb" to "%.1f".format(total), "summary" to "%.1f GB free of %.0f GB.".format(free, total))
    }
    "share.text" -> {
      val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, a.str("text"))
      start(Intent.createChooser(send, null), "Share sheet opened")
    }
    else -> mapOf("error" to "Unknown action $action")
  }

  /** Grabs evenly spaced frames from a video and lays them out in one contact-sheet JPEG for Gemma. */
  private fun videoSheet(path: String, count: Int): Map<String, Any?> {
    val r = MediaMetadataRetriever()
    try {
      r.setDataSource(path)
      if (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") return mapOf("error" to "No video track")
      val durationMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
      val n = count.coerceIn(1, 9)
      val frames = (0 until n).mapNotNull { i ->
        val t = (durationMs * (i + 0.5) / n).toLong() * 1000
        r.getFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
      }
      if (frames.isEmpty()) return mapOf("error" to "Could not read frames")
      val cols = if (frames.size <= 4) 2 else 3
      val rows = (frames.size + cols - 1) / cols
      val cell = 1024 / cols
      val first = frames.first()
      val cellH = (cell * first.height.toFloat() / first.width).toInt().coerceIn(cell / 2, cell * 2)
      val sheet = Bitmap.createBitmap(cell * cols, cellH * rows, Bitmap.Config.ARGB_8888)
      val canvas = Canvas(sheet)
      canvas.drawColor(Color.BLACK)
      frames.forEachIndexed { i, f ->
        val x = (i % cols) * cell
        val y = (i / cols) * cellH
        canvas.drawBitmap(f, null, Rect(x, y, x + cell, y + cellH), null)
        f.recycle()
      }
      val out = File(activity.cacheDir, "frames-${System.currentTimeMillis()}.jpg")
      out.outputStream().use { sheet.compress(Bitmap.CompressFormat.JPEG, 85, it) }
      sheet.recycle()
      return mapOf("path" to out.path, "frames" to frames.size, "duration" to durationMs / 1000.0)
    } finally {
      r.release()
    }
  }

  private fun listEvents(days: Int): Map<String, Any?> {
    val now = System.currentTimeMillis()
    val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
      android.content.ContentUris.appendId(it, now)
      android.content.ContentUris.appendId(it, now + days.coerceIn(1, 31) * 86_400_000L)
    }.build()
    val events = mutableListOf<Map<String, Any?>>()
    activity.contentResolver.query(
      uri,
      arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.EVENT_LOCATION),
      null, null, "${CalendarContract.Instances.BEGIN} ASC",
    )?.use { c ->
      while (c.moveToNext() && events.size < 30) {
        events.add(
          mapOf(
            "title" to c.getString(0),
            "start" to java.time.Instant.ofEpochMilli(c.getLong(1)).atZone(ZoneId.systemDefault()).toLocalDateTime().toString(),
            "location" to c.getString(2),
          )
        )
      }
    }
    return mapOf("events" to events, "summary" to if (events.isEmpty()) "Nothing on your calendar." else "${events.size} events.")
  }

  private fun searchContacts(name: String): Map<String, Any?> {
    val found = linkedMapOf<String, MutableList<String>>()
    activity.contentResolver.query(
      ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
      arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
      "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
      arrayOf("%$name%"),
      null,
    )?.use { c ->
      while (c.moveToNext() && found.size < 10) found.getOrPut(c.getString(0)) { mutableListOf() }.add(c.getString(1))
    }
    return mapOf("contacts" to found.map { mapOf("name" to it.key, "phones" to it.value.distinct()) })
  }

  private fun openApp(name: String): Map<String, Any?> {
    val pm = activity.packageManager
    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    val match = pm.queryIntentActivities(launcher, 0)
      .map { it to it.loadLabel(pm).toString() }
      .sortedBy { it.second.length }
      .firstOrNull { it.second.contains(name, ignoreCase = true) }
      ?: return mapOf("error" to "No app called \"$name\"")
    val intent = pm.getLaunchIntentForPackage(match.first.activityInfo.packageName) ?: return mapOf("error" to "Cannot open ${match.second}")
    return start(intent, "Opened ${match.second}")
  }
}
