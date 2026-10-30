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
  private var pendingShare: Map<String, Any?>? = null

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

  /** Copies shared content into app storage and hands it to Dart. */
  private fun handleShare(intent: Intent?) {
    if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE)) return
    val uris = mutableListOf<Uri>()
    if (intent.action == Intent.ACTION_SEND) {
      @Suppress("DEPRECATION")
      (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
    } else {
      @Suppress("DEPRECATION")
      intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
    }
    val dir = File(filesDir, "shared").apply { mkdirs() }
    val files = uris.take(8).mapNotNull { uri ->
      try {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
          if (it.moveToFirst()) it.getString(0) else null
        } ?: "shared-${System.currentTimeMillis()}"
        val dest = File(dir, "${System.currentTimeMillis()}-$name")
        contentResolver.openInputStream(uri)?.use { input -> dest.outputStream().use { input.copyTo(it) } }
        mapOf("path" to dest.path, "name" to name, "mime" to (contentResolver.getType(uri) ?: intent.type ?: ""))
      } catch (_: Exception) {
        null
      }
    }
    pendingShare = mapOf("text" to (intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""), "files" to files)
    flushShare()
  }

  private fun flushShare() {
    val share = pendingShare ?: return
    if (!dartReady) return
    intake?.invokeMethod("shared", share)
    pendingShare = null
  }
}
