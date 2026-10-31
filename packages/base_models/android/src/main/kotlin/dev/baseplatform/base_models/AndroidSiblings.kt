package dev.baseplatform.base_models

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import java.io.File

/**
 * The other apps of the vendor on this phone: every installed app whose
 * [BaseModelsProvider] answers the discovery action. The provider is guarded
 * by a signature permission, so only apps signed with the same key answer.
 */
class AndroidSiblings(private val context: Context, private val action: String) : SiblingSource {
    override fun authorities(): List<String> {
        val pm = context.packageManager
        val found = if (android.os.Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentContentProviders(Intent(action), PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentContentProviders(Intent(action), 0)
        }
        return found.mapNotNull { it.providerInfo }.filter { it.packageName != context.packageName }.map { it.authority }
    }

    override fun listAll(): List<SiblingFile> {
        val out = mutableListOf<SiblingFile>()
        for (authority in authorities()) {
            try {
                context.contentResolver.query(Uri.parse("content://$authority/models"), null, null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        out.add(SiblingFile(authority, c.getString(0), c.getString(1), c.getLong(2), if (c.isNull(3)) null else c.getString(3)))
                    }
                }
            } catch (e: Exception) {
                // An older sibling without the models table, or one signed with another key.
            }
        }
        return out
    }

    override fun copy(authority: String, modelId: String, file: String, dest: File): Long {
        require(BaseModelsProvider.isPlainName(modelId) && BaseModelsProvider.isPlainName(file)) { "bad name" }
        require(dest.canonicalPath.startsWith(SharedModelStore.storeDir(context).canonicalPath)) { "destination outside the store" }
        val uri = Uri.parse("content://$authority/$modelId/$file")
        val input = context.contentResolver.openInputStream(uri) ?: error("$authority has no $modelId/$file")
        input.use { src -> dest.outputStream().use { dst -> return src.copyTo(dst, 1 shl 20) } }
    }
}
