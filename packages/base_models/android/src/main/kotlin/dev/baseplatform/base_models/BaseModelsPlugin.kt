package dev.baseplatform.base_models

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Flutter side of the shared model store on Android. The store logic lives in
 * Dart (store_io.dart); this plugin gives it the store folder and the sibling
 * apps ([AndroidSiblings], [BaseModelsProvider]), the same classes native
 * Kotlin apps use through [SharedModelStore].
 *
 * Android gives every app its own private storage, so apps cannot open one
 * folder in place the way iOS App Groups or a desktop folder can. Instead each
 * app keeps its models in `noBackupFilesDir/shared-models`, and before
 * downloading a model it asks its sibling apps (same signing key) for a copy.
 */
class BaseModelsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val io = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "base/models")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "storeDir" -> result.success(SharedModelStore.storeDir(context).path)
            "siblings" -> result.success(AndroidSiblings(context, call.argument<String>("action")!!).authorities())
            "siblingModels" -> io.execute {
                val list = try {
                    AndroidSiblings(context, call.argument<String>("action")!!).listAll().map {
                        mapOf("authority" to it.authority, "modelId" to it.modelId, "file" to it.file, "bytes" to it.bytes, "sha256" to it.sha256)
                    }
                } catch (e: Exception) {
                    emptyList()
                }
                post { result.success(list) }
            }
            "copyFromSibling" -> io.execute {
                try {
                    // The authority names the sibling; the action is not needed to copy.
                    val bytes = AndroidSiblings(context, "").copy(
                        call.argument<String>("authority")!!,
                        call.argument<String>("modelId")!!,
                        call.argument<String>("file")!!,
                        File(call.argument<String>("dest")!!),
                    )
                    post { result.success(bytes) }
                } catch (e: Exception) {
                    post { result.error("sibling", e.message ?: e.javaClass.simpleName, null) }
                }
            }
            "keepAwakeBegin" -> {
                KeepAwake.begin(
                    context,
                    call.argument<String>("key")!!,
                    call.argument<String>("text") ?: "working",
                    if (call.argument<Boolean>("ai") == true) KeepAwake.Kind.AI else KeepAwake.Kind.DOWNLOAD,
                )
                result.success(null)
            }
            "keepAwakeUpdate" -> {
                KeepAwake.update(context, call.argument<String>("key")!!, call.argument<Double>("progress"), call.argument<String>("text"))
                result.success(null)
            }
            "keepAwakeEnd" -> {
                KeepAwake.end(context, call.argument<String>("key")!!)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun post(block: () -> Unit) = android.os.Handler(android.os.Looper.getMainLooper()).post(block)
}
