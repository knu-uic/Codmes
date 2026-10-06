using Xunit;

namespace Codmes.Windows;

public class AppLockPinTests
{
    [Fact]
    public void AcceptsOnlyFourASCIIDigits()
    {
        Assert.True(AppLockPin.IsValid("0123"));
        foreach (var invalid in new[] { "", "123", "12345", "１２３４", "1a34" }) Assert.False(AppLockPin.IsValid(invalid));
    }
    [Fact]
    public void HashesAreSaltedAndRejectWrongPIN()
    {
        var first = AppLockPin.Encode("0123");
        Assert.NotEqual(first, AppLockPin.Encode("0123"));
        Assert.True(AppLockPin.Verify("0123", first));
        Assert.False(AppLockPin.Verify("9999", first));
        Assert.False(AppLockPin.Verify("0123", "invalid"));
    }
}
