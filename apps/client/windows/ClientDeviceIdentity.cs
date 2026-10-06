using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Codmes.Windows;

internal static class ClientDeviceIdentity
{
    public static string LoadOrCreate(string serverUrl)
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codmes");
        Directory.CreateDirectory(directory);
        var serverKey = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(serverUrl.TrimEnd('/'))));
        var file = Path.Combine(directory, $"device-{serverKey}");
        if (File.Exists(file))
        {
            var stored = File.ReadAllText(file).Trim();
            if (stored.Length >= 43) return stored;
        }
        var identifier = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        File.WriteAllText(file, identifier);
        return identifier;
    }
}
