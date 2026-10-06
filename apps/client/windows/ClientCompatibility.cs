namespace Codmes.Windows;

public static class ClientCompatibility
{
    public static bool Supports(
        IEnumerable<string> declaredPlatforms,
        IEnumerable<string> declaredFormFactors,
        string currentPlatform,
        string currentFormFactor)
    {
        var originalPlatforms = declaredPlatforms.Select(Normalize).Where(value => value.Length > 0).Distinct().ToArray();
        var platforms = originalPlatforms.Select(value => value == "ipados" ? "ios" : value).Distinct().ToArray();
        var declaredFactors = declaredFormFactors.Select(Normalize).Where(value => value.Length > 0).Distinct().ToArray();
        var factors = declaredFactors.Length > 0 ? declaredFactors : LegacyFormFactors(originalPlatforms);

        return (platforms.Length == 0 || platforms.Contains(Normalize(currentPlatform)))
            && (factors.Length == 0 || factors.Contains(Normalize(currentFormFactor)));
    }

    private static string[] LegacyFormFactors(IEnumerable<string> platforms) =>
        platforms.Select(value => value switch
        {
            "macos" => "desktop",
            "ios" => "phone",
            "ipados" => "tablet",
            _ => ""
        }).Where(value => value.Length > 0).Distinct().ToArray();

    private static string Normalize(string value) => value.Trim().ToLowerInvariant();
}
