package ai.phonedots.phonedots

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
  private var llm: LlmBridge? = null
  private var intake: MethodChannel? = null
  private var dartReady = false
  private val pendingShares = ArrayDeque<Map<String, Any?>>()

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val messenger = flutterEngine.dartExecutor.binaryMessenger
    llm = LlmBridge(applicationContext, messenger)
    SpecialistBridge(applicationContext, messenger)
    DeviceBridge(this, messenger)
    intake = MethodChannel(messenger, "phonedots/intake").also {
      it.setMethodCallHandler { call, result ->
        if (call.method == "ready") {
          dartReady = true
          flushShare()
        }
        result.success(null)
      }
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    handleShare(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    handleShare(intent)
  }

  override fun onDestroy() {
    llm?.dispose()
    super.onDestroy()
  }

  /** Copies shared content into app storage (off the UI thread) and hands it to Dart. */
  private fun handleShare(intent: Intent?) {
    if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE)) return
    // Reopening from Recents re-delivers the original share; it was already handled.
    if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
    val uris = mutableListOf<Uri>()
    if (intent.action == Intent.ACTION_SEND) {
      @Suppress("DEPRECATION")
      (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
    } else {
      @Suppress("DEPRECATION")
      intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
    }
    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""
    // EXTRA_SUBJECT/EXTRA_TITLE often carry the post or video title (YouTube does this).
    val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: intent.getStringExtra(Intent.EXTRA_TITLE)
    val type = intent.type ?: ""
    // Mark it handled so a configuration change or re-delivery doesn't import it twice.
    setIntent(Intent(intent).setAction(Intent.ACTION_MAIN))
    Thread {
      val dir = File(filesDir, "shared").apply { mkdirs() }
      val files = uris.take(8).mapNotNull { uri ->
        try {
          val raw = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
          } ?: "shared-${System.currentTimeMillis()}"
          // Display names come from the sending app: never let one pick the folder.
          val name = raw.replace(Regex("[/\\\\:\u0000]"), "_").trimStart('.').ifEmpty { "shared" }.take(120)
          val dest = File(dir, "${System.currentTimeMillis()}-$name")
          contentResolver.openInputStream(uri)?.use { input -> dest.outputStream().use { input.copyTo(it) } }
          mapOf("path" to dest.path, "name" to name, "mime" to (contentResolver.getType(uri) ?: type))
        } catch (_: Exception) {
          null
        }
      }
      runOnUiThread {
        pendingShares.addLast(mapOf("text" to text, "subject" to subject, "files" to files))
        flushShare()
      }
    }.start()
  }

  private fun flushShare() {
    if (!dartReady) return
    while (pendingShares.isNotEmpty()) intake?.invokeMethod("shared", pendingShares.removeFirst())
  }
}
