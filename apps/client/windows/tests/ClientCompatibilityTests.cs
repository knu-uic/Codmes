using Codmes.Windows;
using Xunit;

namespace Codmes.Windows.Tests;

public class ClientCompatibilityTests
{
    [Fact]
    public void WindowsDesktopMatchesFullCompatibility()
    {
        Assert.True(ClientCompatibility.Supports(
            ["macos", "ios", "android", "windows"],
            ["phone", "tablet", "desktop"],
            "windows",
            "desktop"));
        Assert.False(ClientCompatibility.Supports(
            ["android"],
            ["desktop"],
            "windows",
            "desktop"));
    }

    [Fact]
    public void LegacyIPadOSNormalizesToIosTablet()
    {
        Assert.True(ClientCompatibility.Supports(["ipados"], [], "ios", "tablet"));
        Assert.False(ClientCompatibility.Supports(["ipados"], [], "windows", "desktop"));
    }

    [Fact]
    public void AbsentMetadataRemainsBackwardCompatible()
    {
        Assert.True(ClientCompatibility.Supports([], [], "windows", "desktop"));
    }
}
