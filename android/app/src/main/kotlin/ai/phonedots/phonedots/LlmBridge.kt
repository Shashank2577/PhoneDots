package ai.phonedots.phonedots

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.EmbeddingEngine
import com.google.ai.edge.litertlm.EmbeddingEngineConfig
import com.google.ai.edge.litertlm.EmbeddingOptions
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.OpenApiTool
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ToolCall
import com.google.ai.edge.litertlm.tool
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Gemma on LiteRT-LM. Keeps one live [Conversation] per Dart session so a new
 * turn only prefills what is new; tool calls are returned to Dart (manual tool
 * calling) so skills, permission prompts and the trace stay in one place.
 */
class LlmBridge(private val context: Context, messenger: BinaryMessenger) :
  MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private class Session(
    val conversation: Conversation,
    val modelId: String,
    val key: String,
    var synced: Int,
  )

  /** Describes a skill to the model. Never executed natively. */
  private class DartTool(private val spec: Map<*, *>) : OpenApiTool {
    override fun getToolDescriptionJsonString(): String = JSONObject(spec).toString()

    override fun execute(paramsJsonString: String): String = "{}"
  }

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val main = Handler(Looper.getMainLooper())
  private val engines = ConcurrentHashMap<String, Engine>()
  private val sessions = ConcurrentHashMap<String, Session>()
  private val active = ConcurrentHashMap<String, Conversation>()
  private var embedder: EmbeddingEngine? = null
  private var embedDims = 256
  private var sink: EventChannel.EventSink? = null

  init {
    MethodChannel(messenger, "phonedots/llm").setMethodCallHandler(this)
    EventChannel(messenger, "phonedots/llm/events").setStreamHandler(this)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    sink = events
  }

  override fun onCancel(arguments: Any?) {
    sink = null
  }

  private fun emit(event: Map<String, Any?>) = main.post { sink?.success(event) }

  private fun io(result: MethodChannel.Result, block: () -> Any?) {
    scope.launch {
      try {
        val value = block()
        main.post { result.success(value) }
      } catch (e: Throwable) {
        Log.e(TAG, "llm call failed", e)
        main.post { result.error("llm", e.message ?: e.javaClass.simpleName, null) }
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "load" -> io(result) { load(call) }
      "unload" -> io(result) {
        val id = call.argument<String>("modelId")!!
        sessions.entries.filter { it.value.modelId == id }.forEach { sessions.remove(it.key)?.conversation?.close() }
        engines.remove(id)?.close()
        null
      }
      "generate" -> {
        val requestId = call.argument<String>("requestId")!!
        scope.launch { generate(requestId, call) }
        result.success(null)
      }
      "cancel" -> {
        active[call.argument<String>("requestId")]?.cancelProcess()
        result.success(null)
      }
      "resetSession" -> {
        sessions.remove(call.argument<String>("sessionId"))?.conversation?.close()
        result.success(null)
      }
      "deviceProfile" -> result.success(deviceProfile())
      "loadEmbedder" -> io(result) {
        embedDims = call.argument<Int>("dimensions") ?: 256
        embedder?.close()
        embedder = EmbeddingEngine(EmbeddingEngineConfig(modelPath = call.argument<String>("path")!!, backend = Backend.CPU()))
          .also { it.initialize() }
        null
      }
      "embed" -> io(result) {
        val e = embedder ?: throw IllegalStateException("Embedder not loaded")
        e.computeEmbedding(
          listOf(InputData.Text(call.argument<String>("text")!!)),
          EmbeddingOptions(normalize = true, outputSize = embedDims),
        ).embedding.map { it.toDouble() }
      }
      else -> result.notImplemented()
    }
  }

  @OptIn(ExperimentalApi::class)
  private fun load(call: MethodCall): Any? {
    val id = call.argument<String>("modelId")!!
    val path = call.argument<String>("path")!!
    val gpu = call.argument<String>("backend") == "gpu"
    val vision = call.argument<Boolean>("vision") == true
    val audio = call.argument<Boolean>("audio") == true
    val maxTokens = call.argument<Int>("maxTokens") ?: 4096
    fun config(useGpu: Boolean) = EngineConfig(
      modelPath = path,
      backend = if (useGpu) Backend.GPU() else Backend.CPU(),
      visionBackend = if (vision) Backend.GPU() else null,
      audioBackend = if (audio) Backend.CPU() else null,
      maxNumTokens = maxTokens,
      cacheDir = context.cacheDir.path,
    )
    ExperimentalFlags.enableBenchmark = true
    val engine = try {
      Engine(config(gpu)).also { it.initialize() }
    } catch (e: Throwable) {
      if (!gpu) throw e
      Log.w(TAG, "GPU init failed, falling back to CPU", e)
      Engine(config(false)).also { it.initialize() }
    } finally {
      ExperimentalFlags.enableBenchmark = false
    }
    engines.put(id, engine)?.close()
    return null
  }

  private fun toMessage(turn: Map<*, *>): Message {
    val text = turn["text"] as? String ?: ""
    return when (turn["role"]) {
      "model" -> {
        val calls = (turn["toolCalls"] as? List<*>).orEmpty().map {
          val c = it as Map<*, *>
          @Suppress("UNCHECKED_CAST")
          ToolCall(c["name"] as String, (c["arguments"] as? Map<String, Any?>) ?: emptyMap())
        }
        if (text.isEmpty()) Message.model(toolCalls = calls) else Message.model(Contents.of(text), calls)
      }
      "tool" -> Message.tool(
        Contents.of(
          (turn["toolResponses"] as? List<*>).orEmpty().map {
            val r = it as Map<*, *>
            Content.ToolResponse(r["name"] as String, r["response"])
          }
        )
      )
      "system" -> Message.system(text)
      else -> {
        val parts = mutableListOf<Content>()
        (turn["images"] as? List<*>).orEmpty().forEach { parts.add(Content.ImageFile(it as String)) }
        (turn["audio"] as? List<*>).orEmpty().forEach { parts.add(Content.AudioFile(it as String)) }
        if (text.isNotEmpty() || parts.isEmpty()) parts.add(Content.Text(text))
        Message.user(Contents.of(parts))
      }
    }
  }

  @OptIn(ExperimentalApi::class)
  private fun generate(requestId: String, call: MethodCall) {
    val started = System.currentTimeMillis()
    try {
      val modelId = call.argument<String>("modelId")!!
      val sessionId = call.argument<String>("sessionId")!!
      val history = call.argument<List<Map<*, *>>>("history")!!
      val system = call.argument<String>("systemPrompt") ?: ""
      val tools = call.argument<List<Map<*, *>>>("tools").orEmpty()
      val thinking = call.argument<Boolean>("thinking") == true
      val sampler = call.argument<Map<*, *>>("sampler").orEmpty()
      val engine = engines[modelId] ?: throw IllegalStateException("Model $modelId is not loaded")

      // A different system prompt or tool list needs a fresh conversation.
      val key = "$modelId|${system.hashCode()}|${tools.joinToString(",") { it["name"].toString() }}"
      var session = sessions[sessionId]
      if (session == null || session.key != key || session.synced != history.size - 1) {
        session?.conversation?.close()
        ExperimentalFlags.enableConversationConstrainedDecoding = tools.isNotEmpty()
        val conversation = try {
          engine.createConversation(
            ConversationConfig(
              systemInstruction = if (system.isEmpty()) null else Contents.of(system),
              initialMessages = history.dropLast(1).map(::toMessage),
              tools = tools.map { tool(DartTool(it)) },
              samplerConfig = SamplerConfig(
                topK = (sampler["topK"] as? Number)?.toInt() ?: 40,
                topP = (sampler["topP"] as? Number)?.toDouble() ?: 0.95,
                temperature = (sampler["temperature"] as? Number)?.toDouble() ?: 0.7,
              ),
              automaticToolCalling = false,
              maxOutputToken = (sampler["maxTokens"] as? Number)?.toInt(),
            )
          )
        } finally {
          ExperimentalFlags.enableConversationConstrainedDecoding = false
        }
        session = Session(conversation, modelId, key, history.size - 1)
        sessions[sessionId] = session
      }

      val conversation = session.conversation
      active[requestId] = conversation
      var firstTokenAt = 0L
      var chunks = 0
      val calls = mutableListOf<Map<String, Any?>>()
      conversation.sendMessageAsync(
        toMessage(history.last()),
        object : MessageCallback {
          override fun onMessage(message: Message) {
            if (firstTokenAt == 0L) firstTokenAt = System.currentTimeMillis()
            message.channels["thought"]?.takeIf { it.isNotEmpty() }?.let {
              emit(mapOf("requestId" to requestId, "type" to "thinking", "text" to it))
            }
            val text = message.toString()
            if (text.isNotEmpty()) {
              chunks++
              emit(mapOf("requestId" to requestId, "type" to "token", "text" to text))
            }
            message.toolCalls.forEachIndexed { i, c ->
              calls.add(mapOf("id" to "$requestId-$i", "name" to c.name, "arguments" to c.arguments))
            }
          }

          override fun onDone() {
            active.remove(requestId)
            session.synced = history.size + 1
            if (calls.isNotEmpty()) emit(mapOf("requestId" to requestId, "type" to "toolCalls", "calls" to calls))
            emit(mapOf("requestId" to requestId, "type" to "done", "stats" to stats(conversation, started, firstTokenAt, chunks)))
          }

          override fun onError(throwable: Throwable) {
            active.remove(requestId)
            sessions.remove(sessionId)?.conversation?.close()
            if (throwable is kotlinx.coroutines.CancellationException) {
              emit(mapOf("requestId" to requestId, "type" to "done", "stats" to stats(null, started, firstTokenAt, chunks)))
            } else {
              emit(mapOf("requestId" to requestId, "type" to "error", "message" to (throwable.message ?: "Generation failed")))
            }
          }
        },
        extraContext = mapOf("enable_thinking" to thinking),
      )
    } catch (e: Throwable) {
      Log.e(TAG, "generate failed", e)
      active.remove(requestId)
      emit(mapOf("requestId" to requestId, "type" to "error", "message" to (e.message ?: e.javaClass.simpleName)))
    }
  }

  @OptIn(ExperimentalApi::class)
  private fun stats(conversation: Conversation?, started: Long, firstTokenAt: Long, chunks: Int): Map<String, Any?> {
    val now = System.currentTimeMillis()
    val base = mutableMapOf<String, Any?>(
      "ttftMs" to if (firstTokenAt == 0L) 0 else firstTokenAt - started,
      "totalMs" to now - started,
      "outputTokens" to chunks,
    )
    try {
      conversation?.getBenchmarkInfo()?.let {
        base["outputTokens"] = it.lastDecodeTokenCount
        base["prefillTps"] = it.lastPrefillTokensPerSecond
        base["decodeTps"] = it.lastDecodeTokensPerSecond
      }
    } catch (_: Throwable) {
      // Benchmark info is only present when the engine was created with it on.
    }
    return base
  }

  private fun deviceProfile(): Map<String, Any?> {
    val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
    return mapOf(
      "platform" to "android",
      "totalRamMb" to (mem.totalMem / (1024 * 1024)).toInt(),
      "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
      "soc" to if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else Build.HARDWARE,
      "gpu" to true,
      "npu" to false,
    )
  }

  fun dispose() {
    sessions.values.forEach { it.conversation.close() }
    engines.values.forEach { it.close() }
    embedder?.close()
  }

  companion object {
    private const val TAG = "PhoneDotsLlm"
  }
}
