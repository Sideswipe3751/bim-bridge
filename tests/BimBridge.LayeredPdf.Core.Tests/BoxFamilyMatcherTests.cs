using BimBridge.LayeredPdf.Core.Boxes;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class BoxFamilyMatcherTests
{
    [Theory]
    [InlineData(true, "Junction Box", true)]
    [InlineData(true, "JB_pull box", true)]
    [InlineData(true, "PULL BOX - Custom", true)]
    [InlineData(true, "RoundBoX_WithCover", true)]
    [InlineData(true, "Conduit Elbow", false)]
    [InlineData(false, "Junction Box", false)]
    [InlineData(true, null, false)]
    public void OnlyConduitFittingFamiliesContainingBoxQualify(bool isFitting, string? family, bool expected)
        => Assert.Equal(expected, BoxFamilyMatcher.Matches(isFitting, family));
}
