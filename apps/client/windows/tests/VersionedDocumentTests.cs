using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace Codmes.Windows;

public class VersionedDocumentTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public string Storage { get; } = Path.Combine(Path.GetTempPath(), "codmes-csharp-wire-" + Guid.NewGuid());
        public HttpClient Http { get; } = new();
        public string Url { get; private set; } = "";
        private Process? process;
        public static async Task<Fixture> Start([CallerFilePath] string source = "")
        {
            var fixture = new Fixture();
            var root = new DirectoryInfo(Path.GetDirectoryName(source)!);
            while (!File.Exists(Path.Combine(root.FullName, "server/lib/test-support/versioned-http-fixture.mjs")))
                root = root.Parent ?? throw new IOException("Repository HTTP fixture not found.");
            var script = Path.Combine(root.FullName, "server/lib/test-support/versioned-http-fixture.mjs");
            fixture.process = Process.Start(new ProcessStartInfo("node", script) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false })!;
            var line = await fixture.process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15));
            fixture.Url = JsonDocument.Parse(line ?? throw new IOException("Fixture did not start.")).RootElement.GetProperty("url").GetString()!;
            return fixture;
        }
        public VersionedDocument Document(string device, string resource = "file", string profile = "a", string? storage = null) => new(Http, Url, "test-profile-" + profile, profile, resource == "file" ? "Notes/book.md" : "Notes/book.pdf", resource, device, storage ?? Path.Combine(Storage, device));
        public async ValueTask DisposeAsync()
        {
            try { using var request = new HttpRequestMessage(HttpMethod.Post, Url + "/fixture/stop"); request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "test-profile-a"); await Http.SendAsync(request); } catch { }
            if (process != null) { if (!process.HasExited) await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); process.Dispose(); }
            Http.Dispose(); if (Directory.Exists(Storage)) Directory.Delete(Storage, true);
        }
        public async Task DropNext()
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Url + "/fixture/drop-next"); request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "test-profile-a"); await Http.SendAsync(request);
        }
    }
    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);
    private static long Time(int n) => new DateTimeOffset(2026, 1, 1, 0, 0, n, TimeSpan.Zero).ToUnixTimeMilliseconds();

    [Fact]
    public async Task SelectiveModesKeepLocalChangesAndServerModeDoesNotRetainPayload()
    {
        await using var f = await Fixture.Start();
        var phone = f.Document("phone"); await phone.OpenAsync(); phone.Save(Bytes("same book")); await phone.FlushAsync();
        var mac = f.Document("mac"); mac.StoragePolicies.Set("Notes", "server");
        Assert.Equal("same book", Encoding.UTF8.GetString(await mac.OpenAsync()));
        Assert.Empty(mac.LocalContent);
        mac.StoragePolicies.Set("Notes/book.md", "sync"); await mac.OpenAsync();
        mac.StoragePolicies.Set("Notes/book.md", "local"); mac.Save(Bytes("private edit")); await mac.FlushAsync();
        Assert.Equal(1, mac.PendingCount);
        Assert.Equal("same book", Encoding.UTF8.GetString(await phone.OpenAsync()));
        Assert.Equal("private edit", Encoding.UTF8.GetString(await mac.OpenAsync()));
        mac.StoragePolicies.Set("Notes/book.md", null); Assert.Equal("server", mac.StorageMode);
    }
    [Fact]
    public async Task IndependentSameContentAdoptsIdentityButDifferentContentRequiresChoice()
    {
        await using var f = await Fixture.Start(); var phone = f.Document("phone"); var mac = f.Document("mac"); var tablet = f.Document("tablet");
        phone.Save(Bytes("book")); mac.Save(Bytes("book")); tablet.Save(Bytes("different book"));
        await phone.FlushAsync(); await mac.FlushAsync(); Assert.Equal(0, mac.PendingCount);
        await Assert.ThrowsAsync<FirstRegistrationConflict>(() => tablet.FlushAsync());
        Assert.Equal("different book", Encoding.UTF8.GetString(tablet.LocalContent));
        await tablet.ResolveFirstConflictAsync(false); await tablet.FlushAsync();
        Assert.Equal("different book", Encoding.UTF8.GetString(await phone.OpenAsync()));
    }

    [Fact]
    public async Task IdenticalReadsAreDeduplicatedAndCleanupProtectsPendingEdits()
    {
        await using var f = await Fixture.Start();
        var storage = Path.Combine(f.Storage, "bounded"); var local = f.Document("Windows", storage: storage);
        await local.OpenAsync();
        for (var n = 0; n < 20; n++) local.Save(Bytes("offline " + n), Time(n));
        var restarted = f.Document("Windows", storage: storage);
        Assert.Equal(20, restarted.PendingCount);
        Assert.Equal(20, Directory.GetFiles(storage, "*.blob", SearchOption.AllDirectories).Length);
        await restarted.FlushAsync();
        for (var n = 0; n < 20; n++) { await restarted.OpenAsync(); restarted.Save(Bytes("offline 19")); }
        Assert.Single(Directory.GetFiles(storage, "*.blob", SearchOption.AllDirectories));
        Assert.Equal(0, restarted.PendingCount);
    }
    [Fact]
    public void EditorUndoRedoIsBoundedAndNewEditsClearRedo()
    {
        var history = new EditHistory(); history.Record("base");
        Assert.Equal("base", history.Undo("edited")); Assert.Equal("edited", history.Redo("base"));
        history.Undo("edited"); history.Record("base"); Assert.False(history.CanRedo);
        history.Clear(); for (var n = 0; n < 200; n++) history.Record(n.ToString());
        var count = 0; while (history.Undo("current") != null) count++; Assert.Equal(80, count);
        history.Clear(); history.Record(new string('x', 9 * 1024 * 1024)); Assert.False(history.CanUndo);
    }
    [Fact]
    public void PdfMetadataRefreshPreservesUndoButRemoteContentInvalidatesIt()
    {
        var a = JsonNode.Parse("{\"pages\":[{\"pageIndex\":0,\"objects\":[]}],\"objects\":[]}")!.AsObject();
        var b = a.DeepClone().AsObject(); VersionedDocument.EnsurePageIds(b); b["updatedAt"] = "new"; b["documentPath"] = "Notes/book.pdf";
        Assert.True(VersionedDocument.AnnotationContentEqual(a, b));
        b["pages"]![0]!["objects"]!.AsArray().Add(new JsonObject { ["id"] = "remote", ["text"] = "changed" });
        Assert.False(VersionedDocument.AnnotationContentEqual(a, b));
    }

    [Fact]
    public async Task NativeCSharpHeadersMergeByLocalTimeNotArrivalAndPreserveWords()
    {
        await using var f = await Fixture.Start();
        var seed = f.Document("seed"); await seed.OpenAsync(); seed.Save(Bytes("red cat\n"), Time(0)); await seed.FlushAsync();
        var windows = f.Document("Windows"); var android = f.Document("Android");
        await windows.OpenAsync(); await android.OpenAsync();
        windows.Save(Bytes("blue cat\n"), Time(10)); android.Save(Bytes("red dog\n"), Time(20));
        await android.FlushAsync(); await windows.FlushAsync();
        Assert.Equal("blue dog\n", Encoding.UTF8.GetString(await windows.OpenAsync()));
        Assert.Equal("blue dog\n", Encoding.UTF8.GetString(await android.OpenAsync()));
        Assert.Equal(0, windows.PendingCount);
    }
    [Fact]
    public async Task ResponseLossAndRestartRetainEveryOriginalSnapshotAndOperationId()
    {
        await using var f = await Fixture.Start();
        var storage = Path.Combine(f.Storage, "restart");
        var local = f.Document("Windows", storage: storage); await local.OpenAsync();
        local.Save(Bytes("first\n"), Time(0));
        await f.DropNext(); await Assert.ThrowsAnyAsync<Exception>(() => local.FlushAsync());
        Assert.Equal(1, local.PendingCount);
        local.Save(Bytes("second\n"), Time(10));
        var reopened = f.Document("Windows", storage: storage);
        Assert.Equal(2, reopened.PendingCount); Assert.Equal("second\n", Encoding.UTF8.GetString(reopened.LocalContent));
        await reopened.FlushAsync(); Assert.Equal(0, reopened.PendingCount);
        Assert.Equal("second\n", Encoding.UTF8.GetString(await reopened.OpenAsync()));
        var json = string.Join("", Directory.GetFiles(storage, "journal.json", SearchOption.AllDirectories).Select(File.ReadAllText));
        Assert.DoesNotContain("test-profile-a", json); Assert.DoesNotContain("Bearer", json);
    }
    [Fact]
    public async Task AnnotationPropertiesAndStrokesInteroperateWithTheServer()
    {
        await using var f = await Fixture.Start();
        using var request = new HttpRequestMessage(HttpMethod.Put, f.Url + "/api/sync/blob?path=Notes%2Fbook.pdf&resource=file") { Content = new ByteArrayContent(Bytes("%PDF fixture")) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "test-profile-a"); request.Headers.Add("X-Codmes-Base-Revision", "missing");
        (await f.Http.SendAsync(request)).EnsureSuccessStatusCode();
        var seed = f.Document("seed", "annotations"); await seed.OpenAsync();
        var doc = JsonNode.Parse("{\"schemaVersion\":2,\"pages\":[{\"pageIndex\":0,\"objects\":[{\"id\":\"box\",\"text\":\"base\",\"bbox\":{\"x\":0.1,\"y\":0.2}}],\"inkStrokes\":[]}],\"objects\":[]}")!.AsObject();
        VersionedDocument.EnsurePageIds(doc); seed.Save(Bytes(doc.ToJsonString()), Time(0)); await seed.FlushAsync();
        Assert.True(VersionedDocument.AnnotationContentEqual(doc, JsonNode.Parse(await seed.OpenAsync())!.AsObject()));
        var pen = f.Document("Android", "annotations"); var text = f.Document("Windows", "annotations");
        var a = JsonNode.Parse(await pen.OpenAsync())!; var b = JsonNode.Parse(await text.OpenAsync())!;
        a["pages"]![0]!["objects"]![0]!["bbox"]!["x"] = 0.8;
        a["pages"]![0]!["inkStrokes"]!.AsArray().Add(new JsonObject { ["id"] = "pen-stroke", ["points"] = new JsonArray(new JsonObject { ["x"] = .1, ["y"] = .2, ["pressure"] = .5 }) });
        b["pages"]![0]!["objects"]![0]!["text"] = "latest";
        pen.Save(Bytes(a.ToJsonString()), Time(10)); text.Save(Bytes(b.ToJsonString()), Time(20));
        await text.FlushAsync(); await pen.FlushAsync();
        var result = JsonNode.Parse(await pen.OpenAsync())!;
        Assert.Equal(.8, result["pages"]![0]!["objects"]![0]!["bbox"]!["x"]!.GetValue<double>());
        Assert.Equal("latest", result["pages"]![0]!["objects"]![0]!["text"]!.GetValue<string>());
        Assert.Equal("pen-stroke", result["pages"]![0]!["inkStrokes"]![0]!["id"]!.GetValue<string>());
    }
    [Fact]
    public async Task DifferentAccountsUseSeparateLocalJournalsAndServerHistory()
    {
        await using var f = await Fixture.Start();
        var a = f.Document("Windows", profile: "a", storage: f.Storage); var b = f.Document("Windows", profile: "b", storage: f.Storage);
        await a.OpenAsync(); a.Save(Bytes("private A"), Time(0)); await a.FlushAsync();
        Assert.Empty(await b.OpenAsync()); Assert.Empty(b.LocalContent);
    }
    [Fact]
    public async Task EditorDebounceKeepsOriginalBaseWhileRemoteContentChanges()
    {
        await using var f = await Fixture.Start();
        var local = f.Document("Windows"); await local.OpenAsync(); local.Save(Bytes("red cat\n"), Time(0)); await local.FlushAsync(); await local.OpenAsync();
        var remote = f.Document("Android"); await remote.OpenAsync(); remote.Save(Bytes("red dog\n"), Time(10)); await remote.FlushAsync();
        local.PinDraft(); Assert.Equal("red cat\n", Encoding.UTF8.GetString(await local.OpenAsync()));
        local.Save(Bytes("blue cat\n"), Time(20)); await local.FlushAsync();
        Assert.Equal("blue dog\n", Encoding.UTF8.GetString(await local.OpenAsync()));
    }
}
