using System.Text;
using Xunit;

namespace Codmes.Windows;

public class GoogleDesktopSignInTests
{
    [Fact]
    public void ServerCannotSelectAnotherPublisher()
    {
        GoogleDesktopSignIn.ValidatePublisher("publisher.apps.googleusercontent.com", "publisher.apps.googleusercontent.com");
        Assert.Throws<InvalidOperationException>(() => GoogleDesktopSignIn.ValidatePublisher("publisher.apps.googleusercontent.com", "other.apps.googleusercontent.com"));
        Assert.Throws<InvalidOperationException>(() => GoogleDesktopSignIn.ValidatePublisher("", ""));
    }

    [Fact]
    public void TokenMustMatchPublisherAndLoginAttempt()
    {
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"aud\":\"publisher\",\"nonce\":\"attempt\"}"))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var token = $"header.{payload}.signature";
        GoogleDesktopSignIn.ValidateTokenBinding(token, "publisher", "attempt");
        Assert.Throws<InvalidOperationException>(() => GoogleDesktopSignIn.ValidateTokenBinding(token, "other", "attempt"));
        Assert.Throws<InvalidOperationException>(() => GoogleDesktopSignIn.ValidateTokenBinding(token, "publisher", "other"));
        Assert.Throws<InvalidOperationException>(() => GoogleDesktopSignIn.ValidateTokenBinding("invalid", "publisher", "attempt"));
    }
}
