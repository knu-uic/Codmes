using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Codmes.Windows;

// Portable wire contract: immutable local snapshots + durable, ordered operations.
// No credentials are written into the document journal.
internal sealed class VersionedDocument
{
    internal sealed record Change(string path, string resource, string action, string? baseRevision,
        string? baseVersion, string operationId, string deviceId, string modifiedAt,
        string conflictPolicy = "merge-modified-v2");
    internal sealed record Pending(Change Change, string Object);
    internal sealed class Journal
    {
        public string? Revision { get; set; }
        public string? Version { get; set; }
        public string? Object { get; set; }
        public long LastTime { get; set; }
        public List<Pending> Pending { get; set; } = [];
        public string? FileId { get; set; }
        public string LocalId { get; set; } = Guid.NewGuid().ToString();
        public string? ExpectedRevision { get; set; }
    }
    private readonly string directory;
    private readonly string path;
    private readonly string resource;
    private readonly string deviceId;
    private readonly string server;
    private string auth;
    private readonly HttpClient http;
    private readonly object journalLock = new();
    private readonly SemaphoreSlim uploadLock = new(1, 1);
    private Journal state;
    private long generation;
    private bool draftPinned;
    private string? conflictRevision;
    internal readonly WorkspaceStoragePolicies StoragePolicies;
    internal string StorageMode => StoragePolicies.Mode(path);
    internal async Task ReportPolicyAsync(string? catalogIdentity = null) {
        lock (journalLock) { if (state.FileId == null && state.Object == null && state.Pending.Count == 0 && catalogIdentity != null) { state.FileId = catalogIdentity; Commit(); } }
        object? report; lock (journalLock) report = state.FileId == null ? null : new { fileId = state.FileId, mode = StorageMode, locallyAvailable = state.Object != null, pending = state.Pending.Count > 0 };
        if (report == null) return;
        using var request = Request(HttpMethod.Post, "/api/sync/devices");
        request.Content = new StringContent(JsonSerializer.Serialize(new { deviceId, policies = new[] { report } }), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode();
    }
    internal void EvictIfClean() { lock (journalLock) { if (StorageMode == "server" && state.Pending.Count == 0 && !draftPinned) { state.Object = null; Commit(); } } }
    internal bool AdoptIdenticalEntry(JsonElement entry) {
        lock (journalLock) {
            if (state.FileId != null || state.Object == null || draftPinned || resource != "file" || path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) || state.Revision != entry.GetProperty("revision").GetString() || !entry.TryGetProperty("fileId", out var identity)) return false;
            state.FileId = identity.GetString(); state.Pending.Clear(); state.ExpectedRevision = null;
            state.Version = entry.TryGetProperty("versionId", out var version) ? version.GetString() : "legacy:" + state.Revision;
            if (StorageMode == "local") StoragePolicies.Set(path, "sync"); Commit(); return true;
        }
    }

    internal VersionedDocument(HttpClient http, string server, string auth, string profile, string path, string resource, string deviceId, string? storageRoot = null)
    {
        if (!path.StartsWith("Notes/", StringComparison.Ordinal) && !path.StartsWith("Code/", StringComparison.Ordinal)) throw new ArgumentException("Invalid document path.");
        if (path.Split('/').Any(p => p is "" or "." or ".." or ".codmes" or ".git") || path.Contains('\\')) throw new ArgumentException("Invalid document path.");
        this.http = http; this.server = server.TrimEnd('/'); this.auth = auth; this.path = path; this.resource = resource; this.deviceId = deviceId;
        var uri = new Uri(this.server);
        if (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback)) throw new ArgumentException("Remote synchronization requires HTTPS.");
        storageRoot ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codmes", "Documents-v2");
        StoragePolicies = new WorkspaceStoragePolicies(this.server, profile, storageRoot);
        directory = Path.Combine(storageRoot, Hash(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { this.server, profile, path, resource }))));
        Directory.CreateDirectory(directory);
        var journal = Path.Combine(directory, "journal.json");
        state = File.Exists(journal) ? JsonSerializer.Deserialize<Journal>(File.ReadAllText(journal)) ?? throw new IOException("Invalid document journal.") : new();
        CleanObjects();
    }
    internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    internal void UpdateAuth(string token) { auth = token; }
    // An editor's debounce window must not silently acquire a different merge base.
    internal void PinDraft() { lock (journalLock) { draftPinned = true; generation++; } }
    private void Commit()
    {
        var temporary = Path.Combine(directory, Guid.NewGuid() + ".tmp");
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write)) { JsonSerializer.Serialize(stream, state); stream.Flush(true); }
        File.Move(temporary, Path.Combine(directory, "journal.json"), true);
        CleanObjects();
    }
    private void CleanObjects()
    {
        var retained = state.Pending.Select(p => p.Object).ToHashSet(StringComparer.Ordinal);
        if (state.Object != null) retained.Add(state.Object);
        // Only owned payloads, after the durable journal commit. Cleanup is best-effort.
        try { foreach (var file in Directory.EnumerateFiles(directory, "*.blob"))
            if (!retained.Contains(Path.GetFileName(file)) && (File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0)
                try { File.Delete(file); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    private string StoreObject(byte[] bytes)
    {
        var name = Hash(bytes) + ".blob";
        var destination = Path.Combine(directory, name);
        if (!File.Exists(destination)) {
            var temporary = Path.Combine(directory, Guid.NewGuid() + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write)) { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, destination, true);
        } else if (Hash(File.ReadAllBytes(destination)) != Hash(bytes)) throw new IOException("Damaged local content; changes were not discarded.");
        return name;
    }
    private HttpRequestMessage Request(HttpMethod method, string endpoint)
    {
        var request = new HttpRequestMessage(method, server + endpoint);
        if (auth.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", auth);
        return request;
    }
    private string Query => $"path={Uri.EscapeDataString(path)}&resource={resource}";
    internal byte[] LocalContent { get { lock (journalLock) return state.Object == null ? [] : File.ReadAllBytes(Path.Combine(directory, state.Object)); } }
    internal int PendingCount { get { lock (journalLock) return state.Pending.Count; } }
    internal async Task<byte[]> OpenAsync()
    {
        if (StorageMode == "local") {
            lock (journalLock) { if (state.Object == null) throw new IOException("이 기기에 로컬 사본이 없습니다. 연결 후 동기화 모드로 내려받으세요."); }
            return LocalContent;
        }
        long started; lock (journalLock) started = generation;
        // A failed reconnect cannot replace an unsent local document.
        if (PendingCount > 0) { try { await FlushAsync(); } catch (FirstRegistrationConflict) { throw; } catch { return LocalContent; } }
        try
        {
            using var request = Request(HttpMethod.Get, "/api/sync/manifest");
            using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode();
            using var manifest = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            if (!manifest.RootElement.GetProperty("conflictPolicies").EnumerateArray().Any(p => p.GetString() == "merge-modified-v2")) throw new IOException("Update the server to enable change-based synchronization.");
            var entry = manifest.RootElement.GetProperty("entries").EnumerateArray().FirstOrDefault(e => e.GetProperty("path").GetString() == path && e.GetProperty("resource").GetString() == resource);
            byte[] data;
            string? revision = null, version = null; long observedTime = 0;
            if (entry.ValueKind != JsonValueKind.Undefined)
            {
                revision = entry.GetProperty("revision").GetString();
                version = entry.TryGetProperty("versionId", out var v) ? v.GetString() : "legacy:" + revision;
                var size = entry.GetProperty("size").GetInt64();
                if (size > 64 * 1024 * 1024) throw new IOException("이 플랫폼의 대용량 다운로드는 보류되었습니다. 서버에서 열거나 Apple 클라이언트를 사용하세요.");
                if (size > (long.MaxValue - 8 * 1024 * 1024) / 2 || new DriveInfo(Path.GetPathRoot(directory)!).AvailableFreeSpace < size * 2 + 8 * 1024 * 1024) throw new IOException("저장공간이 부족합니다. 다운로드를 보류했습니다.");
                using var download = Request(HttpMethod.Get, $"/api/sync/blob?{Query}&revision={revision}");
                using var downloaded = await http.SendAsync(download); downloaded.EnsureSuccessStatusCode();
                data = await downloaded.Content.ReadAsByteArrayAsync();
                if (Hash(data) != revision) throw new IOException("Incomplete synchronization download.");
                if (entry.TryGetProperty("logicalModifiedAt", out var clock)) observedTime = DateTimeOffset.Parse(clock.GetString()!).ToUnixTimeMilliseconds();
            }
            else
            {
                data = resource == "annotations" ? Encoding.UTF8.GetBytes("{\"schemaVersion\":2,\"pages\":[],\"objects\":[]}") : [];
                if (manifest.RootElement.TryGetProperty("deletedEntries", out var deleted))
                    foreach (var item in deleted.EnumerateArray()) if (item.GetProperty("path").GetString() == path && item.GetProperty("resource").GetString() == resource)
                    { version = item.GetProperty("versionId").GetString(); observedTime = DateTimeOffset.Parse(item.GetProperty("modifiedAt").GetString()!).ToUnixTimeMilliseconds(); }
            }
            lock (journalLock)
            {
                if (state.Pending.Count > 0 || draftPinned || generation != started) return LocalContent;
                var identityEntry = resource == "annotations" ? manifest.RootElement.GetProperty("entries").EnumerateArray().FirstOrDefault(e => e.GetProperty("path").GetString() == path && e.GetProperty("resource").GetString() == "file") : entry;
                if (identityEntry.ValueKind != JsonValueKind.Undefined && identityEntry.TryGetProperty("fileId", out var identity)) state.FileId = identity.GetString();
                var name = StorageMode == "server" ? null : StoreObject(data);
                state.LastTime = Math.Max(state.LastTime, observedTime);
                state.Object = name; state.Revision = revision; state.Version = version; Commit();
            }
            return data;
        }
        catch (FirstRegistrationConflict) { throw; }
        catch { lock (journalLock) { if (state.Object != null) return LocalContent; } throw; }
    }
    internal void Save(byte[] content, long? modifiedAt = null)
    {
        lock (journalLock)
        {
            if (state.Object != null && LocalContent.AsSpan().SequenceEqual(content)) { Commit(); draftPinned = false; return; }
            var time = Math.Max(modifiedAt ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), state.LastTime + 1);
            var id = Guid.NewGuid().ToString(); var name = StoreObject(content);
            var change = new Change(path, resource, "put", state.Revision, state.Version, id, deviceId, DateTimeOffset.FromUnixTimeMilliseconds(time).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"));
            state.Pending.Add(new(change, name)); state.Object = name; state.Revision = Hash(content); state.Version = id; state.LastTime = time; generation++; Commit(); draftPinned = false;
        }
    }
    internal async Task FlushAsync()
    {
        if (StorageMode == "local") return;
        await uploadLock.WaitAsync();
        try
        {
            while (true)
            {
                Pending pending;
                if (StorageMode == "local") return;
                lock (journalLock) { if (state.Pending.Count == 0) return; pending = state.Pending[0]; }
                var change = pending.Change;
                if (state.FileId == null) {
                    long checking; string? checkingRevision; lock (journalLock) { checking = generation; checkingRevision = state.Revision; }
                    using var listing = Request(HttpMethod.Get, "/api/sync/manifest");
                    using var listed = await http.SendAsync(listing); listed.EnsureSuccessStatusCode();
                    using var catalog = JsonDocument.Parse(await listed.Content.ReadAsStringAsync());
                    var existing = catalog.RootElement.GetProperty("entries").EnumerateArray().FirstOrDefault(e => e.GetProperty("path").GetString() == path && e.GetProperty("resource").GetString() == resource);
                    if (existing.ValueKind != JsonValueKind.Undefined && existing.TryGetProperty("fileId", out var id)) {
                        // Independently imported PDFs must compare their sibling ink too.
                        // Never infer whole-document equality from the original PDF alone.
                        var same = resource == "file" && !path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && checkingRevision == existing.GetProperty("revision").GetString();
                        lock (journalLock) { if (generation != checking) continue; }
                        if (id.GetString() != state.LocalId && change.baseRevision == null && !same) { conflictRevision = existing.GetProperty("revision").GetString(); throw new FirstRegistrationConflict(path); }
                        lock (journalLock) {
                            if (generation != checking) continue;
                            state.FileId = id.GetString();
                            if (same) { state.Pending.Clear(); state.Revision = existing.GetProperty("revision").GetString(); state.Version = existing.TryGetProperty("versionId", out var version) ? version.GetString() : "legacy:" + state.Revision; }
                            Commit();
                        }
                        if (same) return;
                    }
                }
                using var request = Request(HttpMethod.Put, "/api/sync/blob?" + Query);
                request.Headers.Add("X-Codmes-Base-Revision", change.baseRevision ?? "missing");
                request.Headers.Add("X-Codmes-Conflict-Policy", change.conflictPolicy);
                request.Headers.Add("X-Codmes-Operation-ID", change.operationId);
                request.Headers.Add("X-Codmes-Device-ID", change.deviceId);
                request.Headers.Add("X-Codmes-Modified-At", change.modifiedAt);
                if (change.baseVersion != null) request.Headers.Add("X-Codmes-Base-Version", change.baseVersion);
                request.Headers.Add("X-Codmes-File-ID", state.FileId ?? state.LocalId);
                if (state.ExpectedRevision != null) request.Headers.Add("X-Codmes-Expected-Revision", state.ExpectedRevision);
                request.Content = new ByteArrayContent(File.ReadAllBytes(Path.Combine(directory, pending.Object)));
                request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                using var response = await http.SendAsync(request);
                var body = await response.Content.ReadAsStringAsync();
                if (!response.IsSuccessStatusCode) throw new IOException($"Local content saved; synchronization pending ({(int)response.StatusCode}): {body}");
                using var result = JsonDocument.Parse(body);
                if (result.RootElement.GetProperty("status").GetString() != "applied") {
                    if (result.RootElement.TryGetProperty("reason", out var reason) && reason.GetString() is "first-registration" or "decision-stale") { if (result.RootElement.TryGetProperty("entry", out var conflict) && conflict.ValueKind == JsonValueKind.Object) conflictRevision = conflict.GetProperty("revision").GetString(); throw new FirstRegistrationConflict(path); }
                    throw new IOException("Local content saved; a structural/base conflict remains pending.");
                }
                lock (journalLock) {
                    if (result.RootElement.TryGetProperty("entry", out var entry) && entry.ValueKind == JsonValueKind.Object && entry.TryGetProperty("fileId", out var id)) state.FileId = id.GetString();
                    state.Pending.RemoveAll(p => p.Change.operationId == change.operationId);
                    if (state.Pending.Count == 0) state.ExpectedRevision = null;
                    Commit();
                }
            }
        }
        finally { uploadLock.Release(); }
    }
    internal async Task ResolveFirstConflictAsync(bool useServer)
    {
        if (resource == "file" && path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) throw new IOException("PDF 원본·필기의 안전한 공동 교체는 Apple 클라이언트에서 결정하세요. 로컬 PDF는 보존됩니다.");
        using var request = Request(HttpMethod.Get, "/api/sync/manifest"); using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode();
        using var manifest = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var entry = manifest.RootElement.GetProperty("entries").EnumerateArray().First(e => e.GetProperty("path").GetString() == path && e.GetProperty("resource").GetString() == resource);
        var revision = entry.GetProperty("revision").GetString()!;
        if (conflictRevision != null && revision != conflictRevision) { conflictRevision = revision; throw new IOException("서버 파일이 변경됐습니다. 최신 버전을 다시 확인하세요."); }
        var version = entry.TryGetProperty("versionId", out var v) ? v.GetString() : "legacy:" + revision;
        byte[]? downloaded = null;
        long captured; lock (journalLock) captured = generation;
        if (useServer) {
            using var download = Request(HttpMethod.Get, $"/api/sync/blob?{Query}&revision={revision}"); using var remote = await http.SendAsync(download); remote.EnsureSuccessStatusCode();
            downloaded = await remote.Content.ReadAsByteArrayAsync(); if (Hash(downloaded) != revision) throw new IOException("Server file changed. Confirm again.");
        }
        lock (journalLock) {
            if (generation != captured) throw new IOException("Local file changed. Confirm again.");
            state.FileId = entry.GetProperty("fileId").GetString(); state.Pending.Clear(); state.Revision = revision; state.Version = version;
            if (downloaded != null) state.Object = StoreObject(downloaded);
            else {
                var bytes = LocalContent; var id = Guid.NewGuid().ToString(); var time = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), state.LastTime + 1);
                state.Pending.Add(new(new Change(path, resource, "put", revision, version, id, deviceId, DateTimeOffset.FromUnixTimeMilliseconds(time).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")), state.Object!));
                state.ExpectedRevision = revision; state.Revision = Hash(bytes); state.Version = id; state.LastTime = time;
            }
            Commit();
        }
    }
    internal static void EnsurePageIds(JsonObject document)
    {
        if (document["pages"] is not JsonArray pages) return;
        foreach (var page in pages.OfType<JsonObject>()) if (page["pageId"] == null) page["pageId"] = "index:" + page["pageIndex"]!.GetValue<int>();
    }
    internal static bool AnnotationContentEqual(JsonObject a, JsonObject b)
    {
        JsonObject Normalize(JsonObject input) {
            var copy = input.DeepClone().AsObject(); copy.Remove("updatedAt"); copy.Remove("documentPath"); EnsurePageIds(copy);
            foreach (var key in new[] { "objects", "elements", "pages" }) copy[key] ??= new JsonArray();
            foreach (var page in copy["pages"]!.AsArray().OfType<JsonObject>())
                foreach (var key in new[] { "objects", "elements", "inkStrokes" }) page[key] ??= new JsonArray();
            if (copy["pages"] is JsonArray pages) copy["pages"] = new JsonArray(pages.OfType<JsonObject>().OrderBy(p => p["pageIndex"]!.GetValue<int>()).Select(p => (JsonNode)p.DeepClone()).ToArray());
            return copy;
        }
        return JsonNode.DeepEquals(Normalize(a), Normalize(b));
    }
}
internal sealed class FirstRegistrationConflict(string path) : IOException("서버에 같은 경로의 다른 파일이 있습니다: " + path);

// Device-local preferences. Folder defaults are resolved on every access, so an
// editor opened before a preference change cannot keep uploading in local mode.
internal sealed class WorkspaceStoragePolicies
{
    private static readonly object Gate = new();
    private readonly string directory;
    internal WorkspaceStoragePolicies(string server, string profile, string? storageRoot = null)
    {
        storageRoot ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codmes", "Documents-v2");
        directory = Path.Combine(storageRoot, ".policies", VersionedDocument.Hash(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { server.TrimEnd('/'), profile }))));
        Directory.CreateDirectory(directory);
    }
    private Dictionary<string, string> Read() => File.Exists(Path.Combine(directory, "modes.json")) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(directory, "modes.json"))) ?? [] : [];
    private string Key(string path) {
        var json = CachedCatalog(); if (json == null) return path;
        using var catalog = JsonDocument.Parse(json);
        var entry = catalog.RootElement.GetProperty("entries").EnumerateArray().FirstOrDefault(e => e.GetProperty("path").GetString() == path && e.GetProperty("resource").GetString() != "annotations");
        return entry.ValueKind != JsonValueKind.Undefined && entry.TryGetProperty("fileId", out var id) ? "id:" + id.GetString() : path;
    }
    internal string Mode(string path) {
        lock (Gate) { var values = Read(); while (path.Length > 0) { if (values.TryGetValue(Key(path), out var mode) || values.TryGetValue(path, out mode)) return mode; var index = path.LastIndexOf('/'); path = index < 0 ? "" : path[..index]; } return "sync"; }
    }
    internal void Set(string path, string? mode) {
        if (mode != null && mode is not ("local" or "server" or "sync")) throw new ArgumentException("Invalid storage mode.");
        lock (Gate) {
            var values = Read(); var key = Key(path); values.Remove(path); if (mode == null) values.Remove(key); else values[key] = mode;
            var temporary = Path.Combine(directory, Guid.NewGuid() + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write)) { JsonSerializer.Serialize(stream, values); stream.Flush(true); }
            File.Move(temporary, Path.Combine(directory, "modes.json"), true);
        }
    }
    internal void CacheCatalog(string json) { lock (Gate) { var temporary = Path.Combine(directory, Guid.NewGuid() + ".tmp"); File.WriteAllText(temporary, json); File.Move(temporary, Path.Combine(directory, "catalog.json"), true); } }
    internal string? CachedCatalog() { lock (Gate) { var file = Path.Combine(directory, "catalog.json"); return File.Exists(file) ? File.ReadAllText(file) : null; } }
}

// Bounded session-local editor history; no credentials, disk snapshots or server API.
internal sealed class EditHistory
{
    private readonly List<string> undo = [], redo = [];
    internal bool CanUndo => undo.Count > 0;
    internal bool CanRedo => redo.Count > 0;
    internal void Clear() { undo.Clear(); redo.Clear(); }
    internal void Record(string before) { undo.Add(before); redo.Clear(); Trim(); }
    internal string? Undo(string current) { if (!CanUndo) return null; var value = undo[^1]; undo.RemoveAt(undo.Count - 1); redo.Add(current); Trim(); return value; }
    internal string? Redo(string current) { if (!CanRedo) return null; var value = redo[^1]; redo.RemoveAt(redo.Count - 1); undo.Add(current); Trim(); return value; }
    private void Trim() {
        while (undo.Count + redo.Count > 80 || undo.Concat(redo).Sum(s => (long)Encoding.UTF8.GetByteCount(s)) > 8 * 1024 * 1024)
            if (undo.Count > 0) undo.RemoveAt(0); else if (redo.Count > 0) redo.RemoveAt(0); else break;
    }
}
