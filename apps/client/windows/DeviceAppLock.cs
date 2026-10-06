using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Codmes.Windows;

internal static class AppLockPin
{
    public static bool IsValid(string pin) => pin.Length == 4 && pin.All(c => c >= '0' && c <= '9');
    public static string Encode(string pin)
    {
        if (!IsValid(pin)) throw new ArgumentException("Use exactly four digits.");
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(pin, salt, 100_000, HashAlgorithmName.SHA256, 32);
        return $"{Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}";
    }
    public static bool Verify(string pin, string encoded)
    {
        if (!IsValid(pin)) return false;
        try
        {
            var parts = encoded.Split('$');
            if (parts.Length != 2) return false;
            var salt = Convert.FromBase64String(parts[0]);
            var expected = Convert.FromBase64String(parts[1]);
            if (salt.Length != 16 || expected.Length != 32) return false;
            return CryptographicOperations.FixedTimeEquals(expected, Rfc2898DeriveBytes.Pbkdf2(pin, salt, 100_000, HashAlgorithmName.SHA256, 32));
        }
        catch (FormatException) { return false; }
    }
}

#if WINDOWS
internal sealed class DeviceAppLock
{
    private readonly string file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codmes", "app-lock");
    private int attempts;
    private DateTime blockedUntil;
    public bool Enabled => File.Exists(file);

    public void Authorize(string pin)
    {
        if (DateTime.UtcNow < blockedUntil) throw new InvalidOperationException("Too many attempts. Wait one minute.");
        var valid = false;
        try
        {
            var encoded = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser));
            valid = AppLockPin.Verify(pin, encoded);
        }
        catch (Exception error) when (error is IOException or CryptographicException) { }
        if (!valid)
        {
            if (++attempts >= 5) { attempts = 0; blockedUntil = DateTime.UtcNow.AddMinutes(1); }
            throw new InvalidOperationException("Incorrect PIN.");
        }
        attempts = 0;
    }
    public void Set(string current, string pin, string confirmation)
    {
        if (Enabled) Authorize(current);
        if (!AppLockPin.IsValid(pin) || pin != confirmation) throw new ArgumentException("Enter matching four-digit PINs.");
        var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(AppLockPin.Encode(pin)), null, DataProtectionScope.CurrentUser);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllBytes(file, data);
    }
    public void Disable(string current) { Authorize(current); File.Delete(file); }
}
#endif
