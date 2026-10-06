package com.codmes.android

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

/** Same snapshot/operation contract as Swift and C#. Credentials never enter the journal. */
internal class VersionedDocument(
    private val http: OkHttpClient, server: String, @Volatile private var auth: String,
    profile: String, private val path: String, private val resource: String,
    private val deviceId: String, storage: File
) {
    private val server = server.trimEnd('/')
    private val directory = File(storage, hash(JSONArray(listOf(this.server, profile, path, resource)).toString().toByteArray()))
    private val lock = Any()
    private val uploadLock = Any()
    private var state: JSONObject
    private var generation = 0L
    private var draftPinned = false
    private var conflictRevision: String? = null
    val storagePolicies = WorkspaceStoragePolicies(this.server, profile, storage)
    val storageMode: String get() = storagePolicies.mode(path)
    fun reportPolicy(catalogIdentity: String? = null) {
        synchronized(lock) { if (!state.has("fileId") && !state.has("object") && pendingCount() == 0 && catalogIdentity != null) { state.put("fileId", catalogIdentity); commit() } }
        val policy = synchronized(lock) { if (!state.has("fileId")) return else JSONObject().put("fileId", state.getString("fileId")).put("mode", storageMode).put("locallyAvailable", state.has("object")).put("pending", pendingCount() > 0) }
        val data = JSONObject().put("deviceId", deviceId).put("policies", JSONArray().put(policy))
        http.newCall(builder("/api/sync/devices").post(data.toString().toRequestBody("application/json".toMediaType())).build()).execute().use { check(it.isSuccessful) { "기기 저장 모드 보고를 다시 시도하세요." } }
    }
    fun evictIfClean() = synchronized(lock) { if (storageMode == "server" && pendingCount() == 0 && !draftPinned) { state.remove("object"); commit() } }
    fun adoptIdenticalEntry(entry: JSONObject): Boolean = synchronized(lock) {
        if (state.has("fileId") || !state.has("object") || draftPinned || resource != "file" || path.endsWith(".pdf", true) || state.optString("revision") != entry.getString("revision") || !entry.has("fileId")) return@synchronized false
        state.put("fileId", entry.getString("fileId")).put("pending", JSONArray()).put("version", entry.optString("versionId").ifEmpty { "legacy:${state.getString("revision")}" }); state.remove("expectedRevision")
        if (storageMode == "local") storagePolicies.set(path, "sync"); commit(); true
    }
    init {
        require((path.startsWith("Notes/") || path.startsWith("Code/")) && path.split('/').none { it in setOf("", ".", "..", ".codmes", ".git") } && !path.contains('\\')) { "Invalid document path" }
        val uri = URI(this.server)
        require(uri.scheme == "https" || (uri.scheme == "http" && uri.host in setOf("localhost", "127.0.0.1", "::1"))) { "Remote synchronization requires HTTPS" }
        directory.mkdirs()
        val journal = File(directory, "journal.json")
        state = if (journal.exists()) JSONObject(journal.readText()) else JSONObject().put("pending", JSONArray()).put("lastTime", 0L)
        if (!state.has("localId")) { state.put("localId", UUID.randomUUID().toString()); commit() }
        cleanObjects()
    }
    companion object {
        fun hash(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        fun ensurePageIds(document: JSONObject) {
            val pages = document.optJSONArray("pages") ?: return
            for (index in 0 until pages.length()) { val page = pages.getJSONObject(index); if (!page.has("pageId")) page.put("pageId", "index:${page.getInt("pageIndex")}") }
        }
        fun annotationContentEqual(a: JSONObject, b: JSONObject): Boolean {
            fun canonical(value: Any?): String = when (value) {
                is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(prefix = "{", postfix = "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
                is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.get(it)) }
                is String -> JSONObject.quote(value)
                is Number -> java.math.BigDecimal(value.toString()).stripTrailingZeros().toPlainString()
                null, JSONObject.NULL -> "null"
                else -> value.toString()
            }
            fun normalize(input: JSONObject): JSONObject {
                val copy = JSONObject(input.toString()); copy.remove("updatedAt"); copy.remove("documentPath"); ensurePageIds(copy)
                for (key in listOf("objects", "elements", "pages")) if (copy.isNull(key)) copy.put(key, JSONArray())
                val currentPages = copy.getJSONArray("pages")
                for (index in 0 until currentPages.length()) for (key in listOf("objects", "elements", "inkStrokes")) if (currentPages.getJSONObject(index).isNull(key)) currentPages.getJSONObject(index).put(key, JSONArray())
                copy.optJSONArray("pages")?.let { pages -> copy.put("pages", JSONArray((0 until pages.length()).map { pages.getJSONObject(it) }.sortedBy { it.getInt("pageIndex") })) }
                return copy
            }
            return canonical(normalize(a)) == canonical(normalize(b))
        }
    }
    private fun writeDurably(file: File, bytes: ByteArray) { FileOutputStream(file).use { it.write(bytes); it.fd.sync() } }
    fun updateAuth(value: String) { auth = value }
    fun pinDraft() = synchronized(lock) { draftPinned = true; generation++ }
    private fun commit() {
        val temporary = File(directory, "${UUID.randomUUID()}.tmp")
        writeDurably(temporary, state.toString().toByteArray())
        if (!temporary.renameTo(File(directory, "journal.json"))) error("Could not commit local document journal")
        cleanObjects()
    }
    private fun cleanObjects() {
        val list = state.getJSONArray("pending")
        val retained = (0 until list.length()).map { list.getJSONObject(it).getString("object") }.toMutableSet()
        state.optString("object").takeIf { it.isNotEmpty() }?.let { retained.add(it) }
        // The durable journal is authoritative; pending intermediate saves are not garbage.
        directory.listFiles()?.filter { it.name.endsWith(".blob") && !retained.contains(it.name) && !java.nio.file.Files.isSymbolicLink(it.toPath()) }?.forEach { try { it.delete() } catch (_: Exception) { } }
    }
    private fun storeObject(bytes: ByteArray): String {
        val name = "${hash(bytes)}.blob"
        val destination = File(directory, name)
        if (!destination.exists()) {
            val temporary = File(directory, "${UUID.randomUUID()}.tmp")
            writeDurably(temporary, bytes)
            check(temporary.renameTo(destination)) { "Could not save local document" }
        } else check(hash(destination.readBytes()) == hash(bytes)) { "Damaged local content; changes were not discarded" }
        return name
    }
    private fun builder(endpoint: String): Request.Builder = Request.Builder().url(server + endpoint).apply { if (auth.isNotEmpty()) header("Authorization", "Bearer $auth") }
    private fun query() = "path=${URLEncoder.encode(path, "UTF-8")}&resource=$resource"
    private fun bytes(endpoint: String): ByteArray = http.newCall(builder(endpoint).build()).execute().use { response ->
        val body = response.body?.bytes() ?: ByteArray(0)
        if (!response.isSuccessful) error("Synchronization pending (${response.code}): ${body.toString(Charsets.UTF_8)}")
        body
    }
    fun localContent(): ByteArray = synchronized(lock) { state.optString("object").takeIf { it.isNotEmpty() }?.let { File(directory, it).readBytes() } ?: ByteArray(0) }
    fun pendingCount(): Int = synchronized(lock) { state.getJSONArray("pending").length() }
    fun open(): ByteArray {
        if (storageMode == "local") { check(synchronized(lock) { state.has("object") }) { "이 기기에 로컬 사본이 없습니다. 연결 후 동기화 모드로 내려받으세요." }; return localContent() }
        val started = synchronized(lock) { generation }
        if (pendingCount() > 0) try { flush() } catch (error: FirstRegistrationConflict) { throw error } catch (_: Exception) { return localContent() }
        try {
            val manifest = JSONObject(bytes("/api/sync/manifest").toString(Charsets.UTF_8))
            val policies = manifest.optJSONArray("conflictPolicies")
            check((0 until (policies?.length() ?: 0)).any { policies!!.getString(it) == "merge-modified-v2" }) { "Update the server to enable change-based synchronization" }
            val entries = manifest.getJSONArray("entries")
            val entry = (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.getString("path") == path && it.getString("resource") == resource }
            val revision = entry?.getString("revision")
            val size = entry?.optLong("size") ?: 0
            check(size <= 64 * 1024 * 1024) { "이 플랫폼의 대용량 다운로드는 보류되었습니다. 서버에서 열거나 Apple 클라이언트를 사용하세요." }
            check(size <= (Long.MAX_VALUE - 8 * 1024 * 1024) / 2 && directory.usableSpace > size * 2 + 8 * 1024 * 1024) { "저장공간이 부족합니다. 다운로드를 보류했습니다." }
            val data = if (entry != null) bytes("/api/sync/blob?${query()}&revision=$revision") else if (resource == "annotations") "{\"schemaVersion\":2,\"pages\":[],\"objects\":[]}".toByteArray() else ByteArray(0)
            if (revision != null) check(hash(data) == revision) { "Incomplete synchronization download" }
            synchronized(lock) {
                if (pendingCount() > 0 || draftPinned || generation != started) return localContent()
                val identityEntry = if (resource == "annotations") (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.getString("path") == path && it.getString("resource") == "file" } else entry
                if (identityEntry?.has("fileId") == true) state.put("fileId", identityEntry.getString("fileId"))
                val name = if (storageMode == "server") null else storeObject(data)
                if (name == null) state.remove("object") else state.put("object", name)
                state.put("revision", revision ?: JSONObject.NULL)
                    .put("version", entry?.optString("versionId")?.takeIf { it.isNotEmpty() } ?: revision?.let { "legacy:$it" } ?: JSONObject.NULL)
                entry?.optString("logicalModifiedAt")?.takeIf { it.isNotEmpty() }?.let { state.put("lastTime", maxOf(state.optLong("lastTime"), Instant.parse(it).toEpochMilli())) }
                if (entry == null) {
                    val deleted = manifest.optJSONArray("deletedEntries") ?: JSONArray()
                    for (index in 0 until deleted.length()) {
                        val item = deleted.getJSONObject(index)
                        if (item.getString("path") == path && item.getString("resource") == resource) { state.put("version", item.getString("versionId")); state.put("lastTime", maxOf(state.optLong("lastTime"), Instant.parse(item.getString("modifiedAt")).toEpochMilli())) }
                    }
                }
                commit()
            }
            return data
        } catch (error: FirstRegistrationConflict) { throw error }
        catch (error: Exception) { synchronized(lock) { if (state.has("object")) return localContent() }; throw error }
    }
    fun save(content: ByteArray, modifiedAt: Long = System.currentTimeMillis()) = synchronized(lock) {
        if (state.has("object") && localContent().contentEquals(content)) { commit(); draftPinned = false; return@synchronized }
        val time = maxOf(modifiedAt, state.optLong("lastTime") + 1)
        val id = UUID.randomUUID().toString(); val name = storeObject(content)
        val change = JSONObject().put("path", path).put("resource", resource).put("action", "put")
            .put("baseRevision", state.opt("revision") ?: JSONObject.NULL).put("baseVersion", state.opt("version") ?: JSONObject.NULL)
            .put("operationId", id).put("deviceId", deviceId).put("modifiedAt", Instant.ofEpochMilli(time).toString()).put("conflictPolicy", "merge-modified-v2")
        state.getJSONArray("pending").put(JSONObject().put("change", change).put("object", name))
        state.put("object", name).put("revision", hash(content)).put("version", id).put("lastTime", time); generation++; commit(); draftPinned = false
    }
    fun flush(): Unit = synchronized(uploadLock) upload@ {
        if (storageMode == "local") return@upload
        while (true) {
            if (storageMode == "local") return@upload
            val pending = synchronized(lock) { if (pendingCount() == 0) return@upload else JSONObject(state.getJSONArray("pending").getJSONObject(0).toString()) }
            val change = pending.getJSONObject("change")
            if (!state.has("fileId")) {
                val checking = synchronized(lock) { generation to state.optString("revision") }
                val listing = JSONObject(bytes("/api/sync/manifest").toString(Charsets.UTF_8)).getJSONArray("entries")
                val entry = (0 until listing.length()).map { listing.getJSONObject(it) }.firstOrNull { it.getString("path") == path && it.getString("resource") == resource }
                if (entry?.has("fileId") == true) {
                    // Matching originals alone are not proof that PDF ink matches.
                    val same = resource == "file" && !path.endsWith(".pdf", true) && checking.second == entry.getString("revision")
                    if (synchronized(lock) { generation != checking.first }) continue
                    if (entry.getString("fileId") != state.getString("localId") && change.isNull("baseRevision") && !same) { conflictRevision = entry.getString("revision"); throw FirstRegistrationConflict(path) }
                    var changed = false
                    synchronized(lock) {
                        if (generation != checking.first) changed = true else {
                            state.put("fileId", entry.getString("fileId"))
                            if (same) state.put("pending", JSONArray()).put("revision", entry.getString("revision")).put("version", entry.optString("versionId").ifEmpty { "legacy:${entry.getString("revision")}" })
                            commit()
                        }
                    }
                    if (changed) continue
                    if (same) return@upload
                }
            }
            val request = builder("/api/sync/blob?${query()}")
                .header("X-Codmes-Base-Revision", if (change.isNull("baseRevision")) "missing" else change.getString("baseRevision"))
                .header("X-Codmes-Conflict-Policy", "merge-modified-v2")
                .header("X-Codmes-Operation-ID", change.getString("operationId"))
                .header("X-Codmes-Device-ID", deviceId).header("X-Codmes-Modified-At", change.getString("modifiedAt"))
            if (!change.isNull("baseVersion")) request.header("X-Codmes-Base-Version", change.getString("baseVersion"))
            synchronized(lock) { request.header("X-Codmes-File-ID", state.optString("fileId").ifEmpty { state.getString("localId") }); state.optString("expectedRevision").takeIf { it.isNotEmpty() }?.let { request.header("X-Codmes-Expected-Revision", it) } }
            request.put(File(directory, pending.getString("object")).readBytes().toRequestBody("application/octet-stream".toMediaType()))
            http.newCall(request.build()).execute().use { response ->
                val body = response.body?.string().orEmpty()
                check(response.isSuccessful) { "Local content saved; synchronization pending (${response.code}): $body" }
                val result = JSONObject(body)
                if (result.getString("status") != "applied") {
                    if (result.optString("reason") in setOf("first-registration", "decision-stale")) { conflictRevision = result.optJSONObject("entry")?.optString("revision"); throw FirstRegistrationConflict(path) }
                    error("Local content saved; a structural/base conflict remains pending")
                }
                result.optJSONObject("entry")?.optString("fileId")?.takeIf { it.isNotEmpty() }?.let { synchronized(lock) { state.put("fileId", it) } }
            }
            synchronized(lock) {
                val list = state.getJSONArray("pending")
                val remaining = JSONArray()
                for (index in 0 until list.length()) if (list.getJSONObject(index).getJSONObject("change").getString("operationId") != change.getString("operationId")) remaining.put(list.getJSONObject(index))
                state.put("pending", remaining); if (remaining.length() == 0) state.remove("expectedRevision"); commit()
            }
        }
    }
    fun resolveFirstConflict(useServer: Boolean) {
        check(resource != "file" || !path.endsWith(".pdf", true)) { "PDF 원본·필기의 안전한 공동 교체는 Apple 클라이언트에서 결정하세요. 로컬 PDF는 보존됩니다." }
        val listing = JSONObject(bytes("/api/sync/manifest").toString(Charsets.UTF_8)).getJSONArray("entries")
        val entry = (0 until listing.length()).map { listing.getJSONObject(it) }.first { it.getString("path") == path && it.getString("resource") == resource }
        val revision = entry.getString("revision"); val version = entry.optString("versionId").ifEmpty { "legacy:$revision" }
        if (conflictRevision != null && revision != conflictRevision) { conflictRevision = revision; error("서버 파일이 변경됐습니다. 최신 버전을 다시 확인하세요.") }
        val captured = synchronized(lock) { generation }
        val downloaded = if (useServer) bytes("/api/sync/blob?${query()}&revision=$revision").also { check(hash(it) == revision) { "Server file changed. Confirm again." } } else null
        synchronized(lock) {
            check(generation == captured) { "Local file changed. Confirm again." }
            state.put("fileId", entry.getString("fileId")).put("pending", JSONArray()).put("revision", revision).put("version", version)
            if (downloaded != null) state.put("object", storeObject(downloaded)) else {
                val data = localContent(); val id = UUID.randomUUID().toString(); val time = maxOf(System.currentTimeMillis(), state.optLong("lastTime") + 1)
                val change = JSONObject().put("path", path).put("resource", resource).put("action", "put").put("baseRevision", revision).put("baseVersion", version).put("operationId", id).put("deviceId", deviceId).put("modifiedAt", Instant.ofEpochMilli(time).toString()).put("conflictPolicy", "merge-modified-v2")
                state.getJSONArray("pending").put(JSONObject().put("change", change).put("object", state.getString("object")))
                state.put("expectedRevision", revision).put("revision", hash(data)).put("version", id).put("lastTime", time)
            }
            commit()
        }
    }
}
internal class FirstRegistrationConflict(path: String) : java.io.IOException("서버에 같은 경로의 다른 파일이 있습니다: $path")

internal class WorkspaceStoragePolicies(server: String, profile: String, storage: File) {
    private val directory = File(storage, ".policies/${VersionedDocument.hash(JSONArray(listOf(server.trimEnd('/'), profile)).toString().toByteArray())}")
    init { directory.mkdirs() }
    companion object { private val gate = Any() }
    private fun read(): JSONObject { val file = File(directory, "modes.json"); return if (file.exists()) JSONObject(file.readText()) else JSONObject() }
    private fun key(path: String): String {
        val entries = cachedCatalog()?.optJSONArray("entries") ?: return path
        val entry = (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.optString("path") == path && it.optString("resource") != "annotations" }
        return entry?.optString("fileId")?.takeIf { it.isNotEmpty() }?.let { "id:$it" } ?: path
    }
    fun mode(path: String): String = synchronized(gate) {
        val values = read(); var scope = path
        while (scope.isNotEmpty()) { val identity = key(scope); if (values.has(identity)) return@synchronized values.getString(identity); if (values.has(scope)) return@synchronized values.getString(scope); scope = scope.substringBeforeLast('/', "") }
        "sync"
    }
    fun set(path: String, mode: String?) = synchronized(gate) {
        require(mode == null || mode in setOf("local", "server", "sync"))
        val values = read(); val identity = key(path); values.remove(path); if (mode == null) values.remove(identity) else values.put(identity, mode)
        val temporary = File(directory, "${UUID.randomUUID()}.tmp")
        FileOutputStream(temporary).use { it.write(values.toString().toByteArray()); it.fd.sync() }
        check(temporary.renameTo(File(directory, "modes.json"))) { "Could not save storage mode" }
    }
    fun cacheCatalog(value: JSONObject) = synchronized(gate) {
        val temporary = File(directory, "${UUID.randomUUID()}.tmp"); temporary.writeText(value.toString()); check(temporary.renameTo(File(directory, "catalog.json")))
    }
    fun cachedCatalog(): JSONObject? = synchronized(gate) { File(directory, "catalog.json").takeIf { it.exists() }?.let { JSONObject(it.readText()) } }
}

/** Only recent edits in the open editor. Never persisted or synchronized. */
internal class EditHistory {
    private val undo = mutableListOf<String>()
    private val redo = mutableListOf<String>()
    private var lastEdit: Long? = null
    val canUndo: Boolean get() = undo.isNotEmpty()
    val canRedo: Boolean get() = redo.isNotEmpty()
    fun clear() { undo.clear(); redo.clear(); lastEdit = null }
    fun record(before: String, time: Long = System.currentTimeMillis(), groupTyping: Boolean = false) {
        if (!groupTyping || lastEdit == null || time - lastEdit!! > 600 || redo.isNotEmpty()) undo.add(before)
        redo.clear(); lastEdit = if (groupTyping) time else null; trim()
    }
    fun undo(current: String): String? { if (!canUndo) return null; val value = undo.removeAt(undo.lastIndex); redo.add(current); lastEdit = null; trim(); return value }
    fun redo(current: String): String? { if (!canRedo) return null; val value = redo.removeAt(redo.lastIndex); undo.add(current); lastEdit = null; trim(); return value }
    private fun trim() {
        while (undo.size + redo.size > 80 || (undo + redo).sumOf { it.toByteArray().size.toLong() } > 8 * 1024 * 1024)
            if (undo.isNotEmpty()) undo.removeAt(0) else if (redo.isNotEmpty()) redo.removeAt(0) else break
    }
}
