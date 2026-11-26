using System.Text;
using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.IO;

namespace BimBridge.LayeredPdf.Composer.Tests;

public sealed class BoxLayerTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "BoxLayerTests", Guid.NewGuid().ToString("N"));
    private const string Raw = "q 2 0 0 2 0 0 cm /Element10 BMC 0 0 1 RG 1.4 w [5 2] 1 d 10 30 m 180 30 l S EMC " +
        "/Element20 BMC 0.2 0.4 0.6 rg 30 40 12 10 re B EMC " +
        "/Element21 BMC 40 60 8 6 re S EMC Q " +
        "/Element99 BMC 1 0 0 rg 200 200 30 30 re f EMC";
    public BoxLayerTests() => Directory.CreateDirectory(_directory);

    [Fact]
    public void BoxLayerDuplicatesPaintInSameGroupWithoutConduitMarkersOrModelChanges()
    {
        var job = Job(Raw); var sourceBytes = File.ReadAllBytes(job.Layers[0].SourcePdfPath);
        LayeredPdfComposer.Compose(job);
        using var pdf = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import);
        var groups = pdf.Internals.Catalog.Elements.GetDictionary("/OCProperties")!;
        var all = groups.Elements.GetArray("/OCGs")!;
        Assert.Equal(new[] { "Sheet Base", "L1 P2L1S1", "L1 P2L1S1 BOX" }, all.Elements.Cast<PdfReference>().Select(r => ((PdfDictionary)r.Value).Elements.GetString("/Name")));
        var group = Assert.IsType<PdfArray>(groups.Elements.GetDictionary("/D")!.Elements.GetArray("/Order")!.Elements[1]);
        Assert.Equal("Electrical", Assert.IsType<PdfString>(group.Elements[0]).Value);
        Assert.Equal(all.Elements[1], group.Elements[1]); Assert.Equal(all.Elements[2], group.Elements[2]);
        var forms = Forms(pdf);
        Assert.Equal(Content(job.Layers[0].SourcePdfPath).Trim(), forms[1].Trim());
        Assert.Contains("10 30 m\n180 30 l\nn", forms[2]); // conduit not painted in BOX
        Assert.Contains("200 200 30 30 re\nn", forms[2]); // title block not painted
        Assert.Contains("30 40 12 10 re\nB", forms[2]);
        Assert.Contains("40 60 8 6 re\nS", forms[2]);
        Assert.Contains("0.2 0.4 0.6 rg", forms[2]); Assert.Contains("1.4 w", forms[2]); Assert.Contains("[5 2]1 d", forms[2]);
        Assert.Equal(sourceBytes, File.ReadAllBytes(job.Layers[0].SourcePdfPath));
        Assert.Contains("copied 2 printed box element IDs", File.ReadAllText(job.BoxReportPath));
        Assert.Empty(Directory.GetFiles(_directory, "*.boxes-*.pdf"));
    }

    [Theory]
    [InlineData(false, true, true)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    public void DisabledOrMissingPrintedConduitOrBoxesNeverAddsEmptyLayer(bool enabled, bool conduit, bool box)
    {
        var job = Job((conduit ? "/Element10 BMC 10 10 m 100 10 l S EMC " : "") +
            (box ? "/Element20 BMC 20 20 10 10 re S EMC" : ""));
        job.CreateBoxLayers = enabled;
        LayeredPdfComposer.Compose(job);
        using var pdf = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import);
        Assert.Equal(2, pdf.Internals.Catalog.Elements.GetDictionary("/OCProperties")!.Elements.GetArray("/OCGs")!.Elements.Count);
        Assert.Equal(enabled, File.Exists(job.BoxReportPath));
    }

    [Fact]
    public void UnassignedAndDuplicateViewNamesKeepMatchingGroupAndUniqueBoxName()
    {
        var job = Job(Raw); job.Layers[0].GroupName = "";
        job.Layers.Add(new() { Name = "L1 P2L1S1 BOX", SourcePdfPath = job.Layers[0].SourcePdfPath });
        LayeredPdfComposer.Compose(job);
        using var pdf = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import);
        var groups = pdf.Internals.Catalog.Elements.GetDictionary("/OCProperties")!;
        var names = groups.Elements.GetArray("/OCGs")!.Elements.Cast<PdfReference>().Select(r => ((PdfDictionary)r.Value).Elements.GetString("/Name")).ToList();
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.Equal("L1 P2L1S1 BOX", names[2]);
        Assert.Equal("L1 P2L1S1 BOX (2)", names[3]);
        Assert.All(groups.Elements.GetDictionary("/D")!.Elements.GetArray("/Order")!.Elements, e => Assert.IsType<PdfReference>(e));
    }

    [Fact]
    public void CollisionAndNestedNonBoxCannotIntroduceNonBoxPainting()
    {
        var job = Job("/Element10 BMC 10 10 m 100 10 l S EMC /Element20 BMC 20 20 10 10 re S EMC " +
            "/Element21 BMC 60 60 10 10 re f EMC /Element30 BMC /Element20 BMC 80 80 10 10 re f EMC EMC");
        job.Layers[0].AmbiguousBoxElementIds.Add(21);
        LayeredPdfComposer.Compose(job);
        using var pdf = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import);
        var box = Forms(pdf)[2];
        Assert.Contains("20 20 10 10 re\nS", box);
        Assert.Contains("60 60 10 10 re\nn", box);
        Assert.Contains("80 80 10 10 re\nn", box);
        Assert.Contains("ambiguous host/link element IDs: 21", File.ReadAllText(job.BoxReportPath));
    }

    [Fact]
    public void SharedClippingAndTextStateSurviveFilteringAndBrokenSourceKeepsPreviousOutput()
    {
        var job = Job("q 0 0 200 200 re W n /Element10 BMC 10 10 m 100 10 l S EMC " +
            "/Element99 BMC BT /F1 10 Tf 10 50 Td (Hidden) Tj EMC /Element20 BMC (Box) Tj ET 20 20 10 10 re S EMC Q");
        LayeredPdfComposer.Compose(job);
        using (var pdf = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import))
        {
            var box = Forms(pdf)[2];
            Assert.Contains("0 0 200 200 re\nW\nn", box);
            Assert.Contains("3 Tr\n(Hidden)Tj\nQ", box);
            Assert.Contains("(Box)Tj", box);
        }
        var before = File.ReadAllBytes(job.OutputPath);
        job.Layers[0].SourcePdfPath = Source("broken.pdf", "q /Element10 BMC 10 10 m 100 10 l S EMC /Element20 BMC 20 20 10 10 re S EMC");
        Assert.Throws<InvalidDataException>(() => LayeredPdfComposer.Compose(job));
        Assert.Equal(before, File.ReadAllBytes(job.OutputPath));
    }

    private LayeredPdfJob Job(string commands) => new()
    {
        OutputPath = Path.Combine(_directory, "result.pdf"), BasePdfPath = Source("base.pdf", ""),
        CreateBoxLayers = true, BoxReportPath = Path.Combine(_directory, "result.pdf.boxes.txt"),
        Layers = { new() { Name = "L1 P2L1S1", BoxLayerName = "L1 P2L1S1 BOX", GroupName = "Electrical",
            SourcePdfPath = Source("source.pdf", commands), BoxConduitElementIds = { 10 }, BoxElementIds = { 20, 21 } } }
    };
    private string Source(string name, string commands)
    {
        var path = Path.Combine(_directory, name);
        using var pdf = new PdfDocument(); var page = pdf.AddPage(); page.Width = XUnit.FromPoint(500); page.Height = XUnit.FromPoint(300);
        var font = new PdfDictionary(pdf); font.Elements.SetName("/Type", "/Font"); font.Elements.SetName("/Subtype", "/Type1"); font.Elements.SetName("/BaseFont", "/Helvetica");
        var fonts = new PdfDictionary(pdf); fonts.Elements["/F1"] = font; page.Resources.Elements["/Font"] = fonts;
        page.Contents.ReplaceContent(ContentReader.ReadContent(Encoding.ASCII.GetBytes(commands))); pdf.Save(path); return path;
    }
    private static string Content(string path)
    {
        using var pdf = PdfReader.Open(path, PdfDocumentOpenMode.Import);
        return Encoding.ASCII.GetString(ContentReader.ReadContent(pdf.Pages[0]).ToContent());
    }
    private static List<string> Forms(PdfDocument pdf) => pdf.Pages[0].Resources.Elements.GetDictionary("/XObject")!.Elements.Values
        .Cast<PdfReference>().Select(r => Encoding.ASCII.GetString(((PdfDictionary)r.Value).Stream.UnfilteredValue)).ToList();
    public void Dispose() => Directory.Delete(_directory, recursive: true);
}
