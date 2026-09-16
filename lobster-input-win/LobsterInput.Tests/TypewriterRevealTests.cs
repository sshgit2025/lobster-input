using System.Windows.Threading;
using LobsterInput.Helpers;
using Xunit;

namespace LobsterInput.Tests;

public sealed class TypewriterRevealTests
{
    [Fact]
    public void SetTargetClearsRenderedTextWhenTargetBecomesEmpty()
    {
        WpfTestHost.Run(() =>
        {
            var rendered = "stale";
            var reveal = new TypewriterReveal(Dispatcher.CurrentDispatcher, text => rendered = text);

            reveal.SetTarget("hello");
            reveal.Flush();
            Assert.Equal("hello", rendered);

            reveal.SetTarget("");

            Assert.Equal("", rendered);
        });
    }
}
