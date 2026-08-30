using System.Net.Http.Headers;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace Codmes.Windows;

public partial class MainWindow : Window
{
    private readonly HttpClient http = new();
    private ClientWebSocket? liveSocket;
    private CancellationTokenSource? liveCancellation;
    private string? liveSessionId;
    private string? pendingMessage;
    private TextBlock? transcript;

    public MainWindow() => InitializeComponent();

    private async void Connect_Click(object sender, RoutedEventArgs e) => await LoadPlugins();

    private async Task LoadPlugins()
    {
        try
        {
            using var document = await GetJson("/api/plugins");
            SurfaceContent.Children.Clear();
            foreach (var plugin in document.RootElement.GetProperty("plugins").EnumerateArray())
            {
                if (!SupportsWindowsDesktop(plugin)) continue;
                foreach (var view in plugin.GetProperty("views").EnumerateArray())
                {
                    var pluginId = plugin.GetProperty("id").GetString()!;
                    var title = $"{plugin.GetProperty("name").GetString()} · {view.GetProperty("title").GetString()}";
                    var renderer = view.GetProperty("renderer").GetString();
                    var button = new Button { Content = title, Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(12) };
                    button.Click += async (_, _) =>
                    {
                        if (renderer == "declarative") await LoadSurface(pluginId);
                        else
                        {
                            var viewId = view.GetProperty("id").GetString();
                            if (viewId == "chat") await OpenChat();
                            else if (viewId is "notes" or "code") await OpenFiles(viewId);
                            else ShowMessage($"No native renderer for {title}.");
                        }
                    };
                    SurfaceContent.Children.Add(button);
                }
            }
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task LoadSurface(string pluginId)
    {
        try
        {
            using var document = await GetJson($"/api/plugins/{Uri.EscapeDataString(pluginId)}/view-document");
            var root = document.RootElement;
            SurfaceContent.Children.Clear();
            AddHeading(root.GetProperty("title").GetString() ?? pluginId, 24);
            if (root.TryGetProperty("subtitle", out var subtitle) && subtitle.ValueKind == JsonValueKind.String) AddBodyText(subtitle.GetString());
            if (root.TryGetProperty("items", out var items))
            {
                foreach (var item in items.EnumerateArray())
                {
                    AddHeading(item.GetProperty("title").GetString() ?? "", 17);
                    if (item.TryGetProperty("subtitle", out var itemSubtitle) && itemSubtitle.ValueKind == JsonValueKind.String) AddBodyText(itemSubtitle.GetString());
                    if (item.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String) AddBodyText(body.GetString());
                }
            }
            if (root.TryGetProperty("sections", out var sections))
                foreach (var section in sections.EnumerateArray()) AddHeading(section.GetProperty("title").GetString() ?? "", 17);
            var back = new Button { Content = "Back", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 16, 0, 0) };
            back.Click += async (_, _) => await LoadPlugins();
            SurfaceContent.Children.Add(back);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenFiles(string rootName)
    {
        try
        {
            using var document = await GetJson($"/api/tree?root={rootName}&recursive=true");
            SurfaceContent.Children.Clear();
            AddHeading(char.ToUpperInvariant(rootName[0]) + rootName[1..], 24);
            foreach (var item in document.RootElement.GetProperty("children").EnumerateArray())
            {
                if (item.GetProperty("isDirectory").GetBoolean()) continue;
                var path = item.GetProperty("path").GetString()!;
                var button = new Button { Content = path, Margin = new Thickness(0, 0, 0, 6), Padding = new Thickness(10) };
                button.Click += async (_, _) => await OpenFile(path, rootName);
                SurfaceContent.Children.Add(button);
            }
            AddBackButton(LoadPlugins);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenFile(string path, string rootName)
    {
        try
        {
            using var document = await GetJson($"/api/file?path={Uri.EscapeDataString(path)}");
            SurfaceContent.Children.Clear();
            AddHeading(document.RootElement.GetProperty("name").GetString() ?? path, 22);
            var editor = new TextBox {
                Text = document.RootElement.GetProperty("content").GetString() ?? "",
                AcceptsReturn = true,
                AcceptsTab = true,
                MinHeight = 400,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
            };
            SurfaceContent.Children.Add(editor);
            var save = new Button { Content = "Save", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 10, 0, 6) };
            save.Click += async (_, _) =>
            {
                await SendJson(HttpMethod.Put, $"/api/file?path={Uri.EscapeDataString(path)}", new { content = editor.Text });
                AddBodyText($"Saved {path}");
            };
            SurfaceContent.Children.Add(save);
            AddBackButton(() => OpenFiles(rootName));
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenChat()
    {
        await DisconnectChat();
        SurfaceContent.Children.Clear();
        AddHeading("Chat", 24);
        transcript = new TextBlock { Text = "Connecting…", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        SurfaceContent.Children.Add(transcript);
        var composer = new TextBox { MinHeight = 70, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        SurfaceContent.Children.Add(composer);
        var send = new Button { Content = "Send", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 8, 0, 6) };
        send.Click += async (_, _) =>
        {
            var message = composer.Text.Trim();
            if (message.Length == 0) return;
            AppendChat($"You: {message}");
            composer.Clear();
            await SubmitChat(message);
        };
        SurfaceContent.Children.Add(send);
        AddBackButton(async () => { await DisconnectChat(); await LoadPlugins(); });

        liveCancellation = new CancellationTokenSource();
        liveSocket = new ClientWebSocket();
        var token = Token.Text.Trim();
        var baseUri = new Uri(Server.Text.TrimEnd('/'));
        var scheme = baseUri.Scheme == "https" ? "wss" : "ws";
        var uri = new UriBuilder(baseUri) { Scheme = scheme, Path = "/api/live", Query = token.Length > 0 ? $"token={Uri.EscapeDataString(token)}" : "" }.Uri;
        await liveSocket.ConnectAsync(uri, liveCancellation.Token);
        _ = ReceiveChat(liveCancellation.Token);
        await SendLive("connect", "connect", new { });
    }

    private async Task ReceiveChat(CancellationToken cancellation)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (liveSocket?.State == WebSocketState.Open && !cancellation.IsCancellationRequested)
            {
                var segment = new ArraySegment<byte>(buffer);
                var result = await liveSocket.ReceiveAsync(segment, cancellation);
                if (result.MessageType == WebSocketMessageType.Close) break;
                var json = JsonDocument.Parse(Encoding.UTF8.GetString(buffer, 0, result.Count));
                var root = json.RootElement;
                var kind = root.TryGetProperty("kind", out var kindValue) ? kindValue.GetString() : "";
                var id = root.TryGetProperty("id", out var idValue) ? idValue.GetString() : "";
                if (kind == "result" && id == "connect") await SendLive("create", "session.create", new { accessMode = "confirm", surface = "chat" });
                else if (kind == "result" && id == "create")
                {
                    liveSessionId = root.GetProperty("result").GetProperty("sessionId").GetString();
                    await Dispatcher.InvokeAsync(() => AppendChat("Connected"));
                    if (pendingMessage is { } queued) { pendingMessage = null; await SubmitChat(queued); }
                }
                else if (kind is "runtime.event" or "hermes.event")
                {
                    var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() ?? "" : "";
                    var text = root.TryGetProperty("text", out var textValue) ? textValue.GetString() ?? "" : "";
                    if (text.Length > 0 && (type.Contains("delta") || type.Contains("message")))
                        await Dispatcher.InvokeAsync(() => AppendChat($"Codmes: {text}"));
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { await Dispatcher.InvokeAsync(() => AppendChat($"Connection failed: {error.Message}")); }
    }

    private async Task SubmitChat(string message)
    {
        if (liveSessionId is null) { pendingMessage = message; return; }
        await SendLive($"prompt-{Guid.NewGuid()}", "prompt.submit", new { sessionId = liveSessionId, message, surface = "chat" });
    }

    private async Task SendLive(string id, string command, object parameters)
    {
        if (liveSocket?.State != WebSocketState.Open) return;
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { id, command, @params = parameters }));
        await liveSocket.SendAsync(bytes, WebSocketMessageType.Text, true, liveCancellation?.Token ?? CancellationToken.None);
    }

    private async Task DisconnectChat()
    {
        liveCancellation?.Cancel();
        if (liveSocket?.State == WebSocketState.Open)
            await liveSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "leaving chat", CancellationToken.None);
        liveSocket?.Dispose();
        liveSocket = null;
        liveCancellation?.Dispose();
        liveCancellation = null;
        liveSessionId = null;
        transcript = null;
    }

    private async Task SendJson(HttpMethod method, string path, object body)
    {
        var request = new HttpRequestMessage(method, Server.Text.TrimEnd('/') + path) {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json")
        };
        var token = Token.Text.Trim();
        if (token.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request);
        response.EnsureSuccessStatusCode();
    }

    private async Task<JsonDocument> GetJson(string path)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, Server.Text.TrimEnd('/') + path);
        var token = Token.Text.Trim();
        if (token.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await response.Content.ReadAsStreamAsync());
    }

    private static bool SupportsWindowsDesktop(JsonElement plugin)
    {
        var platforms = Strings(plugin, "platforms").Select(value => value == "ipados" ? "ios" : value).ToArray();
        var factors = Strings(plugin, "formFactors").ToArray();
        if (factors.Length == 0)
        {
            var legacy = Strings(plugin, "platforms").ToHashSet();
            factors = new[] { legacy.Contains("macos") ? "desktop" : "", legacy.Contains("ios") ? "phone" : "", legacy.Contains("ipados") ? "tablet" : "" }
                .Where(value => value.Length > 0).ToArray();
        }
        return (platforms.Length == 0 || platforms.Contains("windows"))
            && (factors.Length == 0 || factors.Contains("desktop"));
    }

    private static IEnumerable<string> Strings(JsonElement value, string name) =>
        value.TryGetProperty(name, out var array) && array.ValueKind == JsonValueKind.Array
            ? array.EnumerateArray().Select(item => (item.GetString() ?? "").ToLowerInvariant())
            : [];

    private void AddBackButton(Func<Task> action)
    {
        var back = new Button { Content = "Back", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 16, 0, 0) };
        back.Click += async (_, _) => await action();
        SurfaceContent.Children.Add(back);
    }
    private void AppendChat(string value) { if (transcript is not null) transcript.Text += $"\n{value}"; }
    private void ShowMessage(string message) { SurfaceContent.Children.Clear(); AddBodyText(message); }
    private void AddHeading(string value, double size) => SurfaceContent.Children.Add(new TextBlock { Text = value, FontSize = size, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 5), TextWrapping = TextWrapping.Wrap });
    private void AddBodyText(string? value) { if (!string.IsNullOrWhiteSpace(value)) SurfaceContent.Children.Add(new TextBlock { Text = value, Margin = new Thickness(0, 0, 0, 7), TextWrapping = TextWrapping.Wrap }); }

    protected override async void OnClosed(EventArgs e) { await DisconnectChat(); base.OnClosed(e); }
}
