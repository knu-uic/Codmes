package com.codmes.android

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.TimeUnit

class VersionedDocumentTest {
    @Test fun selectiveModesPreservePrivateEditsAndServerModeDoesNotRetainPayload() = Fixture().use { f ->
        val phone = f.document("phone"); phone.open(); phone.save("same book".toByteArray()); phone.flush()
        val mac = f.document("mac"); mac.storagePolicies.set("Notes", "server")
        assertEquals("same book", mac.open().toString(Charsets.UTF_8)); assertTrue(mac.localContent().isEmpty())
        mac.storagePolicies.set("Notes/book.md", "sync"); mac.open(); mac.storagePolicies.set("Notes/book.md", "local"); mac.save("private edit".toByteArray()); mac.flush()
        assertEquals(1, mac.pendingCount()); assertEquals("same book", phone.open().toString(Charsets.UTF_8)); assertEquals("private edit", mac.open().toString(Charsets.UTF_8))
        mac.storagePolicies.set("Notes/book.md", null); assertEquals("server", mac.storageMode)
    }
    @Test fun independentSameContentAdoptsButDifferentContentRequiresChoice() = Fixture().use { f ->
        val phone = f.document("phone"); val mac = f.document("mac"); val tablet = f.document("tablet")
        phone.save("book".toByteArray()); mac.save("book".toByteArray()); tablet.save("different book".toByteArray())
        phone.flush(); mac.flush(); assertEquals(0, mac.pendingCount())
        try { tablet.flush(); fail("must ask") } catch (_: FirstRegistrationConflict) { }
        assertEquals("different book", tablet.localContent().toString(Charsets.UTF_8))
        tablet.resolveFirstConflict(false); tablet.flush(); assertEquals("different book", phone.open().toString(Charsets.UTF_8))
    }
    private class Fixture : AutoCloseable {
        val storage = Files.createTempDirectory("codmes-kotlin-wire-").toFile()
        val http = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
        private val process: Process
        val url: String
        init {
            var root = File(System.getProperty("user.dir") ?: error("Missing working directory")).absoluteFile
            while (!File(root, "server/lib/test-support/versioned-http-fixture.mjs").exists()) root = root.parentFile ?: error("Missing fixture")
            process = ProcessBuilder("node", File(root, "server/lib/test-support/versioned-http-fixture.mjs").path).start()
            url = JSONObject(process.inputStream.bufferedReader().readLine() ?: error("Fixture did not start")).getString("url")
        }
        fun document(device: String, resource: String = "file", profile: String = "a", directory: File = File(storage, device)) =
            VersionedDocument(http, url, "test-profile-$profile", profile, if (resource == "file") "Notes/book.md" else "Notes/book.pdf", resource, device, directory)
        fun post(endpoint: String) { http.newCall(Request.Builder().url(url + endpoint).header("Authorization", "Bearer test-profile-a").post(ByteArray(0).toRequestBody()).build()).execute().close() }
        override fun close() {
            try { post("/fixture/stop") } finally {
                if (!process.waitFor(10, TimeUnit.SECONDS)) process.destroyForcibly()
                http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll(); storage.deleteRecursively()
            }
        }
    }
    private fun time(second: Int) = Instant.parse("2026-01-01T00:00:${second.toString().padStart(2, '0')}Z").toEpochMilli()

    @Test fun identicalReadsAreDeduplicatedAndPendingEditsSurviveCleanup() = Fixture().use { f ->
        val storage = File(f.storage, "bounded"); val local = f.document("Android", directory = storage); local.open()
        for (n in 0 until 20) local.save("offline $n".toByteArray(), time(n))
        val restarted = f.document("Android", directory = storage)
        assertEquals(20, restarted.pendingCount()); assertEquals(20, storage.walkTopDown().count { it.name.endsWith(".blob") })
        restarted.flush()
        repeat(20) { restarted.open(); restarted.save("offline 19".toByteArray()) }
        assertEquals(1, storage.walkTopDown().count { it.name.endsWith(".blob") }); assertEquals(0, restarted.pendingCount())
    }
    @Test fun undoRedoGroupsTypingAndBoundsCountAndMemory() {
        val history = EditHistory(); history.record("", 1000, true); history.record("h", 1200, true)
        assertEquals("", history.undo("hi")); assertEquals("hi", history.redo(""))
        history.undo("hi"); history.record("replacement"); assertFalse(history.canRedo)
        history.clear(); repeat(200) { history.record(it.toString()) }
        var count = 0; while (history.undo("current") != null) count++; assertEquals(80, count)
        history.clear(); history.record("x".repeat(9 * 1024 * 1024)); assertFalse(history.canUndo)
    }
    @Test fun pdfSyncMetadataPreservesUndoButRemoteContentInvalidatesIt() {
        val a = JSONObject("""{"pages":[{"pageIndex":0,"objects":[]}],"objects":[]}""")
        val b = JSONObject(a.toString()); VersionedDocument.ensurePageIds(b); b.put("updatedAt", "new").put("documentPath", "Notes/book.pdf")
        assertTrue(VersionedDocument.annotationContentEqual(a, b))
        b.getJSONArray("pages").getJSONObject(0).getJSONArray("objects").put(JSONObject().put("id", "remote").put("text", "changed"))
        assertFalse(VersionedDocument.annotationContentEqual(a, b))
    }

    @Test fun nativeKotlinHeadersPreserveIndependentWordsDespiteReversedArrival() = Fixture().use { f ->
        val seed = f.document("seed"); seed.open(); seed.save("red cat\n".toByteArray(), time(0)); seed.flush()
        val phone = f.document("Android"); val windows = f.document("Windows")
        phone.open(); windows.open()
        phone.save("blue cat\n".toByteArray(), time(10)); windows.save("red dog\n".toByteArray(), time(20))
        windows.flush(); phone.flush()
        assertEquals("blue dog\n", phone.open().toString(Charsets.UTF_8)); assertEquals(0, phone.pendingCount())
    }
    @Test fun responseLossRestartAndDraftPinRetainOriginalOperations() = Fixture().use { f ->
        val directory = File(f.storage, "restart")
        val local = f.document("Android", directory = directory); local.open(); local.save("first\n".toByteArray(), time(0))
        f.post("/fixture/drop-next")
        try { local.flush(); fail("Response should be lost") } catch (_: Exception) { }
        assertEquals(1, local.pendingCount())
        local.save("second\n".toByteArray(), time(10))
        val reopened = f.document("Android", directory = directory)
        assertEquals(2, reopened.pendingCount()); reopened.flush()
        assertEquals("second\n", reopened.open().toString(Charsets.UTF_8))
        val remote = f.document("other"); remote.open(); remote.save("remote\n".toByteArray(), time(20)); remote.flush()
        reopened.pinDraft(); assertEquals("second\n", reopened.open().toString(Charsets.UTF_8))
        reopened.save("new draft\n".toByteArray(), time(30)); reopened.flush()
        assertEquals("new draft\n", remote.open().toString(Charsets.UTF_8))
        directory.walkTopDown().filter { it.name == "journal.json" }.forEach { assertFalse(it.readText().contains("test-profile-a")) }
    }
    @Test fun annotationPropertiesAndNewStrokesUseActualServerMerge() = Fixture().use { f ->
        f.http.newCall(Request.Builder().url(f.url + "/api/sync/blob?path=Notes%2Fbook.pdf&resource=file").header("Authorization", "Bearer test-profile-a").header("X-Codmes-Base-Revision", "missing").put("%PDF fixture".toByteArray().toRequestBody()).build()).execute().use { assertTrue(it.isSuccessful) }
        val seed = f.document("seed", "annotations"); seed.open()
        val initial = JSONObject("""{"schemaVersion":2,"pages":[{"pageIndex":0,"objects":[{"id":"box","text":"base","bbox":{"x":0.1,"y":0.2}}],"inkStrokes":[]}],"objects":[]}""")
        VersionedDocument.ensurePageIds(initial); seed.save(initial.toString().toByteArray(), time(0)); seed.flush()
        assertTrue(VersionedDocument.annotationContentEqual(initial, JSONObject(seed.open().toString(Charsets.UTF_8))))
        val pen = f.document("Android", "annotations"); val text = f.document("Windows", "annotations")
        val a = JSONObject(pen.open().toString(Charsets.UTF_8)); val b = JSONObject(text.open().toString(Charsets.UTF_8))
        a.getJSONArray("pages").getJSONObject(0).getJSONArray("objects").getJSONObject(0).getJSONObject("bbox").put("x", .8)
        a.getJSONArray("pages").getJSONObject(0).getJSONArray("inkStrokes").put(JSONObject("""{"id":"stroke","points":[{"x":0.1,"y":0.2,"pressure":0.5}]}"""))
        b.getJSONArray("pages").getJSONObject(0).getJSONArray("objects").getJSONObject(0).put("text", "latest")
        pen.save(a.toString().toByteArray(), time(10)); text.save(b.toString().toByteArray(), time(20)); text.flush(); pen.flush()
        val page = JSONObject(pen.open().toString(Charsets.UTF_8)).getJSONArray("pages").getJSONObject(0)
        assertEquals(.8, page.getJSONArray("objects").getJSONObject(0).getJSONObject("bbox").getDouble("x"), .0001)
        assertEquals("latest", page.getJSONArray("objects").getJSONObject(0).getString("text")); assertEquals("stroke", page.getJSONArray("inkStrokes").getJSONObject(0).getString("id"))
    }
    @Test fun differentProfilesHaveSeparateDiskAndServerData() = Fixture().use { f ->
        val a = f.document("Android", directory = f.storage); val b = f.document("Android", profile = "b", directory = f.storage)
        a.open(); a.save("private".toByteArray(), time(0)); a.flush()
        assertTrue(b.open().isEmpty()); assertTrue(b.localContent().isEmpty())
    }
}
