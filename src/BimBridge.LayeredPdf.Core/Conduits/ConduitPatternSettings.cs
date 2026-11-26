using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Xml.Serialization;

namespace BimBridge.LayeredPdf.Core.Conduits;

// Append new symbols; existing preset names and numeric values remain stable.
public enum ConduitSymbol
{
    RevitDefault = 0, Circle = 1, Triangle = 2, Square = 3, Diamond = 4,
    Hexagon = 5, Cross = 6, Plus = 7, DoubleSlash = 8, DoubleBar = 9, Star = 10,
    DownTriangle = 11, Chevron = 12, DoubleChevron = 13, Arrow = 14, Tee = 15,
    IBeam = 16, Hourglass = 17, BowTie = 18, Brackets = 19, Zigzag = 20
}
public enum MarkerPlacement { Inline, Beside }

public sealed class ConduitSizeRule
{
    public string Standard { get; set; } = string.Empty;
    public double NominalDiameterMm { get; set; }
    public ConduitSymbol Symbol { get; set; }
    public string Label { get; set; } = string.Empty;
}

[XmlRoot("ConduitPatternSettings")]
public sealed class ConduitPatternSettings
{
    public bool Enabled { get; set; }
    public MarkerPlacement Placement { get; set; } = MarkerPlacement.Inline;
    public double SymbolSizeMm { get; set; } = 2.4;
    public double TextSizePoints { get; set; } = 7.5;
    public double RepeatDistanceMm { get; set; } = 25;
    [XmlArrayItem("Rule")]
    public List<ConduitSizeRule> Rules { get; set; } = new();

    // Numeric nominal sizes, never display strings or outside diameters.
    public ConduitSizeRule? Match(string standard, double millimeters) => Rules.FirstOrDefault(r =>
        string.Equals(r.Standard, standard, StringComparison.OrdinalIgnoreCase) &&
        Math.Abs(r.NominalDiameterMm - millimeters) < 0.001);

    public ConduitPatternSettings Clone() => new()
    {
        Enabled = Enabled, Placement = Placement, SymbolSizeMm = SymbolSizeMm,
        TextSizePoints = TextSizePoints, RepeatDistanceMm = RepeatDistanceMm,
        Rules = Rules.Select(r => new ConduitSizeRule { Standard = r.Standard,
            NominalDiameterMm = r.NominalDiameterMm, Symbol = r.Symbol, Label = r.Label }).ToList(),
    };

    public void Validate()
    {
        Check(SymbolSizeMm, 1, 8, "Symbol size (mm)");
        Check(TextSizePoints, 5, 18, "Text size (pt)");
        Check(RepeatDistanceMm, 10, 150, "Repeat distance (mm)");
        if (!Enum.IsDefined(typeof(MarkerPlacement), Placement)) throw new ArgumentException("Unknown marker placement.");
        for (var i = 0; i < Rules.Count; i++)
        {
            var rule = Rules[i];
            Check(rule.NominalDiameterMm, .1, 1000, "Nominal size (mm)");
            if (string.IsNullOrWhiteSpace(rule.Standard)) throw new ArgumentException("A conduit standard is required for every row.");
            if (!Enum.IsDefined(typeof(ConduitSymbol), rule.Symbol)) throw new ArgumentException("Unknown conduit symbol.");
            if (rule.Label.Length > 24 || rule.Label.Any(char.IsControl)) throw new ArgumentException("Labels must be at most 24 printable characters.");
            if (Rules.Take(i).Any(r => string.Equals(r.Standard, rule.Standard, StringComparison.OrdinalIgnoreCase) &&
                Math.Abs(r.NominalDiameterMm - rule.NominalDiameterMm) < .001))
                throw new ArgumentException($"Duplicate size: {rule.Standard} {rule.NominalDiameterMm.ToString(CultureInfo.InvariantCulture)} mm.");
        }
    }

    private static void Check(double value, double min, double max, string name)
    {
        if (double.IsNaN(value) || double.IsInfinity(value) || value < min || value > max)
            throw new ArgumentException($"{name} must be between {min} and {max}.");
    }
}

public sealed class ConduitElementPattern
{
    public long ElementId { get; set; }
    public long LinkInstanceId { get; set; }
    public string SourceDocument { get; set; } = string.Empty;
    public string Standard { get; set; } = string.Empty;
    public double NominalDiameterMm { get; set; }
    public string DisplayDiameter { get; set; } = string.Empty;
    public bool HasMatchingRule { get; set; }
    public bool HasProjectedAxis { get; set; }
    public double StartX { get; set; }
    public double StartY { get; set; }
    public double EndX { get; set; }
    public double EndY { get; set; }
    [XmlIgnore]
    public string Identity => LinkInstanceId == 0 ? $"Host:{ElementId}" : $"Link:{LinkInstanceId}:{ElementId}";
    [XmlIgnore]
    public string Description => LinkInstanceId == 0 ? $"Element {ElementId}" : $"Link {LinkInstanceId}, Element {ElementId}";
    public ConduitSymbol Symbol { get; set; }
    public string Label { get; set; } = string.Empty;
}
