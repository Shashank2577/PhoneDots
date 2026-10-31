package ai.phonedots.phonedots

import ai.desertant.clear.Clear
import ai.desertant.ear.Ear
import ai.desertant.emo.Emo
import ai.desertant.eye.Eye
import ai.desertant.gist.Gist
import ai.desertant.moderator.Moderator
import ai.desertant.redact.Redact
import ai.desertant.tongue.Tongue
import ai.desertant.voz.Voz
import ai.desertant.who.Who
import android.content.Context
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Desert Ant specialists (desert-ant-core Android SDK). Each model is created
 * lazily, downloads itself into the app's model folder on first use, and
 * returns plain maps to Dart. Uhm, Align, Title and Clips are Apple-only.
 */
class SpecialistBridge(private val context: Context, messenger: BinaryMessenger) :
  MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val main = Handler(Looper.getMainLooper())
  private val models = ConcurrentHashMap<String, Any>()
  private var sink: EventChannel.EventSink? = null

  init {
    MethodChannel(messenger, "phonedots/specialist").setMethodCallHandler(this)
    EventChannel(messenger, "phonedots/specialist/events").setStreamHandler(this)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    sink = events
  }

  override fun onCancel(arguments: Any?) {
    sink = null
  }

  private fun dir(key: String): String =
    File(context.filesDir, "desertant/$key").apply { mkdirs() }.path

  private fun key(modelId: String) = modelId.removePrefix("desertant.")

  /** Returns the SDK object for [modelId], creating it on first use. */
  private fun model(modelId: String): Any = models.getOrPut(modelId) {
    val k = key(modelId)
    when (k) {
      "voz" -> Voz(context, dir(k))
      "who" -> Who(context, dir(k))
      "ear" -> Ear(context, dir(k))
      "clear" -> Clear(context, dir(k))
      "redact" -> Redact(context, dir(k))
      "emo" -> Emo(context, dir(k))
      "gist" -> Gist(context, dir(k))
      "eye" -> Eye(context, dir(k))
      "moderator" -> Moderator(context, dir(k))
      "tongue" -> Tongue.bundled(context)
      else -> throw UnsupportedOperationException("${k.replaceFirstChar { it.uppercase() }} is not available on Android yet")
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val modelId = call.argument<String>("modelId")
    when (call.method) {
      "availability" -> result.success(
        listOf("voz", "who", "ear", "clear", "redact", "emo", "gist", "eye", "moderator", "tongue")
          .associate { "desertant.$it" to "native" } +
          listOf("uhm", "align", "title", "clips", "shapes").associate { "desertant.$it" to "unsupported" }
      )
      "isDownloaded" -> scope.launch {
        val ok = try {
          isDownloaded(model(modelId!!))
        } catch (_: Throwable) {
          false
        }
        main.post { result.success(ok) }
      }
      "download" -> scope.launch {
        try {
          emit(modelId!!, 0.0)
          download(model(modelId))
          emit(modelId, 1.0)
          main.post { result.success(null) }
        } catch (e: Throwable) {
          Log.e(TAG, "download $modelId failed", e)
          main.post { result.error("download", e.message, null) }
        }
      }
      "run" -> scope.launch {
        val out = try {
          @Suppress("UNCHECKED_CAST")
          run(modelId!!, call.argument<String>("task")!!, call.argument<Map<String, Any?>>("input") ?: emptyMap())
        } catch (e: Throwable) {
          Log.e(TAG, "run $modelId failed", e)
          mapOf("error" to (e.message ?: e.javaClass.simpleName))
        }
        main.post { result.success(out) }
      }
      else -> result.notImplemented()
    }
  }

  private fun emit(modelId: String, progress: Double) =
    main.post { sink?.success(mapOf("modelId" to modelId, "progress" to progress)) }

  private fun isDownloaded(m: Any): Boolean = when (m) {
    is Voz -> m.isDownloaded()
    is Who -> m.isDownloaded()
    is Ear -> m.isDownloaded()
    is Clear -> m.isDownloaded()
    is Redact -> m.isDownloaded()
    is Emo -> m.isDownloaded()
    is Gist -> m.isDownloaded()
    is Eye -> m.isDownloaded()
    is Moderator -> m.isDownloaded()
    else -> true // Tongue ships inside the APK.
  }

  private suspend fun download(m: Any) {
    when (m) {
      is Voz -> m.download()
      is Who -> m.download()
      is Ear -> m.download()
      is Clear -> m.download()
      is Redact -> m.download()
      is Emo -> m.download()
      is Gist -> m.download()
      is Eye -> m.download()
      is Moderator -> m.download()
    }
  }

  private fun audio(input: Map<String, Any?>) = AudioFiles.decode(input["audioPath"] as String)

  private fun bitmap(input: Map<String, Any?>) =
    BitmapFactory.decodeFile(input["imagePath"] as String) ?: throw IllegalArgumentException("Could not read the image")

  private suspend fun run(modelId: String, task: String, input: Map<String, Any?>): Map<String, Any?> {
    return when (val m = model(modelId)) {
      is Voz -> {
        val pcm = audio(input)
        val t = m.transcribe(pcm.samples, pcm.sampleRate)
        mapOf(
          "text" to t.text,
          "duration" to t.duration,
          "words" to t.words.map { mapOf("text" to it.text, "start" to it.start, "end" to it.end) },
        )
      }
      is Who -> {
        val pcm = audio(input)
        val d = m.diarize(pcm.samples, pcm.sampleRate)
        mapOf(
          "speakerCount" to d.speakerCount,
          "duration" to d.duration,
          "turns" to d.turns.map { mapOf("speaker" to it.speaker, "start" to it.start, "end" to it.end) },
        )
      }
      is Ear -> {
        val pcm = audio(input)
        val d = m.identify(pcm.samples, pcm.sampleRate)
        mapOf("language" to d.language, "confidence" to d.confidence, "isReliable" to d.isReliable)
      }
      is Clear -> {
        val pcm = audio(input)
        val r = m.enhance(pcm.samples, pcm.sampleRate)
        val src = File(input["audioPath"] as String)
        val outPath = File(src.parentFile, "${src.nameWithoutExtension}-clear.wav").path
        AudioFiles.writeWav(outPath, r.samples, r.sampleRate.toInt())
        mapOf("outputPath" to outPath, "measuredLufs" to r.measuredLufs)
      }
      is Redact -> {
        val r = m.redaction(input["text"] as String)
        mapOf(
          "redactedText" to r.redactedText,
          "items" to r.items.map {
            mapOf("label" to it.label, "original" to it.original, "placeholder" to it.placeholder, "confidence" to it.confidence)
          },
        )
      }
      is Emo -> mapOf(
        "suggestions" to m.suggestions(input["text"] as String, limit = (input["limit"] as? Number)?.toInt() ?: 3)
          .map { mapOf("emoji" to it.emoji, "confidence" to it.confidence) }
      )
      is Gist -> mapOf(
        "topics" to m.classify(input["text"] as String).map { mapOf("slug" to it.slug, "name" to it.name, "score" to it.score) }
      )
      is Eye -> {
        val a = m.analyze(bitmap(input))
        mapOf(
          "kind" to a.kind?.id,
          "tags" to a.tags().map { it.id },
          "aesthetic" to a.scores?.aesthetic,
          "keeper" to a.scores?.keeper,
          "faces" to (a.faces?.size ?: 0),
        )
      }
      is Moderator -> {
        val r = m.analyze(bitmap(input))
        mapOf("isNSFW" to r.isNSFW, "score" to r.score)
      }
      is Tongue -> {
        val d = m.detect(input["text"] as String)
        val top = d.candidates.firstOrNull()
        mapOf("language" to top?.language, "confidence" to top?.probability, "isTooCloseToCall" to d.isTooCloseToCall)
      }
      else -> mapOf("error" to "Task $task is not supported for $modelId")
    }
  }

  companion object {
    private const val TAG = "PhoneDotsSpecialist"
  }
}
