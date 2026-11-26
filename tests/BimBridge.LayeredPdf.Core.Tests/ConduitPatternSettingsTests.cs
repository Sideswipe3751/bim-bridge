using BimBridge.LayeredPdf.Core.Conduits;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class ConduitPatternSettingsTests
{
    [Fact]
    public void TwentyPatterns_PreserveLegacyIdsAndRoundTripEveryChoice()
    {
        var legacy = new[] { "RevitDefault", "Circle", "Triangle", "Square", "Diamond", "Hexagon", "Cross", "Plus", "DoubleSlash", "DoubleBar", "Star" };
        for (var i = 0; i < legacy.Length; i++) Assert.Equal(legacy[i], ((ConduitSymbol)i).ToString());
        var symbols = Enum.GetValues<ConduitSymbol>();
        Assert.Equal(21, symbols.Length); // Twenty custom patterns plus Revit default.
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".xml");
        try
        {
            var settings = new ConduitPatternSettings { Enabled = true };
            foreach (var symbol in symbols)
                settings.Rules.Add(new() { Standard = "EMT", NominalDiameterMm = 21 + (int)symbol, Symbol = symbol, Label = "27" });
            ConduitProfileSerializer.Write(file, settings);
            var restored = ConduitProfileSerializer.Read(file);
            Assert.Equal(symbols, restored.Rules.Select(rule => rule.Symbol));
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public void Match_UsesNominalSizeAndStandardWithoutReassigningMissingSizes()
    {
        var settings = new ConduitPatternSettings
        {
            Enabled = true,
            Rules =
        {
            new() { Standard = "EMT", NominalDiameterMm = 21, Symbol = ConduitSymbol.RevitDefault },
            new() { Standard = "EMT", NominalDiameterMm = 27, Symbol = ConduitSymbol.Triangle, Label = "27" },
            new() { Standard = "RNC", NominalDiameterMm = 27, Symbol = ConduitSymbol.Square, Label = "27" },
        }
        };
        settings.Validate();
        Assert.Equal(ConduitSymbol.RevitDefault, settings.Match("EMT", 21)!.Symbol);
        Assert.Equal(ConduitSymbol.Triangle, settings.Match("emt", 27.00000004)!.Symbol);
        Assert.Equal(ConduitSymbol.Square, settings.Match("RNC", 27)!.Symbol);
        Assert.Null(settings.Match("EMT", 32));
        Assert.Null(settings.Match("IMC", 27));
        var clone = settings.Clone(); clone.Rules[1].Symbol = ConduitSymbol.Star;
        Assert.Equal(ConduitSymbol.Triangle, settings.Match("EMT", 27)!.Symbol);
    }

    [Fact]
    public void PresetRoundTrip_KeepsDefaultAndUnicodeLabel()
    {
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".xml");
        try
        {
            var settings = new ConduitPatternSettings
            {
                Enabled = true,
                Placement = MarkerPlacement.Beside,
                Rules =
            {
                new() { Standard = "EMT", NominalDiameterMm = 21 },
                new() { Standard = "EMT", NominalDiameterMm = 27, Symbol = ConduitSymbol.Triangle, Label = "¾″" },
            }
            };
            ConduitProfileSerializer.Write(file, settings);
            settings.RepeatDistanceMm = 30;
            ConduitProfileSerializer.Write(file, settings);
            var loaded = ConduitProfileSerializer.Read(file);
            Assert.True(loaded.Enabled);
            Assert.Equal(30, loaded.RepeatDistanceMm);
            Assert.Equal(MarkerPlacement.Beside, loaded.Placement);
            Assert.Equal(ConduitSymbol.RevitDefault, loaded.Match("EMT", 21)!.Symbol);
            Assert.Equal("¾″", loaded.Match("EMT", 27)!.Label);
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public void InvalidPreset_RejectsAmbiguousDuplicatesAndNonfiniteDimensions()
    {
        var settings = new ConduitPatternSettings { SymbolSizeMm = double.NaN };
        Assert.Throws<ArgumentException>(() => settings.Validate());
        settings.SymbolSizeMm = 2.4;
        settings.Rules.Add(new() { Standard = "EMT", NominalDiameterMm = 27 });
        settings.Rules.Add(new() { Standard = "emt", NominalDiameterMm = 27.0000001 });
        Assert.Throws<ArgumentException>(() => settings.Validate());
    }
}
