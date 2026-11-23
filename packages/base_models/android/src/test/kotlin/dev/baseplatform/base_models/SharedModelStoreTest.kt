package dev.baseplatform.base_models

import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Kotlin store against a local server: the same rules as the Dart store (store_test.dart). */
class SharedModelStoreTest {
    private val payload = ByteArray(300_000) { (it % 251).toByte() }
    private lateinit var server: ServerSocket
    private var requests = 0
    private lateinit var tmp: File

    @BeforeTest
    fun setUp() {
        tmp = Files.createTempDirectory("shared-models-kt").toFile()
        // A minimal HTTP/1.1 server (the Android test classpath has no JDK HttpServer).
        server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val sock = try {
                    server.accept()
                } catch (e: Exception) {
                    break
                }
                sock.use { s ->
                    val reader = s.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                    var from = 0
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("Range:", ignoreCase = true)) {
                            from = line.substringAfter("bytes=").substringBefore("-").trim().toInt()
                        }
                    }
                    requests++
                    val status = if (from > 0) "206 Partial Content" else "200 OK"
                    val out = s.getOutputStream()
                    out.write("HTTP/1.1 $status\r\nContent-Length: ${payload.size - from}\r\nConnection: close\r\n\r\n".toByteArray())
                    out.write(payload, from, payload.size - from)
                    out.flush()
                }
            }
        }
    }

    @AfterTest
    fun tearDown() {
        server.close()
        tmp.deleteRecursively()
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun catalog(sha: String? = sha(payload)) = ModelCatalog.parse(
        JSONObject().put(
            "models",
            org.json.JSONArray().put(
                JSONObject()
                    .put("id", "test.tiny").put("name", "Tiny").put("source", "file").put("platforms", org.json.JSONArray().put("android"))
                    .put(
                        "files",
                        org.json.JSONArray().put(
                            JSONObject().put("name", "weights.bin").put("url", "http://127.0.0.1:${server.localPort}/w")
                                .put("sha256", sha ?: JSONObject.NULL).put("bytes", payload.size)
                        )
                    )
            ).put(
                JSONObject().put("id", "test.sdk").put("name", "Sdk").put("source", "sdk").put("platforms", org.json.JSONArray().put("android"))
                    .put("files", org.json.JSONArray()).put("sdk", JSONObject().put("name", "x").put("key", "sdk"))
            )
        ).toString()
    )

    private fun store(app: String, root: File = File(tmp, "store"), siblings: SiblingSource? = null, sha: String? = sha(payload), offline: Boolean = false) =
        SharedModelStore(root, app, catalog(sha), siblings, offline = { offline })

    @Test
    fun `a model downloaded by one app is reused by the next without the network`() {
        val a = store("app.a")
        a.ensure("test.tiny")
        assertEquals(1, requests)
        val b = store("app.b")
        assertTrue(b.isReady("test.tiny"))
        b.ensure("test.tiny")
        assertEquals(1, requests, "no second download")
        assertEquals(setOf("app.a", "app.b"), b.users("test.tiny"))
        assertEquals(payload.toList(), b.pathOf("test.tiny", "weights.bin").readBytes().toList())
    }

    @Test
    fun `the registry is the one the Dart store writes`() {
        store("app.a").ensure("test.tiny")
        val reg = JSONObject(File(tmp, "store/registry.json").readText())
        assertEquals(1, reg.getInt("version"))
        val entry = reg.getJSONObject("models").getJSONObject("test.tiny")
        val file = entry.getJSONObject("files").getJSONObject("weights.bin")
        assertEquals(payload.size.toLong(), file.getLong("bytes"))
        assertEquals("network", file.getString("source"))
        assertEquals("app.a", entry.getString("addedBy"))
        assertTrue(java.time.Instant.parse(entry.getJSONObject("users").getString("app.a")) != null)
    }

    @Test
    fun `files stay until the last app releases the model`() {
        val a = store("app.a")
        val b = store("app.b")
        a.ensure("test.tiny")
        b.ensure("test.tiny")
        a.release("test.tiny")
        assertTrue(b.isReady("test.tiny"))
        b.release("test.tiny")
        assertFalse(b.pathOf("test.tiny").exists())
    }

    @Test
    fun `a damaged download is thrown away`() {
        val a = store("app.a", sha = "0".repeat(64))
        assertFailsWith<ChecksumMismatch> { a.ensure("test.tiny") }
        assertFalse(a.isReady("test.tiny"))
        assertFalse(File(a.pathOf("test.tiny", "weights.bin").path + ".part").exists())
    }

    @Test
    fun `never go online blocks a needed download`() {
        assertFailsWith<OfflineException> { store("app.a", offline = true).ensure("test.tiny") }
        assertEquals(0, requests)
    }

    @Test
    fun `an interrupted download resumes`() {
        val a = store("app.a")
        val part = File(a.pathOf("test.tiny").apply { mkdirs() }, "weights.bin.part")
        part.writeBytes(payload.copyOfRange(0, 1000))
        a.ensure("test.tiny")
        assertTrue(a.isReady("test.tiny"))
        assertEquals(payload.toList(), a.pathOf("test.tiny", "weights.bin").readBytes().toList())
    }

    /** Another phone app's private store, reached through its provider. */
    private class FakeSibling(val other: SharedModelStore) : SiblingSource {
        var copies = 0
        override fun authorities() = listOf("other.basemodels")
        override fun listAll() = other.models().let { m ->
            m.keys().asSequence().flatMap { id ->
                val f = m.getJSONObject(id).optJSONObject("files") ?: JSONObject()
                f.keys().asSequence().map { n -> SiblingFile("other.basemodels", id, n, f.getJSONObject(n).getLong("bytes"), f.getJSONObject(n).optString("sha256")) }
            }.toList()
        }
        override fun copy(authority: String, modelId: String, file: String, dest: File): Long {
            copies++
            other.pathOf(modelId, file).copyTo(dest, overwrite = true)
            return dest.length()
        }
    }

    @Test
    fun `on Android a sibling's copy is used instead of the network`() {
        val burrow = store("com.showcase.desertant", root = File(tmp, "burrow"))
        burrow.ensure("test.tiny")
        assertEquals(1, requests)
        val sibling = FakeSibling(burrow)
        val dots = store("ai.phonedots.phonedots", root = File(tmp, "dots"), siblings = sibling)
        assertTrue(dots.inSibling("test.tiny"), "detected before any copy")
        dots.ensure("test.tiny")
        assertEquals(1, requests, "copied, not downloaded")
        assertEquals(1, sibling.copies)
        assertEquals("sibling", dots.sourceOf("test.tiny"))
    }

    @Test
    fun `an SDK model is installed into its folder in the store and recorded`() {
        val a = store("app.a")
        a.ensure("test.sdk", sdkInstall = { dir, progress ->
            File(dir, "weights.bin").writeBytes(ByteArray(1234))
            progress(1.0)
        })
        assertTrue(a.isReady("test.sdk"))
        val entry = a.models().getJSONObject("test.sdk")
        assertEquals(1234L, entry.getLong("sdkBytes"))
        assertEquals(1234L, entry.getJSONObject("sdkFiles").getJSONObject("weights.bin").getLong("bytes"))
        assertEquals("app.a", entry.getJSONArray("sdkApps").getString(0))
    }

    @Test
    fun `files an app downloaded before the store are adopted, not downloaded again`() {
        val old = File(tmp, "old/model.bin").apply { parentFile!!.mkdirs(); writeBytes(payload) }
        val a = store("app.a")
        assertTrue(a.adopt("test.tiny", mapOf("weights.bin" to old)))
        assertTrue(a.isReady("test.tiny"))
        assertFalse(old.exists(), "moved, not copied")
        assertEquals(0, requests)
        val wrong = File(tmp, "old/wrong.bin").apply { writeBytes(ByteArray(10)) }
        assertFalse(store("app.b", root = File(tmp, "other")).adopt("test.tiny", mapOf("weights.bin" to wrong)))
        assertTrue(wrong.exists(), "a file that doesn't match stays where it was")
    }

    @Test
    fun `a claim on a model whose file went missing is still releasable`() {
        val a = store("app.a")
        a.ensure("test.tiny")
        a.pathOf("test.tiny", "weights.bin").delete()
        assertFalse(a.isReady("test.tiny"))
        assertEquals(setOf("test.tiny"), a.claimedByThisApp())
        a.release("test.tiny")
        assertTrue(a.claimedByThisApp().isEmpty())
    }
}
