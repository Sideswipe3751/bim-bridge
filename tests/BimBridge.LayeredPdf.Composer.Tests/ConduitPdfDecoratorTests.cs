using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.IO;
using System.Text;

namespace BimBridge.LayeredPdf.Composer.Tests;

public sealed class ConduitPdfDecoratorTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "ConduitPdfTests", Guid.NewGuid().ToString("N"));
    public ConduitPdfDecoratorTests() => Directory.CreateDirectory(_directory);
    private const string DefaultLine = "/Element21 BMC\n0 0 1 RG\n2 w\n[5 3] 2 d\n20 240 m\n480 240 l\nS\nEMC\n";

    [Fact]
    public void AllTwentyPatterns_RenderDistinctGeometryAndPreserveNativeStroke()
    {
        var source = Source("all-patterns.pdf", "/Element27 BMC 0.2 0.4 0.7 RG 0.7 w [6 2] 3 d 20 160 m 480 160 l S EMC");
        var guide = Source("all-patterns-guide.pdf", "/Element27 BMC 20 160 m 480 160 l S EMC");
        var drawings = new HashSet<string>(StringComparer.Ordinal);
        foreach (var symbol in Enum.GetValues<ConduitSymbol>().Where(value => value != ConduitSymbol.RevitDefault))
        {
            var layer = Layer(guide); layer.Conduits[0].Symbol = symbol;
            var report = new List<string>();
            var result = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report);
            Assert.NotEqual(source, result);
            var content = Content(result);
            Assert.Contains("0.2 0.4 0.7 RG", content);
            Assert.Contains("0.2 0.4 0.7 rg", content);
            Assert.Contains("0.7 w", content);
            Assert.Contains("[6 2]3 d", content);
            Assert.Contains("20 160 m", content);
            Assert.Contains("480 160 l", content);
            Assert.Contains(report, line => line.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
            Assert.True(drawings.Add(content), $"Duplicate drawing for {symbol}");
        }
        Assert.Equal(20, drawings.Count);
    }

    [Theory]
    [InlineData(MarkerPlacement.Inline)]
    [InlineData(MarkerPlacement.Beside)]
    public void CustomMarker_PreservesOriginalPaintAndDefaultConduit(MarkerPlacement placement)
    {
        var raw = DefaultLine + "/Element27 BMC\n1 0 0 RG\n0.7 w\n[6 2] 3 d\n20 160 m\n480 160 l\nS\nEMC\n";
        var source = Source("original.pdf", raw);
        var guide = Source("guide.pdf", raw.Replace("[6 2] 3 d", "[] 0 d"));
        var layer = Layer(guide);
        var report = new List<string>();
        var path = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true, Placement = placement }, report);
        Assert.NotEqual(source, path);
        var content = Content(path);
        var original = Content(source);
        Assert.Equal(original[original.IndexOf("/Element21", StringComparison.Ordinal)..original.IndexOf("/Element27", StringComparison.Ordinal)],
            content[content.IndexOf("/Element21", StringComparison.Ordinal)..content.IndexOf("/Element27", StringComparison.Ordinal)]);
        Assert.Contains("[6 2]3 d", content);
        Assert.Contains("0.7 w", content);
        Assert.Contains("1 0 0 rg", content);
        Assert.Contains("20 160 m", content);
        Assert.Contains("480 160 l", content);
        Assert.Equal(placement == MarkerPlacement.Inline, content.Contains("W*", StringComparison.Ordinal));
        Assert.Contains(report, l => l.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void SolidGuide_LabelsManuallyDashedRevitStrokesWithoutReconstructingThem()
    {
        var raw = new StringBuilder("/Element27 BMC\n0.3 G\n0.5 w\n");
        for (var x = 20; x < 480; x += 8) raw.AppendLine($"{x} 160 m {x + 4} 160 l S");
        raw.AppendLine("EMC");
        var source = Source("manual.pdf", raw.ToString());
        var guide = Source("solid.pdf", "/Element27 BMC 0.3 G 0.5 w 20 160 m 480 160 l S EMC");
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, Layer(guide), new() { Enabled = true }, report);
        Assert.NotEqual(source, output);
        var content = Content(output);
        for (var x = 20; x < 480; x += 8) { Assert.Contains($"{x} 160 m", content); Assert.Contains($"{x + 4} 160 l", content); }
        Assert.Contains("0.3 g", content);
        Assert.Contains(report, l => l.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void UnsupportedDoubleLines_StayUnchangedAndAreReported()
    {
        var source = Source("double.pdf", "/Element27 BMC 20 160 m 480 160 l S 20 164 m 480 164 l S EMC");
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, Layer(source), new() { Enabled = true }, report);
        Assert.Equal(source, output);
        Assert.Contains(report, l => l.Contains("multiple projected edges", StringComparison.Ordinal));
    }

    [Fact]
    public void DisabledSettings_ReturnOriginalBytes()
    {
        var source = Source("off.pdf", DefaultLine);
        var before = File.ReadAllBytes(source);
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, Layer("missing-guide.pdf"), new(), new List<string>());
        Assert.Equal(source, output); Assert.Equal(before, File.ReadAllBytes(output));
    }

    [Fact]
    public void RevitDefaultRule_DoesNotRequireAnAuxiliaryExport()
    {
        var source = Source("default.pdf", DefaultLine);
        var layer = Layer("missing.pdf"); layer.Conduits[0].Symbol = ConduitSymbol.RevitDefault;
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, new List<string>()));
    }

    [Fact]
    public void NativeDashDot_ZeroLengthRoundCapDotsRemainSupported()
    {
        var source = Source("dots.pdf", "/Element27 BMC 1 J 0.7 w 20 160 m 200 160 l S 205 160 m 205 160 l S 210 160 m 480 160 l S EMC");
        var guide = Source("dots-guide.pdf", "/Element27 BMC 1 J 0.7 w 20 160 m 480 160 l S EMC");
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, Layer(guide), new() { Enabled = true }, report);
        Assert.NotEqual(source, output);
        Assert.Contains("205 160 m", Content(output));
        Assert.Contains("205 160 l", Content(output));
        Assert.Contains(report, line => line.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void ShortConduits_AreReportedWithoutInventingMarkers()
    {
        var source = Source("short.pdf", "/Element27 BMC 20 160 m 24 160 l S EMC");
        var report = new List<string>();
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, Layer(source), new() { Enabled = true }, report));
        Assert.Contains(report, l => l.Contains("too short", StringComparison.Ordinal));
    }

    [Fact]
    public void RotatedScaledAndClippedGeometry_RetainsClipAndInheritsCmykAlpha()
    {
        var raw = "q 0 2 -2 0 500 0 cm 0 0 200 200 re W n /GS1 gs /Element27 BMC 0.2 0.4 0 0 K 0.5 w 20 50 m 200 50 l S EMC Q";
        var source = Source("rotated.pdf", raw, true);
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, Layer(source), new() { Enabled = true }, report);
        Assert.NotEqual(source, output);
        var content = Content(output);
        Assert.Contains("0 2 -2 0 500 0 cm", content);
        Assert.Contains("0.2 0.4 0 0 k", content);
        using var pdf = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        var gs = pdf.Pages[0].Resources.Elements.GetDictionary("/ExtGState")!.Elements.GetDictionary("/LPConduitAlpha0")!;
        Assert.Equal(.4, gs.Elements.GetReal("/ca"), 6);
        Assert.Equal(.4, gs.Elements.GetReal("/CA"), 6);
    }

    [Fact]
    public void HostAndTwoLinkInstancesWithSameElementIdUseSeparateProjectedAxes()
    {
        var source = Source("linked.pdf", "/Element27 BMC 1 0 0 RG 20 240 m 480 240 l S EMC " +
            "/Element27 BMC 0 0 1 RG 20 160 m 480 160 l S EMC " +
            "/Element27 BMC 0 0.5 0 RG 300 20 m 300 120 l S EMC");
        var layer = Layer(source); layer.Conduits.Clear();
        layer.Conduits.Add(Projected(0, 20, 240, 480, 240));
        layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        layer.Conduits.Add(Projected(102, 300, 20, 300, 120));
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report);
        Assert.NotEqual(source, output);
        Assert.Contains(report, line => line.Contains("3/3 requested conduits marked", StringComparison.Ordinal));
        Assert.Contains(report, line => line.Contains("Link 101, Element 27: Triangle", StringComparison.Ordinal));
        Assert.Contains(report, line => line.Contains("Link 102, Element 27: Triangle", StringComparison.Ordinal));
        var content = Content(output);
        Assert.Contains("1 0 0 rg", content); Assert.Contains("0 0 1 rg", content); Assert.Contains("0 0.5 0 rg", content);
    }

    [Fact]
    public void DefaultLinkWithCollidingIdRetainsItsOriginalCommands()
    {
        var source = Source("default-link.pdf", "/Element27 BMC 20 240 m 480 240 l S EMC /Element27 BMC 20 160 m 480 160 l S EMC");
        var layer = Layer(source); layer.Conduits.Clear();
        layer.Conduits.Add(Projected(0, 20, 240, 480, 240));
        var linked = Projected(101, 20, 160, 480, 160); linked.Symbol = ConduitSymbol.RevitDefault; layer.Conduits.Add(linked);
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report);
        var before = Content(source); var after = Content(output);
        Assert.Equal(before[before.LastIndexOf("/Element27", StringComparison.Ordinal)..], after[after.LastIndexOf("/Element27", StringComparison.Ordinal)..]);
        Assert.Contains(report, l => l.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void OverlappingHostAndLinkWithSameIdRemainUnchangedInsteadOfGuessing()
    {
        var source = Source("ambiguous-link.pdf", "/Element27 BMC 20 160 m 480 160 l S EMC");
        var layer = Layer(source); layer.Conduits.Clear();
        layer.Conduits.Add(Projected(0, 20, 160, 480, 160));
        layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        var report = new List<string>();
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report));
        Assert.Contains(report, line => line.Contains("ambiguous overlapping", StringComparison.Ordinal));
        Assert.Contains(report, line => line.Contains("0/2 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void DuplicateLinkStrokesReceiveOnlyOneSetOfMarkers()
    {
        const string line = "/Element27 BMC 20 160 m 480 160 l S EMC ";
        var single = Source("single-link.pdf", line);
        var duplicate = Source("duplicate-link.pdf", line + line);
        var layer = Layer(single); layer.Conduits.Clear(); layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        var oneReport = new List<string>(); var duplicateReport = new List<string>();
        ConduitPdfDecorator.CreateDecoratedCopy(single, layer, new() { Enabled = true }, oneReport);
        layer.ConduitGuidePdfPath = duplicate;
        ConduitPdfDecorator.CreateDecoratedCopy(duplicate, layer, new() { Enabled = true }, duplicateReport);
        Assert.Equal(oneReport.Last(), duplicateReport.Last());
    }

    [Fact]
    public void LinkedConduitWithoutSupportedProjectionCannotMatchHostTags()
    {
        var source = Source("unsupported-link.pdf", "/Element27 BMC 20 160 m 480 160 l S EMC");
        var layer = Layer(source); layer.Conduits[0].LinkInstanceId = 101;
        var report = new List<string>();
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report));
        Assert.Contains(report, line => line.Contains("unsupported linked conduit projection", StringComparison.Ordinal));
    }

    [Fact]
    public void DashedLinkedConduitUsesSolidGuideWhilePreservingItsDashStrokes()
    {
        var commands = new StringBuilder("/Element27 BMC 0 0 1 RG 0.5 w ");
        for (var x = 20; x < 480; x += 8) commands.Append($"{x} 160 m {x + 4} 160 l S ");
        commands.Append("EMC");
        var source = Source("linked-dashes.pdf", commands.ToString());
        var guide = Source("linked-guide.pdf", "/Element27 BMC 20 160 m 480 160 l S EMC");
        var layer = Layer(guide); layer.Conduits.Clear(); layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        var report = new List<string>();
        var result = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report);
        Assert.NotEqual(source, result);
        var content = Content(result);
        for (var x = 20; x < 480; x += 8) { Assert.Contains($"{x} 160 m", content); Assert.Contains($"{x + 4} 160 l", content); }
        Assert.Contains("0 0 1 rg", content);
        Assert.Contains(report, line => line.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void RoundedSheetProjectionAndSmallConnectionExtensionStillMatchLinkedConduit()
    {
        var source = Source("rounded-projection.pdf", "/Element27 BMC 0 0 1 RG 1.4 w 16.3 160.33 m 480 160.33 l S EMC");
        var layer = Layer(source); layer.Conduits.Clear(); layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        var report = new List<string>();
        var output = ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report);
        Assert.NotEqual(source, output);
        Assert.Contains("16.3 160.33 m", Content(output));
        Assert.Contains("1.4 w", Content(output));
        Assert.Contains(report, line => line.Contains("1/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("20 161 m 480 161 l")]
    [InlineData("14 160 m 480 160 l")]
    [InlineData("15 160 m 19 160 l")]
    public void ProjectionAllowanceDoesNotAcceptOffsetOrExcessiveExtensionOrDisjointLine(string path)
    {
        var source = Source("outside-projection.pdf", $"/Element27 BMC {path} S EMC");
        var layer = Layer(source); layer.Conduits.Clear(); layer.Conduits.Add(Projected(101, 20, 160, 480, 160));
        var report = new List<string>();
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report));
        Assert.Contains(report, line => line.Contains("0/1 requested conduits marked", StringComparison.Ordinal));
    }

    [Fact]
    public void NearCoincidentHostAndLinkWithSameIdStillRemainUnchanged()
    {
        var source = Source("near-ambiguous.pdf", "/Element27 BMC 20 160.2 m 480 160.2 l S EMC");
        var layer = Layer(source); layer.Conduits.Clear();
        layer.Conduits.Add(Projected(0, 20, 160, 480, 160));
        layer.Conduits.Add(Projected(101, 20, 160.4, 480, 160.4));
        var report = new List<string>();
        Assert.Equal(source, ConduitPdfDecorator.CreateDecoratedCopy(source, layer, new() { Enabled = true }, report));
        Assert.Contains(report, line => line.Contains("ambiguous overlapping", StringComparison.Ordinal));
    }

    private static ConduitElementPattern Projected(long linkId, double x1, double y1, double x2, double y2) => new()
    {
        ElementId = 27, LinkInstanceId = linkId, Symbol = ConduitSymbol.Triangle, Label = "27", HasProjectedAxis = true,
        StartX = x1 / 500, StartY = y1 / 300, EndX = x2 / 500, EndY = y2 / 300
    };

    private static PdfLayerJob Layer(string guide) => new()
    {
        Name = "View A",
        ConduitGuidePdfPath = guide,
        Conduits = { new() { ElementId = 27, Symbol = ConduitSymbol.Triangle, Label = "27" } }
    };
    private string Source(string name, string commands, bool alpha = false)
    {
        var path = Path.Combine(_directory, name);
        using var pdf = new PdfDocument(); var page = pdf.AddPage(); page.Width = PdfSharp.Drawing.XUnit.FromPoint(500); page.Height = PdfSharp.Drawing.XUnit.FromPoint(300);
        if (alpha)
        {
            var dict = new PdfDictionary(pdf); var gs = new PdfDictionary(pdf); gs.Elements.SetReal("/CA", .4);
            dict.Elements["/GS1"] = gs; page.Resources.Elements["/ExtGState"] = dict;
        }
        page.Contents.ReplaceContent(ContentReader.ReadContent(Encoding.ASCII.GetBytes(commands))); pdf.Save(path); return path;
    }
    private static string Content(string path)
    {
        using var pdf = PdfReader.Open(path, PdfDocumentOpenMode.Import);
        var sequence = ContentReader.ReadContent(pdf.Pages[0]);
        return Encoding.ASCII.GetString(sequence.ToContent());
    }
    public void Dispose() => Directory.Delete(_directory, true);
}
