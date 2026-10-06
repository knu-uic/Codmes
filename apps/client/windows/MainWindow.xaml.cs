using System.Net.Http.Headers;
using System.IO;
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
    private string accountToken = "";
    private string accountServerUrl = "";
    private string activeProfileId = "";
    private string activeProfileName = "";
    private string googleDesktopClientId = "";
    private bool googleSignInBusy;
    private string googleAccountLabel = "";
    private string setupGoogleToken = "";
    private string setupGoogleServer = "";
    private DateTime setupGoogleCreated;
    private bool accountActionBusy;
    private JsonElement accountIdentity;
    private readonly DeviceAppLock appLock = new();
    private Action? flushLocalEditor;
    private Func<Task>? syncCurrentEditor;
    private bool editorSyncRunning;
    private bool localEditorSaveFailed;
    private readonly Dictionary<string, VersionedDocument> documents = [];

    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => LockApp();
        Deactivated += (_, _) => { flushLocalEditor?.Invoke(); if (!googleSignInBusy) LockApp(); };
        Closing += (_, _) => flushLocalEditor?.Invoke();
        var reconnect = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        reconnect.Tick += async (_, _) => {
            if (editorSyncRunning || syncCurrentEditor == null || !IsActive) return;
            editorSyncRunning = true;
            try { await syncCurrentEditor(); } finally { editorSyncRunning = false; }
        };
        reconnect.Start();
        Closed += (_, _) => reconnect.Stop();
    }

    private void LockApp()
    {
        if (!appLock.Enabled) return;
        WorkspacePanel.Visibility = Visibility.Hidden;
        LockCurtain.Visibility = Visibility.Visible;
        UnlockPin.Clear();
        LockError.Text = "";
    }

    private void Unlock_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            appLock.Authorize(UnlockPin.Password);
            LockCurtain.Visibility = Visibility.Collapsed;
            WorkspacePanel.Visibility = Visibility.Visible;
        }
        catch (Exception error) { LockError.Text = error.Message; }
        finally { UnlockPin.Clear(); }
    }

    private void AddAppLockSettings()
    {
        AddHeading("App lock (optional)", 20);
        AddBodyText("This device only. Locks on launch and when leaving the app. Not a server credential or file encryption.");
        var current = new PasswordBox { Padding = new Thickness(8) };
        if (appLock.Enabled) { AddBodyText("Current PIN"); SurfaceContent.Children.Add(current); }
        var pin = new PasswordBox { Padding = new Thickness(8) };
        var confirmation = new PasswordBox { Padding = new Thickness(8) };
        AddBodyText("New PIN (four digits)"); SurfaceContent.Children.Add(pin);
        AddBodyText("Confirm PIN"); SurfaceContent.Children.Add(confirmation);
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var save = new Button { Content = appLock.Enabled ? "Change app lock PIN" : "Enable app lock", Padding = new Thickness(12) };
        save.Click += async (_, _) =>
        {
            try { appLock.Set(current.Password, pin.Password, confirmation.Password); await ShowProfileSettings(); }
            catch (Exception error) { status.Text = error.Message; }
            finally { current.Clear(); pin.Clear(); confirmation.Clear(); }
        };
        SurfaceContent.Children.Add(save);
        if (appLock.Enabled)
        {
            var disable = new Button { Content = "Disable app lock", Padding = new Thickness(12) };
            disable.Click += async (_, _) =>
            {
                try { appLock.Disable(current.Password); await ShowProfileSettings(); }
                catch (Exception error) { status.Text = error.Message; }
                finally { current.Clear(); }
            };
            SurfaceContent.Children.Add(disable);
            var lockNow = new Button { Content = "Lock now", Padding = new Thickness(12) };
            lockNow.Click += (_, _) => LockApp();
            SurfaceContent.Children.Add(lockNow);
        }
        SurfaceContent.Children.Add(status);
    }

    private async void Connect_Click(object sender, RoutedEventArgs e) => await ShowServerLogin();

    private async Task ShowServerLogin()
    {
        if (!FlushEditor()) return;
        await DisconnectChat();
        activeProfileId = "";
        activeProfileName = "";
        Token.Text = "";
        if (accountServerUrl != Server.Text.TrimEnd('/')) accountToken = "";
        if (accountToken.Length > 0) { await ShowProfiles(); return; }
        try
        {
            using var status = await AccountJson(HttpMethod.Get, "/api/google-auth/config");
            var setup = status.RootElement.GetProperty("bootstrapRequired").GetBoolean();
            googleDesktopClientId = status.RootElement.GetProperty("clientIds").GetProperty("desktop").GetString() ?? "";
            if (!ClearSurface()) return;
            AddHeading("Sign in to Codmes", 24);
            if (setup)
            {
                SurfaceContent.Children.Add(new TextBlock { Text = "Set up the first administrator in Codmes Server Manager on the server computer, then connect again.", TextWrapping = TextWrapping.Wrap });
                return;
            }
            AddCodmesLoginFields(false);
            if (status.RootElement.GetProperty("enabled").GetBoolean() && googleDesktopClientId.Length > 0)
            {
                var google = new Button { Content = "Continue with Google", Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8) };
                google.Click += async (_, _) => await SignInWithGoogle();
                SurfaceContent.Children.Add(google);
            }
            else
            {
                SurfaceContent.Children.Add(new TextBlock { Text = "Google sign-in is not configured on this server yet.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
            }
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task SignInWithGoogle()
    {
        if (googleSignInBusy) return;
        googleSignInBusy = true;
        try
        {
            var serverUrl = Server.Text.TrimEnd('/');
            var serverUri = new Uri(serverUrl);
            if (serverUri.Scheme != Uri.UriSchemeHttps && !serverUri.IsLoopback)
                throw new InvalidOperationException("Google sign-in requires HTTPS for a remote Codmes server.");
            var idToken = await GoogleDesktopSignIn.GetIdTokenAsync(googleDesktopClientId);
            if (Server.Text.TrimEnd('/') != serverUrl) return;
            using var result = await AccountJson(HttpMethod.Post,
                "/api/google-auth/client/login",
                new { idToken, deviceId = ClientDeviceIdentity.LoadOrCreate(serverUrl), deviceName = Environment.MachineName }, serverUrl);
            if (Server.Text.TrimEnd('/') != serverUrl) return;
            if (result.RootElement.GetProperty("status").GetString() == "account_setup_required") { setupGoogleToken = idToken; setupGoogleServer = serverUrl; setupGoogleCreated = DateTime.UtcNow; }
            await HandleGoogleLoginResult(result.RootElement);
        }
        catch (Exception error) { ShowMessage(error.Message); }
        finally { googleSignInBusy = false; }
    }

    private async Task HandleGoogleLoginResult(JsonElement result, string? pendingRequestId = null, string? pendingRequestToken = null)
    {
        var status = result.GetProperty("status").GetString();
        if (status == "account_setup_required") { if (!ClearSurface()) return; AddHeading("Set up your Codmes account", 24); AddBodyText("Choose an ID and password once. Existing profiles and data are preserved."); AddCodmesLoginFields(true, true); return; }
        if (status == "approved")
        {
            accountToken = result.GetProperty("token").GetString() ?? "";
            accountServerUrl = Server.Text.TrimEnd('/');
            await ShowProfiles();
            return;
        }
        if (status == "pending")
        {
            var requestId = pendingRequestId ?? result.GetProperty("requestId").GetString() ?? "";
            var requestToken = pendingRequestToken ?? result.GetProperty("requestToken").GetString() ?? "";
            if (!ClearSurface()) return;
            AddHeading("Waiting for server approval", 24);
            SurfaceContent.Children.Add(new TextBlock { Text = "Ask the server administrator to approve this device in Server Manager.", TextWrapping = TextWrapping.Wrap });
            SurfaceContent.Children.Add(new TextBlock { Text = "This request expires after 10 minutes. If it expires, sign in with Google again.", TextWrapping = TextWrapping.Wrap });
            var check = new Button { Content = "Check approval", Padding = new Thickness(12), Margin = new Thickness(0, 8, 0, 8) };
            check.Click += async (_, _) =>
            {
                try
                {
                    using var response = await AccountJson(HttpMethod.Post, "/api/google-auth/client/status", new { requestId, requestToken });
                    await HandleGoogleLoginResult(response.RootElement, requestId, requestToken);
                }
                catch (Exception error) { ShowMessage(error.Message); }
            };
            SurfaceContent.Children.Add(check);
            var retry = new Button { Content = "Sign in with Google again", Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8) };
            retry.Click += async (_, _) => await SignInWithGoogle();
            SurfaceContent.Children.Add(retry);
            return;
        }
        ShowMessage(status == "rejected" ? "The server administrator rejected this device." : $"Google sign-in returned {status}.");
    }

    private async Task ShowProfiles()
    {
        await DisconnectChat();
        Token.Text = "";
        activeProfileId = "";
        activeProfileName = "";
        try
        {
            using var response = await AccountJson(HttpMethod.Post, "/api/client/profile/register", new { });
            var user = response.RootElement.GetProperty("user");
            accountIdentity = user.Clone();
            googleAccountLabel = $"{user.GetProperty("displayName").GetString()} · ID: {user.GetProperty("username").GetString()} · {user.GetProperty("email").GetString()}";
            if (!user.GetProperty("credentialsConfigured").GetBoolean()) { if (!ClearSurface()) return; AddHeading("Set up your Codmes account", 24); AddBodyText("Your existing account and data are preserved."); AddCodmesLoginFields(true, true); return; }
            var profile = response.RootElement.GetProperty("profile");
            var id = profile.GetProperty("id").GetString()!;
            using var opened = await AccountJson(HttpMethod.Post, $"/api/profiles/{Uri.EscapeDataString(id)}/open", new { });
            Token.Text = opened.RootElement.GetProperty("token").GetString() ?? "";
            activeProfileId = id;
            activeProfileName = profile.GetProperty("name").GetString()!;
            await LoadPlugins();
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private void AddCodmesLoginFields(bool signup, bool setup = false)
    {
        var username = new TextBox { MaxLength = 64, Margin = new Thickness(0, 6, 0, 6) };
        var password = new PasswordBox { MaxLength = 128, Margin = new Thickness(0, 6, 0, 6) };
        var confirmation = new PasswordBox { MaxLength = 128, Margin = new Thickness(0, 6, 0, 6) };
        AddBodyText("Codmes ID (3–64 letters, numbers, dots, underscores or hyphens)");
        SurfaceContent.Children.Add(username); AddBodyText(signup ? "Password (15–128 characters)" : "Password"); SurfaceContent.Children.Add(password);
        if (signup) { AddBodyText("Confirm password"); SurfaceContent.Children.Add(confirmation); }
        var submit = new Button { Content = setup ? "Complete account setup" : signup ? "Sign up" : "Sign in", Padding = new Thickness(12) };
        submit.Click += async (_, _) =>
        {
            if (accountActionBusy) return;
            if (signup && (password.Password.Length < 15 || password.Password != confirmation.Password)) { ShowMessage("Use 15–128 characters and match the confirmation."); return; }
            accountActionBusy = true; submit.IsEnabled = false;
            var serverUrl = Server.Text.TrimEnd('/');
            try
            {
                if (setup && accountToken.Length > 0)
                {
                    using var _ = await AccountJson(HttpMethod.Post, "/api/auth/account/credentials", new { username = username.Text, password = password.Password }, serverUrl);
                    await ShowProfiles();
                }
                else
                {
                    JsonDocument result;
                    if (setup && setupGoogleToken.Length > 0)
                    {
                        if (setupGoogleServer != serverUrl || DateTime.UtcNow - setupGoogleCreated > TimeSpan.FromMinutes(10)) throw new InvalidOperationException("Google sign-in expired. Sign in again.");
                        result = await AccountJson(HttpMethod.Post, "/api/google-auth/client/login", new { idToken = setupGoogleToken, username = username.Text, password = password.Password, deviceId = ClientDeviceIdentity.LoadOrCreate(serverUrl), deviceName = Environment.MachineName }, serverUrl);
                    }
                    else result = await AccountJson(HttpMethod.Post, signup ? "/api/auth/client/register" : "/api/auth/client/login", new { username = username.Text, password = password.Password, deviceId = ClientDeviceIdentity.LoadOrCreate(serverUrl), deviceName = Environment.MachineName }, serverUrl);
                    using (result) { if (Server.Text.TrimEnd('/') == serverUrl) { setupGoogleToken = ""; await HandleGoogleLoginResult(result.RootElement); } }
                }
                password.Clear(); confirmation.Clear();
            }
            catch (Exception error) { ShowMessage(error.Message); }
            finally { accountActionBusy = false; submit.IsEnabled = true; }
        };
        SurfaceContent.Children.Add(submit);
        var toggle = new Button { Content = setup ? "Cancel / sign in to an existing account" : signup ? "Already have an account? Sign in" : "Create a Codmes account", Padding = new Thickness(12), Margin = new Thickness(0, 8, 0, 8) };
        toggle.Click += async (_, _) => { if (accountActionBusy) return; setupGoogleToken = ""; if (setup) { accountToken = ""; await ShowServerLogin(); } else { if (!ClearSurface()) return; AddHeading(signup ? "Sign in" : "Sign up",24); AddCodmesLoginFields(!signup); } };
        SurfaceContent.Children.Add(toggle);
    }

    private void AddCodmesAccountSettings()
    {
        AddHeading("Codmes account / login methods", 20);
        var current = new PasswordBox { MaxLength = 128 };
        AddBodyText("Current Codmes password"); SurfaceContent.Children.Add(current);
        var link = new Button { Content = "Connect / change Google", Padding = new Thickness(12), Margin = new Thickness(0,8,0,8) };
        link.Click += async (_, _) =>
        {
            if (accountActionBusy || current.Password.Length == 0) return;
            accountActionBusy = true; googleSignInBusy = true;
            var serverUrl = Server.Text.TrimEnd('/'); var existingToken = accountToken;
            try {
                var idToken = await GoogleDesktopSignIn.GetIdTokenAsync(googleDesktopClientId);
                if (Server.Text.TrimEnd('/') != serverUrl || accountToken != existingToken) return;
                using var _ = await AccountJson(HttpMethod.Post, "/api/auth/account/google/link", new { idToken, currentPassword = current.Password }, serverUrl);
                await ShowProfiles(); await ShowProfileSettings();
            } catch (Exception error) { ShowMessage(error.Message); }
            finally { accountActionBusy = false; googleSignInBusy = false; current.Clear(); }
        };
        SurfaceContent.Children.Add(link);
        if (accountIdentity.ValueKind == JsonValueKind.Object && accountIdentity.GetProperty("googleLinked").GetBoolean())
        {
            var unlink = new Button { Content = "Disconnect Google", Padding = new Thickness(12) };
            unlink.Click += async (_, _) => {
                if (accountActionBusy || current.Password.Length == 0 || MessageBox.Show("Disconnect Google? Codmes ID/password and existing data will remain.", "Google connection", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
                accountActionBusy = true;
                try { using var _ = await AccountJson(HttpMethod.Post, "/api/auth/account/google/unlink", new { currentPassword = current.Password }); await ShowProfiles(); await ShowProfileSettings(); }
                catch (Exception error) { ShowMessage(error.Message); }
                finally { accountActionBusy = false; current.Clear(); }
            };
            SurfaceContent.Children.Add(unlink);
        }
        var password = new PasswordBox { MaxLength = 128 }; var confirmation = new PasswordBox { MaxLength = 128 };
        AddBodyText("New password (15–128 characters)"); SurfaceContent.Children.Add(password); AddBodyText("Confirm new password"); SurfaceContent.Children.Add(confirmation);
        var change = new Button { Content = "Change password", Padding = new Thickness(12), Margin = new Thickness(0,8,0,8) };
        change.Click += async (_, _) => {
            if (accountActionBusy || current.Password.Length == 0 || password.Password.Length < 15 || password.Password != confirmation.Password) return;
            accountActionBusy = true;
            try { using var _ = await AccountJson(HttpMethod.Post, "/api/auth/account/password", new { currentPassword = current.Password, password = password.Password }); current.Clear();password.Clear();confirmation.Clear(); AddBodyText("Password changed. Other account sessions are signed out."); }
            catch (Exception error) { ShowMessage(error.Message); } finally { accountActionBusy = false; }
        };
        SurfaceContent.Children.Add(change);
        AddBodyText("Google connection changes keep your profile and approvals, and sign out other sessions. Administrator accounts are managed in Server Manager.");
    }

    private async Task<JsonDocument> AccountJson(HttpMethod method, string path, object? body = null, string? serverUrl = null)
    {
        serverUrl ??= Server.Text.TrimEnd('/');
        if (accountToken.Length > 0 && serverUrl != accountServerUrl)
            throw new InvalidOperationException("The server address changed. Connect to the selected server again.");
        var uri = new Uri(serverUrl);
        if (path != "/api/google-auth/config" && uri.Scheme != Uri.UriSchemeHttps && !uri.IsLoopback) throw new InvalidOperationException("Remote account access requires HTTPS.");
        using var request = new HttpRequestMessage(method, serverUrl + path);
        if (accountToken.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accountToken);
        if (body is not null) request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"Server returned {(int)response.StatusCode}: {text}");
        return JsonDocument.Parse(text);
    }

    private async Task ShowProfileSettings()
    {
        if (activeProfileId.Length == 0) { await ShowProfiles(); return; }
        if (!ClearSurface()) return;
        AddHeading($"Account · {activeProfileName}", 24);
        AddBodyText(googleAccountLabel);
        AddBodyText("Your Codmes account automatically selects your profile. The same account shares this profile across approved devices on this server.");
        var signOut = new Button { Content = "Sign out / another account", Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8) };
        signOut.Click += async (_, _) =>
        {
            try { using var _ = await AccountJson(HttpMethod.Post, "/api/auth/logout", new { }); }
            catch { }
            accountToken = "";
            googleAccountLabel = "";
            Token.Text = "";
            activeProfileId = "";
            await ShowServerLogin();
        };
        SurfaceContent.Children.Add(signOut);
        var delete = new Button { Content = "Delete profile", Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8) };
        delete.Click += async (_, _) =>
        {
            if (MessageBox.Show($"Delete {activeProfileName} on all devices using this Codmes account? Server Manager can restore its data.", "Delete profile", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            try
            {
                using var _ = await AccountJson(HttpMethod.Post, $"/api/profiles/{Uri.EscapeDataString(activeProfileId)}/archive", new { });
                Token.Text = "";
                activeProfileId = "";
                await ShowProfiles();
            }
            catch (Exception error) { ShowMessage(error.Message); }
        };
        SurfaceContent.Children.Add(delete);
        AddCodmesAccountSettings();
        AddAppLockSettings();
        var back = new Button { Content = "Back", Padding = new Thickness(12) };
        back.Click += async (_, _) => await LoadPlugins();
        SurfaceContent.Children.Add(back);
    }

    private async Task LoadPlugins()
    {
        try
        {
            using var document = await GetJson("/api/plugins");
            if (!ClearSurface()) return;
            AddBodyText(googleAccountLabel);
            var profileSettings = new Button { Content = "Profile settings", Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(12) };
            profileSettings.Click += async (_, _) => await ShowProfileSettings();
            SurfaceContent.Children.Add(profileSettings);
            var approvals = new Button { Content = "Pending approvals", Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(12) };
            approvals.Click += async (_, _) => await OpenApprovals();
            SurfaceContent.Children.Add(approvals);
            foreach (var plugin in document.RootElement.GetProperty("plugins").EnumerateArray())
            {
                if (!SupportsWindowsDesktop(plugin)) continue;
                var pluginId = plugin.GetProperty("id").GetString()!;
                if (!plugin.GetProperty("builtIn").GetBoolean())
                {
                    var toolButton = new Button { Content = $"{plugin.GetProperty("name").GetString()} · MCP tools", Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(12) };
                    toolButton.Click += async (_, _) => await OpenMcpTools(pluginId);
                    SurfaceContent.Children.Add(toolButton);
                }
                foreach (var view in plugin.GetProperty("views").EnumerateArray())
                {
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

    private async Task OpenMcpTools(string pluginId, bool refresh = false)
    {
        try
        {
            var encoded = Uri.EscapeDataString(pluginId);
            if (refresh) await SendJson(HttpMethod.Post, $"/api/plugins/{encoded}/mcp-tools/refresh", new { });
            using var document = await GetJson($"/api/plugins/{encoded}/mcp-tools");
            var root = document.RootElement;
            var approved = root.GetProperty("approvedTools").EnumerateArray()
                .Select(item => item.GetString() ?? "").Where(name => name.Length > 0).ToHashSet();
            if (!ClearSurface()) return;
            AddHeading("MCP tools", 24);
            AddBodyText("Discovered tools stay unavailable to AI until you approve them for this Workspace.");
            var discover = new Button { Content = "Discover", Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 10) };
            discover.Click += async (_, _) => await OpenMcpTools(pluginId, true);
            SurfaceContent.Children.Add(discover);
            var tools = root.GetProperty("discoveredTools");
            if (tools.GetArrayLength() == 0) AddBodyText("No tool catalog has been stored yet.");
            foreach (var tool in tools.EnumerateArray())
            {
                var name = tool.GetProperty("name").GetString()!;
                var check = new CheckBox {
                    Content = tool.GetProperty("approved").GetBoolean() ? name : $"{name} · Waiting for approval",
                    IsChecked = tool.GetProperty("approved").GetBoolean(),
                    Margin = new Thickness(0, 6, 0, 2)
                };
                check.Click += async (_, _) =>
                {
                    if (check.IsChecked == true) approved.Add(name); else approved.Remove(name);
                    try
                    {
                        await SendJson(HttpMethod.Post, $"/api/plugins/{encoded}/mcp-tools/consent", new { approvedTools = approved.OrderBy(name => name).ToArray() });
                    }
                    catch (Exception error) { ShowMessage(error.Message); }
                };
                SurfaceContent.Children.Add(check);
                if (tool.TryGetProperty("description", out var description)) AddBodyText(description.GetString());
            }
            AddBackButton(LoadPlugins);
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenApprovals()
    {
        try
        {
            using var document = await GetJson("/api/agent/approvals?status=pending&limit=50");
            if (!ClearSurface()) return;
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
        if (!ClearSurface()) return;
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
            if (!ClearSurface()) return;
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
        rootName = rootName.Equals("code", StringComparison.OrdinalIgnoreCase) ? "Code" : "Notes";
        try
        {
            var scope = DocumentScope;
            var policies = new WorkspaceStoragePolicies(Server.Text, activeProfileId);
            string json; bool online = true;
            try { using var listing = await GetJson("/api/sync/manifest"); json = listing.RootElement.GetRawText(); policies.CacheCatalog(json); }
            catch { online = false; json = policies.CachedCatalog() ?? throw new IOException("저장된 파일 목록이 없습니다. 서버에 먼저 연결하세요."); }
            using var document = JsonDocument.Parse(json);
            if (!ClearSurface()) return;
            AddHeading(char.ToUpperInvariant(rootName[0]) + rootName[1..], 24);
            if (!online) AddHeading("▱ ☁̸ 오프라인 · 이 기기에 저장된 자료만 열 수 있습니다", 14);
            var rootMode = new ComboBox { ItemsSource = new[] { "local", "server", "sync" }, SelectedItem = policies.Mode(rootName), Width = 140, HorizontalAlignment = HorizontalAlignment.Left };
            rootMode.SelectionChanged += (_, _) => policies.Set(rootName, rootMode.SelectedItem as string);
            SurfaceContent.Children.Add(rootMode);
            var queued = new List<(string Path, string Resource, string? Id, TextBlock Status, StackPanel Row, ProgressBar Busy)>();
            foreach (var item in document.RootElement.GetProperty("entries").EnumerateArray().OrderBy(e => e.GetProperty("path").GetString()))
            {
                var path = item.GetProperty("path").GetString()!;
                var resource = item.GetProperty("resource").GetString()!;
                if (!path.StartsWith(rootName + "/", StringComparison.OrdinalIgnoreCase) || resource == "annotations") continue;
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
                var button = new Button { Content = (resource == "folder" ? "📁 " : "") + path, Padding = new Thickness(10), IsEnabled = resource != "folder" };
                button.Click += async (_, _) =>
                {
                    if (path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) await OpenPdf(path, rootName);
                    else await OpenFile(path, rootName);
                };
                row.Children.Add(button);
                var mode = new ComboBox { ItemsSource = new[] { "local", "server", "sync", "inherit" }, SelectedItem = policies.Mode(path), Width = 100, Margin = new Thickness(6, 0, 6, 0) };
                var status = new TextBlock { Text = online ? "목록 확인됨" : "오프라인", VerticalAlignment = VerticalAlignment.Center };
                var id = item.TryGetProperty("fileId", out var identity) ? identity.GetString() : null;
                if (resource == "file" && online && DocumentJournal(path, "file").AdoptIdenticalEntry(item)) { mode.SelectedItem = "sync"; }
                mode.SelectionChanged += async (_, _) => {
                    try {
                        policies.Set(path, mode.SelectedItem as string == "inherit" ? null : mode.SelectedItem as string);
                        if (resource == "file") { var journal = DocumentJournal(path, "file"); journal.EvictIfClean(); if (online) await journal.ReportPolicyAsync(id); }
                        status.Text = "이 기기의 설정 저장됨";
                    } catch (Exception error) { status.Text = error.Message; }
                };
                var busy = new ProgressBar { IsIndeterminate = true, Width = 24, Height = 6, Visibility = Visibility.Collapsed, Margin = new Thickness(6) };
                row.Children.Add(mode); row.Children.Add(status); row.Children.Add(busy); SurfaceContent.Children.Add(row);
                if (resource == "file") queued.Add((path, resource, id, status, row, busy));
            }
            AddBackButton(LoadPlugins);
            // Publish the complete catalog before the sequential transfer queue starts.
            foreach (var item in queued) {
                if (DocumentScope != scope || !SurfaceContent.Children.Contains(item.Row)) break;
                if (!online) continue;
                var journal = DocumentJournal(item.Path, "file");
                if (policies.Mode(item.Path) != "sync") { try { journal.EvictIfClean(); await journal.ReportPolicyAsync(item.Id); item.Status.Text = "이 기기: " + policies.Mode(item.Path); } catch (Exception error) { item.Status.Text = error.Message; } continue; }
                item.Status.Text = "다운로드 중"; item.Busy.Visibility = Visibility.Visible;
                try { await journal.OpenAsync(); await journal.ReportPolicyAsync(item.Id); item.Status.Text = "동기화됨"; }
                catch (FirstRegistrationConflict) { item.Status.Text = "⚠ 확인 필요"; await AskFileConflict(journal); }
                catch (Exception error) { item.Status.Text = "⏸ " + error.Message; }
                finally { item.Busy.Visibility = Visibility.Collapsed; }
            }
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task AskFileConflict(VersionedDocument journal) {
        var answer = MessageBox.Show("서버에 같은 경로의 다른 파일이 있습니다.\n예: 서버 버전 사용 (이 기기 내용 교체)\n아니요: 내 버전으로 서버 덮어쓰기 (다른 기기에도 반영)\n취소: 나중에 결정 · 로컬 변경 보존", "파일 충돌 확인", MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
        if (answer == MessageBoxResult.Cancel) return;
        try { await journal.ResolveFirstConflictAsync(answer == MessageBoxResult.Yes); await journal.FlushAsync(); }
        catch (Exception error) { MessageBox.Show(error.Message, "로컬 변경 보존됨"); }
    }

    private async Task OpenPdf(string path, string rootName)
    {
        if (DocumentJournal(path, "file").StorageMode == "local") { ShowMessage("Windows 로컬 PDF 렌더링은 아직 지원하지 않습니다. 서버 모드로 열거나 Apple 클라이언트를 사용하세요. 로컬 자료는 보존됩니다."); return; }
        try
        {
            using var metadata = await GetJson($"/api/pdf/metadata?path={Uri.EscapeDataString(path)}");
            if (!FlushEditor()) return;
            var journal = DocumentJournal(path, "annotations");
            var annotations = JsonNode.Parse(await journal.OpenAsync())!.AsObject();
            VersionedDocument.EnsurePageIds(annotations);
            var pageCount = Math.Max(1, metadata.RootElement.GetProperty("pageCount").GetInt32());
            var pageIndex = 0;
            if (!ClearSurface()) return;
            var heading = new TextBlock { FontSize = 22, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 8) };
            var viewer = new PdfAnnotationCanvas { Height = 620, MinWidth = 500 };
            var status = new TextBlock { Text = "Local document ready", TextWrapping = TextWrapping.Wrap };
            var documentScope = DocumentScope;
            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
            void SaveLocal() { timer.Stop(); if (viewer.Document["pages"] == null) return; try { VersionedDocument.EnsurePageIds(viewer.Document); journal.Save(Encoding.UTF8.GetBytes(viewer.Document.ToJsonString())); localEditorSaveFailed = false; status.Text = "Locally saved · synchronization pending"; } catch (Exception error) { localEditorSaveFailed = true; status.Text = "Not saved: " + error.Message; } }
            async Task Sync() {
                if (DocumentScope != documentScope) return;
                var snapshot = viewer.Document.ToJsonString();
                try { await journal.FlushAsync(); var merged = await journal.OpenAsync();
                    if (DocumentScope == documentScope && viewer.Document.ToJsonString() == snapshot && journal.PendingCount == 0) viewer.UpdateDocument(JsonNode.Parse(merged)!.AsObject());
                    status.Text = journal.PendingCount == 0 ? "Server synchronized" : "Locally saved · synchronization pending";
                } catch (Exception error) { status.Text = error.Message; }
            }
            viewer.DocumentChanged = () => { SaveLocal(); timer.Start(); };
            viewer.EditingStarted = journal.PinDraft;
            timer.Tick += async (_, _) => { timer.Stop(); await Sync(); };
            flushLocalEditor = SaveLocal;
            syncCurrentEditor = Sync;
            async Task LoadPage()
            {
                heading.Text = $"{System.IO.Path.GetFileName(path)} · {pageIndex + 1}/{pageCount}";
                var bytes = await GetBytes($"/api/pdf-thumbnail?path={Uri.EscapeDataString(path)}&page={pageIndex + 1}&scale=2");
                viewer.SetPage(bytes, viewer.Document.Count > 0 ? viewer.Document : annotations, pageIndex);
            }
            viewer.TextRequested = (x, y) =>
            {
                var value = PromptForText();
                if (!string.IsNullOrWhiteSpace(value)) viewer.AddText(x, y, value);
            };
            SurfaceContent.Children.Add(heading);
            SurfaceContent.Children.Add(viewer);
            SurfaceContent.Children.Add(status);
            var tools = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 8) };
            var undo = new Button { Content = "‹", ToolTip = "Undo", IsEnabled = false, Padding = new Thickness(12, 6, 12, 6) };
            var redo = new Button { Content = "›", ToolTip = "Redo", IsEnabled = false, Padding = new Thickness(12, 6, 12, 6) };
            undo.Click += (_, _) => viewer.Undo(); redo.Click += (_, _) => viewer.Redo();
            viewer.UndoStateChanged = () => { undo.IsEnabled = viewer.CanUndo; redo.IsEnabled = viewer.CanRedo; };
            tools.Children.Add(undo); tools.Children.Add(redo);
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
            var save = new Button { Content = "Retry sync", Padding = new Thickness(12, 6, 12, 6) };
            save.Click += async (_, _) => { SaveLocal(); await Sync(); };
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
            if (!FlushEditor()) return;
            var journal = DocumentJournal(path, "file");
            var bytes = await journal.OpenAsync();
            if (!ClearSurface()) return;
            AddHeading(System.IO.Path.GetFileName(path), 22);
            var editor = new TextBox {
                Text = Encoding.UTF8.GetString(bytes),
                AcceptsReturn = true,
                AcceptsTab = true,
                UndoLimit = 80,
                MinHeight = 400,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
            };
            SurfaceContent.Children.Add(editor);
            var status = new TextBlock { Text = "Local document ready", TextWrapping = TextWrapping.Wrap };
            SurfaceContent.Children.Add(status);
            var undo = new Button { Content = "‹", ToolTip = "Undo", IsEnabled = false, Padding = new Thickness(14, 7, 14, 7) };
            var redo = new Button { Content = "›", ToolTip = "Redo", IsEnabled = false, Padding = new Thickness(14, 7, 14, 7) };
            var edits = new StackPanel { Orientation = Orientation.Horizontal };
            void UpdateUndo() { undo.IsEnabled = editor.CanUndo; redo.IsEnabled = editor.CanRedo; }
            undo.Click += (_, _) => { editor.Undo(); UpdateUndo(); }; redo.Click += (_, _) => { editor.Redo(); UpdateUndo(); };
            edits.Children.Add(undo); edits.Children.Add(redo); SurfaceContent.Children.Add(edits);
            var remoteUpdate = false;
            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
            var scope = DocumentScope;
            var editTime = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            void SaveLocal() { timer.Stop(); try { journal.Save(Encoding.UTF8.GetBytes(editor.Text), editTime); localEditorSaveFailed = false; status.Text = "Locally saved · synchronization pending"; } catch (Exception error) { localEditorSaveFailed = true; status.Text = "Not saved: " + error.Message; } }
            async Task Sync() {
                if (scope != DocumentScope) return;
                var snapshot = editor.Text;
                try { await journal.FlushAsync(); var merged = await journal.OpenAsync();
                    if (scope == DocumentScope && editor.Text == snapshot && journal.PendingCount == 0 && editor.Text != Encoding.UTF8.GetString(merged)) {
                        remoteUpdate = true; editor.IsUndoEnabled = false; editor.Text = Encoding.UTF8.GetString(merged); editor.IsUndoEnabled = true; remoteUpdate = false; UpdateUndo();
                    }
                    status.Text = journal.PendingCount == 0 ? "Server synchronized" : "Locally saved · synchronization pending";
                } catch (Exception error) { status.Text = error.Message; }
            }
            timer.Tick += async (_, _) => { timer.Stop(); SaveLocal(); await Sync(); };
            editor.TextChanged += (_, _) => { UpdateUndo(); if (remoteUpdate) return; journal.PinDraft(); editTime = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); timer.Stop(); timer.Start(); status.Text = "Autosaving…"; };
            flushLocalEditor = SaveLocal;
            syncCurrentEditor = Sync;
            var save = new Button { Content = "Retry sync", Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 10, 0, 6) };
            save.Click += async (_, _) => { SaveLocal(); await Sync(); };
            SurfaceContent.Children.Add(save);
            AddBackButton(() => OpenFiles(rootName));
        }
        catch (Exception error) { ShowMessage(error.Message); }
    }

    private async Task OpenChat()
    {
        await DisconnectChat();
        if (!ClearSurface()) return;
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
        pendingMessage = null;
        transcript = null;
    }

    private string DocumentScope => Server.Text.TrimEnd('/') + "|" + activeProfileId;
    private VersionedDocument DocumentJournal(string path, string resource)
    {
        if (activeProfileId.Length == 0 || Token.Text.Trim().Length == 0) throw new InvalidOperationException("Connect to a server account first.");
        if (accountServerUrl.Length > 0 && accountServerUrl != Server.Text.TrimEnd('/')) throw new InvalidOperationException("Reconnect after changing the server address.");
        var key = DocumentScope + "|" + path + "|" + resource;
        if (!documents.TryGetValue(key, out var journal)) {
            journal = new VersionedDocument(http, Server.Text.TrimEnd('/'), Token.Text.Trim(), activeProfileId, path, resource, ClientDeviceIdentity.LoadOrCreate(Server.Text));
            documents[key] = journal;
        }
        journal.UpdateAuth(Token.Text.Trim());
        return journal;
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
        back.Click += async (_, _) => { if (FlushEditor()) await action(); };
        SurfaceContent.Children.Add(back);
    }
    private void AppendChat(string value) { if (transcript is not null) transcript.Text += $"\n{value}"; }
    private bool FlushEditor() { flushLocalEditor?.Invoke(); return !localEditorSaveFailed; }
    private bool ClearSurface()
    {
        if (!FlushEditor()) return false;
        flushLocalEditor = null; syncCurrentEditor = null;
        SurfaceContent.Children.Clear(); return true;
    }
    private void ShowMessage(string message) { if (!ClearSurface()) return; AddBodyText(message); }
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
