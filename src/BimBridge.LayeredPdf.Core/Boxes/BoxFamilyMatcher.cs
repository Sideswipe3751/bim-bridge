using System;

namespace BimBridge.LayeredPdf.Core.Boxes;

public static class BoxFamilyMatcher
{
    public static bool Matches(bool isConduitFitting, string? familyName) => isConduitFitting &&
        !string.IsNullOrWhiteSpace(familyName) && familyName!.IndexOf("box", StringComparison.OrdinalIgnoreCase) >= 0;
}
