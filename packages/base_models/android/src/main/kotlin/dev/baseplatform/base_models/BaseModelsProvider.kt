package dev.baseplatform.base_models

import android.content.ContentProvider
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/**
 * Hands this app's finished model files to sibling apps, read-only.
 *
 * Exported, but guarded by a signature-level permission (see the manifest), so
 * only apps signed with the same key can read it. Only files that the shared
 * registry lists as complete are served: never a `.part`, never anything
 * outside the store.
 *
 * URIs (protocol v1, docs/MODEL_STORE.md):
 * - content://<applicationId>.basemodels/models: one row per complete file
 *   ([COLUMNS]), so any sibling can list what is on the device without copying.
 * - content://<applicationId>.basemodels/<modelId>/<file>: the file, read-only.
 */
class BaseModelsProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read-only")
        val ctx = context ?: throw FileNotFoundException()
        val segments = uri.pathSegments
        if (segments.size != 2 || !segments.all(::isPlainName)) throw FileNotFoundException(uri.toString())
        val (modelId, name) = segments
        val root = SharedModelStore.storeDir(ctx)
        val recorded = completeFiles(root).firstOrNull { it.modelId == modelId && it.name == name }
            ?: throw FileNotFoundException(uri.toString())
        val file = File(File(root, modelId), name)
        if (!file.canonicalPath.startsWith(root.canonicalPath) || file.length() != recorded.bytes) {
            throw FileNotFoundException(uri.toString())
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "application/octet-stream"
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? {
        if (uri.pathSegments != listOf("models")) return null
        val ctx = context ?: return null
        val cursor = MatrixCursor(COLUMNS)
        for (f in completeFiles(SharedModelStore.storeDir(ctx))) {
            cursor.addRow(arrayOf<Any?>(f.modelId, f.name, f.bytes, f.sha256))
        }
        return cursor
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0

    companion object {
        val COLUMNS = arrayOf("model_id", "file", "bytes", "sha256")

        data class StoredFile(val modelId: String, val name: String, val bytes: Long, val sha256: String?)

        /** Files the registry lists that are on disk at their recorded size. */
        fun completeFiles(root: File): List<StoredFile> {
            val registry = File(root, "registry.json")
            if (!registry.exists()) return emptyList()
            val models = try {
                JSONObject(registry.readText()).optJSONObject("models")
            } catch (e: org.json.JSONException) {
                null
            } ?: return emptyList()
            val out = mutableListOf<StoredFile>()
            for (id in models.keys()) {
                val entry = models.optJSONObject(id) ?: continue
                // Downloaded files, and the files an SDK wrote into the model's folder.
                val files = entry.optJSONObject("files")?.takeIf { it.length() > 0 }
                    ?: entry.optJSONObject("sdkFiles")?.takeIf { entry.optBoolean("sdkReady") }
                    ?: continue
                for (name in files.keys()) {
                    val rec = files.optJSONObject(name) ?: continue
                    val bytes = rec.optLong("bytes", -1)
                    if (!isPlainName(id) || !isPlainName(name)) continue
                    if (File(File(root, id), name).length() != bytes) continue
                    out.add(StoredFile(id, name, bytes, if (rec.isNull("sha256")) null else rec.optString("sha256").ifEmpty { null }))
                }
            }
            return out
        }

        /** The discovery action this app's provider answers (the manifest placeholder, via meta-data). */
        fun discoveryAction(context: Context): String {
            val info = context.packageManager.getProviderInfo(
                ComponentName(context, BaseModelsProvider::class.java),
                PackageManager.GET_META_DATA,
            )
            return info.metaData?.getString("dev.baseplatform.base_models.ACTION")
                ?: error("BaseModelsProvider has no discovery action; set manifestPlaceholders[\"baseModelsDiscoveryAction\"]")
        }

        fun isPlainName(s: String) = s.isNotEmpty() && s != "." && s != ".." && !s.contains('/') && !s.contains('\\')
    }
}
