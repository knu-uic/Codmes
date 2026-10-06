using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Codmes.Windows;

internal static class GoogleDesktopSignIn
{
    private static readonly HttpClient Http = new();

    public static async Task<string> GetIdTokenAsync(string serverClientId)
    {
        var clientId = PublisherCredential("CodmesGoogleDesktopClientId");
        ValidatePublisher(clientId, serverClientId);
        var clientSecret = PublisherCredential("CodmesGoogleDesktopClientSecret");
        if (string.IsNullOrWhiteSpace(clientSecret))
            throw new InvalidOperationException("This Codmes Windows build is missing its Google Desktop OAuth client secret. Install a build with the matching Desktop app credential.");
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var redirectUri = $"http://127.0.0.1:{port}/";
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = Base64Url(RandomNumberGenerator.GetBytes(32));
        var nonce = Base64Url(RandomNumberGenerator.GetBytes(32));

        var authorizationUrl = "https://accounts.google.com/o/oauth2/v2/auth?" + FormQuery(new Dictionary<string, string>
        {
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = "openid email profile",
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256",
            ["state"] = state,
            ["nonce"] = nonce,
            ["prompt"] = "select_account"
        });
        Process.Start(new ProcessStartInfo(authorizationUrl) { UseShellExecute = true });

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        var code = await AwaitCodeAsync(listener, state, timeout.Token);

        using var response = await Http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["code"] = code,
            ["client_id"] = clientId,
            ["client_secret"] = clientSecret,
            ["code_verifier"] = verifier,
            ["redirect_uri"] = redirectUri,
            ["grant_type"] = "authorization_code"
        }), timeout.Token);
        var body = await response.Content.ReadAsStringAsync(timeout.Token);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Google token exchange failed ({(int)response.StatusCode}).");
        using var document = JsonDocument.Parse(body);
        var token = document.RootElement.TryGetProperty("id_token", out var idToken)
            ? idToken.GetString() ?? throw new InvalidOperationException("Google returned an empty ID token.")
            : throw new InvalidOperationException("Google did not return an ID token.");
        ValidateTokenBinding(token, clientId, nonce);
        return token;
    }

    private static string PublisherCredential(string key) => typeof(GoogleDesktopSignIn).Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(attribute => attribute.Key == key)?.Value ?? "";

    internal static void ValidatePublisher(string clientId, string serverClientId)
    {
        if (string.IsNullOrWhiteSpace(clientId) || !clientId.EndsWith(".apps.googleusercontent.com", StringComparison.Ordinal)
            || !string.Equals(clientId, serverClientId, StringComparison.Ordinal))
            throw new InvalidOperationException("This app and server have different Codmes publisher login settings. Use matching app and Server Manager builds; server owners do not need their own Google Cloud project.");
    }

    // The backend separately verifies Google's signature and identity claims.
    internal static void ValidateTokenBinding(string token, string clientId, string nonce)
    {
        try
        {
            if (token.Length > 16_384) throw new FormatException();
            var segments = token.Split('.');
            if (segments.Length != 3) throw new FormatException();
            var payload = segments[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
            using var claims = JsonDocument.Parse(Convert.FromBase64String(payload));
            if (claims.RootElement.GetProperty("aud").GetString() != clientId
                || claims.RootElement.GetProperty("nonce").GetString() != nonce) throw new FormatException();
        }
        catch (Exception error) when (error is FormatException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new InvalidOperationException("Google sign-in response did not match this app and login attempt.");
        }
    }

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string FormQuery(IReadOnlyDictionary<string, string> fields) => string.Join("&", fields.Select(entry => $"{Uri.EscapeDataString(entry.Key)}={Uri.EscapeDataString(entry.Value)}"));

    private static async Task<string> AwaitCodeAsync(TcpListener listener, string expectedState, CancellationToken cancellation)
    {
        while (true)
        {
            using var callback = await listener.AcceptTcpClientAsync(cancellation);
            using var stream = callback.GetStream();
            using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
            var requestLine = await reader.ReadLineAsync(cancellation);
            var target = requestLine?.Split(' ', StringSplitOptions.RemoveEmptyEntries).ElementAtOrDefault(1);
            if (target is null || !Uri.TryCreate($"http://127.0.0.1{target}", UriKind.Absolute, out var uri)
                || uri?.AbsolutePath != "/")
            {
                await WriteCallbackAsync(stream, false, cancellation);
                continue;
            }
            var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(part => part.Split('=', 2))
                .ToDictionary(part => Uri.UnescapeDataString(part[0]), part => part.Length == 2 ? Uri.UnescapeDataString(part[1]) : "");
            if (!query.TryGetValue("state", out var returnedState)
                || !string.Equals(returnedState, expectedState, StringComparison.Ordinal))
            {
                await WriteCallbackAsync(stream, false, cancellation);
                continue;
            }
            if (query.TryGetValue("error", out var error))
            {
                await WriteCallbackAsync(stream, false, cancellation);
                throw new InvalidOperationException($"Google sign-in failed: {error}");
            }
            if (!query.TryGetValue("code", out var code) || string.IsNullOrEmpty(code))
            {
                await WriteCallbackAsync(stream, false, cancellation);
                throw new InvalidOperationException("Google sign-in callback did not contain an authorization code.");
            }
            await WriteCallbackAsync(stream, true, cancellation);
            return code;
        }
    }

    private static async Task WriteCallbackAsync(NetworkStream stream, bool success, CancellationToken cancellation)
    {
        var page = success ? "Google sign-in complete. Return to Codmes." : "Google sign-in was not completed. Return to Codmes.";
        var html = $"<!doctype html><meta charset=\"utf-8\"><title>Codmes</title><p>{page}</p>";
        var body = Encoding.UTF8.GetBytes(html);
        var headers = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(headers, cancellation);
        await stream.WriteAsync(body, cancellation);
    }
}
