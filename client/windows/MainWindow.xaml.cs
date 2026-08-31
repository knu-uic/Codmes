using System.Net.Http.Headers;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
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
            var approvals = new Button { Content = "Pending approvals", Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(12) };
            approvals.Click += async (_, _) => await OpenApprovals();
            SurfaceContent.Children.Add(approvals);
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

    private async Task OpenApprovals()
    {
        try
        {
            using var document = await GetJson("/api/agent/approvals?status=pending&limit=50");
            SurfaceContent.Children.Clear();
            AddHeading("Pending approvals", 24);
            var approvals = document.RootElement.GetProperty("approvals");
            if (approvals.GetArrayLength() == 0) AddBodyText("No pending approvals.");
            foreach (var approval in approvals.EnumerateArray())
            {
                var id = approval.GetProperty("id").GetString()!;
                var label = approval.TryGetProperty("summary", out var summary) && summary.ValueKind == JsonValueKind.String
                    ? summary.GetString()
                    : approval.GetProperty("category").GetString();
                var button = new Button { Content = label ?? "Approval", Margin = new Thickness(0, 0, 0, 6), Padding = new Thickness(10) };
                button.Click += async (_, _) => await OpenApproval(id);
                SurfaceContent.Children.Add(button);
            }
            AddBackButton(LoadPlugins);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenApproval(string id)
    {
        try
        {
            using var document = await GetJson($"/api/agent/approvals/{Uri.EscapeDataString(id)}");
            var approval = document.RootElement.Clone();
            string? diffText = null;
            if (approval.TryGetProperty("diffRef", out var diffRef) && diffRef.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(diffRef.GetString()))
            {
                using var diff = await GetJson($"/api/file?path={Uri.EscapeDataString(diffRef.GetString()!)}");
                diffText = diff.RootElement.TryGetProperty("content", out var content) ? content.GetString() : null;
            }
            RenderApproval(approval, diffText);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private void RenderApproval(JsonElement approval, string? diffText)
    {
        SurfaceContent.Children.Clear();
        var summary = approval.TryGetProperty("summary", out var summaryValue) ? summaryValue.GetString() : "Approval";
        var category = approval.TryGetProperty("category", out var categoryValue) ? categoryValue.GetString() ?? "approval" : "approval";
        AddHeading(summary ?? "Approval", 22);
        AddBodyText(category);
        if (approval.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String) AddBodyText(reason.GetString());
        if (!string.IsNullOrWhiteSpace(diffText))
        {
            AddHeading("Proposed diff", 17);
            SurfaceContent.Children.Add(new TextBox {
                Text = diffText,
                IsReadOnly = true,
                AcceptsReturn = true,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                MinHeight = 280
            });
        }
        var runChecks = new CheckBox {
            Content = "Run checks after applying patch",
            Visibility = category == "code.patch.apply" ? Visibility.Visible : Visibility.Collapsed,
            Margin = new Thickness(0, 12, 0, 8)
        };
        SurfaceContent.Children.Add(runChecks);
        var id = approval.GetProperty("id").GetString()!;
        var approve = new Button { Content = "Approve & execute", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 0, 0, 6) };
        approve.Click += async (_, _) =>
        {
            var checks = runChecks.IsChecked == true;
            await SendJson(HttpMethod.Post, $"/api/agent/approvals/{Uri.EscapeDataString(id)}/respond", new { approved = true, runChecksAfterApply = checks, checksApproved = checks });
            await OpenApprovals();
        };
        SurfaceContent.Children.Add(approve);
        var reject = new Button { Content = "Reject", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 0, 0, 6) };
        reject.Click += async (_, _) =>
        {
            await SendJson(HttpMethod.Post, $"/api/agent/approvals/{Uri.EscapeDataString(id)}/respond", new { approved = false, reason = "Rejected in Windows client." });
            await OpenApprovals();
        };
        SurfaceContent.Children.Add(reject);
        AddBackButton(OpenApprovals);
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
            var usesCards = root.TryGetProperty("collectionStyle", out var collectionStyle)
                && collectionStyle.ValueKind == JsonValueKind.String
                && collectionStyle.GetString() == "cards";
            if (root.TryGetProperty("items", out var items))
            {
                foreach (var item in items.EnumerateArray())
                {
                    if (usesCards) AddSurfaceCard(item);
                    else
                    {
                        AddHeading(item.GetProperty("title").GetString() ?? "", 17);
                        if (item.TryGetProperty("subtitle", out var itemSubtitle) && itemSubtitle.ValueKind == JsonValueKind.String) AddBodyText(itemSubtitle.GetString());
                        if (item.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String) AddBodyText(body.GetString());
                    }
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
                button.Click += async (_, _) =>
                {
                    if (path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) await OpenPdf(path, rootName);
                    else await OpenFile(path, rootName);
                };
                SurfaceContent.Children.Add(button);
            }
            AddBackButton(LoadPlugins);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenPdf(string path, string rootName)
    {
        try
        {
            using var metadata = await GetJson($"/api/pdf/metadata?path={Uri.EscapeDataString(path)}");
            using var annotationJson = await GetJson($"/api/file/annotations?path={Uri.EscapeDataString(path)}");
            var annotations = JsonNode.Parse(annotationJson.RootElement.GetRawText())!.AsObject();
            var pageCount = Math.Max(1, metadata.RootElement.GetProperty("pageCount").GetInt32());
            var pageIndex = 0;
            SurfaceContent.Children.Clear();
            var heading = new TextBlock { FontSize = 22, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 8) };
            var viewer = new PdfAnnotationCanvas { Height = 620, MinWidth = 500 };
            async Task LoadPage()
            {
                heading.Text = $"{System.IO.Path.GetFileName(path)} · {pageIndex + 1}/{pageCount}";
                var bytes = await GetBytes($"/api/pdf-thumbnail?path={Uri.EscapeDataString(path)}&page={pageIndex + 1}&scale=2");
                viewer.SetPage(bytes, annotations, pageIndex);
            }
            viewer.TextRequested = (x, y) =>
            {
                var value = PromptForText();
                if (!string.IsNullOrWhiteSpace(value)) viewer.AddText(x, y, value);
            };
            SurfaceContent.Children.Add(heading);
            SurfaceContent.Children.Add(viewer);
            var tools = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 8) };
            foreach (var entry in new[] {
                ("Pen", PdfAnnotationCanvas.AnnotationTool.Pen),
                ("Rectangle", PdfAnnotationCanvas.AnnotationTool.Rectangle),
                ("Text", PdfAnnotationCanvas.AnnotationTool.Text)
            })
            {
                var button = new Button { Content = entry.Item1, Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 6, 0) };
                button.Click += (_, _) => viewer.Tool = entry.Item2;
                tools.Children.Add(button);
            }
            SurfaceContent.Children.Add(tools);
            var navigation = new StackPanel { Orientation = Orientation.Horizontal };
            var previous = new Button { Content = "Previous", Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 6, 0) };
            previous.Click += async (_, _) => { if (pageIndex > 0) { pageIndex--; await LoadPage(); } };
            var next = new Button { Content = "Next", Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 6, 0) };
            next.Click += async (_, _) => { if (pageIndex + 1 < pageCount) { pageIndex++; await LoadPage(); } };
            var save = new Button { Content = "Save annotations", Padding = new Thickness(12, 6, 12, 6) };
            save.Click += async (_, _) =>
            {
                await SendJson(HttpMethod.Put, $"/api/file/annotations?path={Uri.EscapeDataString(path)}", viewer.Document);
                MessageBox.Show(this, "Annotations saved.", "Codmes");
            };
            navigation.Children.Add(previous);
            navigation.Children.Add(next);
            navigation.Children.Add(save);
            SurfaceContent.Children.Add(navigation);
            AddBackButton(() => OpenFiles(rootName));
            await LoadPage();
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private string? PromptForText()
    {
        var dialog = new Window { Title = "Add text", Width = 420, Height = 160, Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var panel = new StackPanel { Margin = new Thickness(14) };
        var input = new TextBox { MinHeight = 34 };
        var add = new Button { Content = "Add", IsDefault = true, Padding = new Thickness(12, 6, 12, 6), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        add.Click += (_, _) => dialog.DialogResult = true;
        panel.Children.Add(input);
        panel.Children.Add(add);
        dialog.Content = panel;
        return dialog.ShowDialog() == true ? input.Text : null;
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

    private async Task<byte[]> GetBytes(string path)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, Server.Text.TrimEnd('/') + path);
        var token = Token.Text.Trim();
        if (token.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync();
    }

    private static bool SupportsWindowsDesktop(JsonElement plugin)
    {
        return ClientCompatibility.Supports(
            Strings(plugin, "platforms"),
            Strings(plugin, "formFactors"),
            "windows",
            "desktop"
        );
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
    private void AddSurfaceCard(JsonElement item)
    {
        var panel = new StackPanel();
        if (item.TryGetProperty("eyebrow", out var eyebrow) && eyebrow.ValueKind == JsonValueKind.String)
        {
            var symbol = item.TryGetProperty("systemImage", out var image) && image.ValueKind == JsonValueKind.String
                ? SurfaceSymbol(image.GetString())
                : "";
            panel.Children.Add(new TextBlock {
                Text = $"{symbol}{eyebrow.GetString()}",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = System.Windows.Media.Brushes.RoyalBlue,
                Margin = new Thickness(0, 0, 0, 5)
            });
        }
        if (item.TryGetProperty("badge", out var badge) && badge.ValueKind == JsonValueKind.String)
        {
            var tone = item.TryGetProperty("badgeTone", out var badgeTone) && badgeTone.ValueKind == JsonValueKind.String
                ? badgeTone.GetString()
                : null;
            panel.Children.Add(new TextBlock {
                Text = badge.GetString(),
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                Foreground = SurfaceTone(tone),
                Margin = new Thickness(0, 0, 0, 4)
            });
        }
        if (item.TryGetProperty("meta", out var meta) && meta.ValueKind == JsonValueKind.String)
            panel.Children.Add(new TextBlock { Text = meta.GetString(), FontSize = 11, Opacity = .65, Margin = new Thickness(0, 0, 0, 5) });
        panel.Children.Add(new TextBlock { Text = item.GetProperty("title").GetString() ?? "", FontSize = 17, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (item.TryGetProperty("subtitle", out var subtitle) && subtitle.ValueKind == JsonValueKind.String)
            panel.Children.Add(new TextBlock { Text = subtitle.GetString(), Margin = new Thickness(0, 5, 0, 0), TextWrapping = TextWrapping.Wrap });
        if (item.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String)
            panel.Children.Add(new TextBlock { Text = body.GetString(), Margin = new Thickness(0, 5, 0, 0), TextWrapping = TextWrapping.Wrap });
        SurfaceContent.Children.Add(new Border {
            Child = panel,
            Padding = new Thickness(16, 14, 16, 14),
            Margin = new Thickness(0, 6, 0, 6),
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            BorderBrush = System.Windows.Media.Brushes.LightGray,
            Background = System.Windows.Media.Brushes.White
        });
    }
    private static System.Windows.Media.Brush SurfaceTone(string? tone) => tone switch {
        "danger" => System.Windows.Media.Brushes.Firebrick,
        "warning" => System.Windows.Media.Brushes.DarkOrange,
        "success" => System.Windows.Media.Brushes.ForestGreen,
        "neutral" => System.Windows.Media.Brushes.DimGray,
        _ => System.Windows.Media.Brushes.RoyalBlue
    };
    private static string SurfaceSymbol(string? value) => value switch {
        "bell" => "🔔 ",
        "calendar" => "📅 ",
        "checkmark.circle" => "✓ ",
        _ => ""
    };

    protected override async void OnClosed(EventArgs e) { await DisconnectChat(); base.OnClosed(e); }
}
