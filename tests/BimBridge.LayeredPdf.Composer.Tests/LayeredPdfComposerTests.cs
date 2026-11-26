using BimBridge.LayeredPdf.Core.Jobs;
using BimBridge.LayeredPdf.Core.Conduits;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace BimBridge.LayeredPdf.Composer.Tests;

public sealed class LayeredPdfComposerTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "LayeredPdfTests", Guid.NewGuid().ToString("N"));

    public LayeredPdfComposerTests()
    {
        Directory.CreateDirectory(_directory);
    }

    [Fact]
    public void Compose_CreatesOptionalContentGroupsForBaseAndViewportLayers()
    {
        var basePdf = CreateSource("base.pdf", XColors.Black, "SHEET BASE", new XRect(20, 20, 572, 752));
        var leftPdf = CreateSource("left.pdf", XColors.Red, "VIEW A", new XRect(60, 100, 200, 300));
        var rightPdf = CreateSource("right.pdf", XColors.Blue, "VIEW B", new XRect(340, 250, 200, 300));
        var output = Path.Combine(_directory, "layered.pdf");
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf,
            OutputPath = output,
            Layers =
            {
                new PdfLayerJob
                {
                    GroupName = "A101 - Architectural",
                    Name = "01 - View A",
                    SourcePdfPath = leftPdf,
                    ClipLeft = 0.05,
                    ClipBottom = 0.05,
                    ClipRight = 0.5,
                    ClipTop = 0.95,
                    HasLabelClip = true,
                    LabelClipLeft = 0.05,
                    LabelClipBottom = 0.01,
                    LabelClipRight = 0.3,
                    LabelClipTop = 0.04,
                },
                new PdfLayerJob
                {
                    GroupName = "M101 - Mechanical",
                    Name = "02 - View B",
                    SourcePdfPath = rightPdf,
                    ClipLeft = 0.5,
                    ClipBottom = 0.05,
                    ClipRight = 0.95,
                    ClipTop = 0.95,
                },
            },
        };

        LayeredPdfComposer.Compose(job);

        Assert.True(File.Exists(output));
        using var document = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        Assert.Single(document.Pages);
        var optionalContent = document.Internals.Catalog.Elements.GetDictionary("/OCProperties");
        Assert.NotNull(optionalContent);
        var groups = optionalContent!.Elements.GetArray("/OCGs");
        Assert.NotNull(groups);
        Assert.Equal(3, groups!.Elements.Count);
        var names = groups
            .Select(item => ((PdfSharp.Pdf.Advanced.PdfReference)item).Value)
            .Cast<PdfDictionary>()
            .Select(dictionary => dictionary.Elements.GetString("/Name"))
            .ToArray();
        Assert.Equal(new[] { "Sheet Base", "01 - View A", "02 - View B" }, names);

        var order = optionalContent.Elements.GetDictionary("/D")!.Elements.GetArray("/Order");
        Assert.NotNull(order);
        Assert.Equal(3, order!.Elements.Count);
        Assert.IsType<PdfReference>(order.Elements[0]);
        var architecturalGroup = Assert.IsType<PdfArray>(order.Elements[1]);
        Assert.Equal("A101 - Architectural", Assert.IsType<PdfString>(architecturalGroup.Elements[0]).Value);
        Assert.IsType<PdfReference>(architecturalGroup.Elements[1]);
        var mechanicalGroup = Assert.IsType<PdfArray>(order.Elements[2]);
        Assert.Equal("M101 - Mechanical", Assert.IsType<PdfString>(mechanicalGroup.Elements[0]).Value);

        var properties = document.Pages[0].Resources.Elements.GetDictionary("/Properties");
        Assert.NotNull(properties);
        Assert.Equal(3, properties!.Elements.Count);
        Assert.True(properties.Elements.ContainsKey("/L1"));
        Assert.True(properties.Elements.ContainsKey("/L2"));
        Assert.True(properties.Elements.ContainsKey("/L3"));

        var contents = document.Pages[0].Contents.Elements
            .Select(item => ((PdfReference)item).Value)
            .Cast<PdfContent>()
            .ToArray();
        Assert.Equal(3, contents.Length);
        for (var index = 0; index < contents.Length; index++)
        {
            var bytes = contents[index].Stream?.UnfilteredValue ?? Array.Empty<byte>();
            var text = System.Text.Encoding.ASCII.GetString(bytes);
            Assert.StartsWith($"/OC /L{index + 1} BDC\n", text);
            Assert.EndsWith("\nEMC\n", text);
        }
    }

    [Fact]
    public void Compose_SupportsMoreThanTenViewportLayers()
    {
        var basePdf = CreateSource("many-base.pdf", XColors.Black, "BASE", new XRect(10, 10, 592, 772));
        var output = Path.Combine(_directory, "many-layered.pdf");
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf,
            OutputPath = output,
        };
        for (var index = 1; index <= 12; index++)
        {
            var source = CreateSource(
                $"source-{index:00}.pdf",
                XColors.DarkBlue,
                $"VIEW {index:00}",
                new XRect(20 + index, 30 + index, 120, 160));
            job.Layers.Add(new PdfLayerJob
            {
                GroupName = index <= 6 ? "A101 - Architectural" : "M101 - Mechanical",
                Name = $"{index:00} - View",
                SourcePdfPath = source,
                ClipLeft = 0.02,
                ClipBottom = 0.02,
                ClipRight = 0.8,
                ClipTop = 0.9,
                HasLabelClip = true,
                LabelClipLeft = 0.1,
                LabelClipBottom = 0.01,
                LabelClipRight = 0.25,
                LabelClipTop = 0.03,
            });
        }

        LayeredPdfComposer.Compose(job);

        using var document = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        var optionalContent = document.Internals.Catalog.Elements.GetDictionary("/OCProperties");
        Assert.NotNull(optionalContent);
        Assert.Equal(13, optionalContent!.Elements.GetArray("/OCGs")!.Elements.Count);
        var properties = document.Pages[0].Resources.Elements.GetDictionary("/Properties");
        Assert.NotNull(properties);
        Assert.Equal(13, properties!.Elements.Count);
        Assert.True(properties.Elements.ContainsKey("/L10"));
        Assert.True(properties.Elements.ContainsKey("/L13"));
        Assert.Equal(13, document.Pages[0].Contents.Elements.Count);

        var order = optionalContent.Elements.GetDictionary("/D")!.Elements.GetArray("/Order");
        Assert.NotNull(order);
        Assert.Equal(3, order!.Elements.Count);
        Assert.Equal(7, Assert.IsType<PdfArray>(order.Elements[1]).Elements.Count);
        Assert.Equal(7, Assert.IsType<PdfArray>(order.Elements[2]).Elements.Count);
    }

    [Fact]
    public void Compose_RejectsAViewportSourceWithDifferentPaperSize()
    {
        var basePdf = CreateSource("size-base.pdf", XColors.Black, "BASE", new XRect(10, 10, 100, 100));
        var differentSizePdf = CreateSource(
            "different-size.pdf",
            XColors.Red,
            "VIEW",
            new XRect(10, 10, 100, 100),
            width: 792,
            height: 612);
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf,
            OutputPath = Path.Combine(_directory, "size-mismatch.pdf"),
            Layers =
            {
                new PdfLayerJob
                {
                    Name = "A201 - View",
                    SourcePdfPath = differentSizePdf,
                    ClipLeft = 0.1,
                    ClipBottom = 0.1,
                    ClipRight = 0.9,
                    ClipTop = 0.9,
                },
            },
        };

        var exception = Assert.Throws<InvalidDataException>(() => LayeredPdfComposer.Compose(job));

        Assert.Contains("All selected sheets must use the same paper size and orientation", exception.Message);
    }

    [Fact]
    public void Compose_RemovesTaggedRevitTitleBlockElementFromViewportLayer()
    {
        var basePdf = CreateSource("tag-base.pdf", XColors.Black, "BASE", new XRect(10, 10, 100, 100));
        var taggedPdf = CreateTaggedSource("tagged-source.pdf");
        var output = Path.Combine(_directory, "tagged-layered.pdf");
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf,
            OutputPath = output,
            Layers =
            {
                new PdfLayerJob
                {
                    Name = "A101 - View",
                    SourcePdfPath = taggedPdf,
                    ExcludedElementIds = { 123 },
                    ClipLeft = 0.01,
                    ClipBottom = 0.01,
                    ClipRight = 0.99,
                    ClipTop = 0.99,
                },
            },
        };

        LayeredPdfComposer.Compose(job);

        using var document = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        var xObjects = document.Pages[0].Resources.Elements.GetDictionary("/XObject");
        Assert.NotNull(xObjects);
        var formStreams = new List<string>();
        foreach (var item in xObjects!.Elements.Values)
        {
            var reference = Assert.IsType<PdfReference>(item);
            var form = Assert.IsType<PdfDictionary>(reference.Value);
            Assert.NotNull(form.Stream);
            formStreams.Add(System.Text.Encoding.ASCII.GetString(form.Stream!.UnfilteredValue));
        }

        Assert.DoesNotContain(formStreams, content => content.Contains("/Element123", StringComparison.Ordinal));
        Assert.Contains(formStreams, content => content.Contains("/Element456", StringComparison.Ordinal));
        Assert.False(File.Exists(taggedPdf + ".stripped.pdf"));
    }

    [Fact]
    public void Compose_ConduitMarkersStayInsideViewportOcgAndFailedGuideKeepsExistingOutput()
    {
        var basePdf = CreateSource("conduit-base.pdf", XColors.Black, "BASE", new XRect(10, 10, 100, 100));
        var source = Path.Combine(_directory, "conduit-source.pdf");
        using (var document = new PdfDocument())
        {
            var page = document.AddPage(); page.Width = XUnit.FromPoint(612); page.Height = XUnit.FromPoint(792);
            page.Contents.ReplaceContent(PdfSharp.Pdf.Content.ContentReader.ReadContent(System.Text.Encoding.ASCII.GetBytes(
                "/Element27 BMC 1 0 0 RG 0.5 w [6 3] 2 d 40 300 m 550 300 l S EMC")));
            document.Save(source);
        }
        var output = Path.Combine(_directory, "conduits.pdf");
        var report = output + ".conduits.txt";
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf, OutputPath = output, ConduitReportPath = report,
            ConduitPatterns = new() { Enabled = true },
            Layers = { new() { Name = "Conduit view", SourcePdfPath = source, ConduitGuidePdfPath = source,
                Conduits = { new() { ElementId = 27, Symbol = ConduitSymbol.Triangle, Label = "27" } } } },
        };
        LayeredPdfComposer.Compose(job);
        using (var result = PdfReader.Open(output, PdfDocumentOpenMode.Import))
        {
            Assert.Equal(2, result.Internals.Catalog.Elements.GetDictionary("/OCProperties")!.Elements.GetArray("/OCGs")!.Elements.Count);
            Assert.Equal(2, result.Pages[0].Contents.Elements.Count);
            var forms = result.Pages[0].Resources.Elements.GetDictionary("/XObject")!.Elements.Values
                .Cast<PdfReference>().Select(r => (PdfDictionary)r.Value).ToArray();
            Assert.Contains(forms, f => System.Text.Encoding.ASCII.GetString(f.Stream!.UnfilteredValue).Contains("LPConduitAlpha", StringComparison.Ordinal));
        }
        Assert.Contains("1/1 requested conduits marked", File.ReadAllText(report));
        Assert.False(File.Exists(source + ".conduits.pdf"));
        var before = File.ReadAllBytes(output);
        job.Layers[0].ConduitGuidePdfPath = Path.Combine(_directory, "missing.pdf");
        Assert.Throws<InvalidDataException>(() => LayeredPdfComposer.Compose(job));
        Assert.Equal(before, File.ReadAllBytes(output));
    }

    [Fact]
    public void Compose_TitleBlockPaintingIsRemovedWithoutLosingSharedGraphicsAndTextState()
    {
        var basePdf = CreateSource("shared-base.pdf", XColors.Black, "BASE", new XRect(10, 10, 100, 100));
        var source = Path.Combine(_directory, "shared-state.pdf");
        using (var document = new PdfDocument())
        {
            var page = document.AddPage(); page.Width = XUnit.FromPoint(612); page.Height = XUnit.FromPoint(792);
            var font = new PdfDictionary(document);
            font.Elements.SetName("/Type", "/Font"); font.Elements.SetName("/Subtype", "/Type1"); font.Elements.SetName("/BaseFont", "/Helvetica");
            var fonts = new PdfDictionary(document); fonts.Elements["/F1"] = font; page.Resources.Elements["/Font"] = fonts;
            // Revit can close a viewport's graphics state inside the title block, and
            // begin text/state used by the following element before the title block ends.
            var raw = "q 2 0 0 2 0 0 cm /Element27 BMC 0 0 1 RG 20 100 m 250 100 l S EMC " +
                "/Element123 BMC Q 1 0 0 RG 10 10 30 30 re f q 1 0 0 1 10 20 cm " +
                "BT /F1 10 Tf 30 40 Td /Nested BMC (Hidden title) Tj EMC EMC " +
                "/Element456 BMC (Visible suffix) Tj ET 0.4 w [6 3] 2 d 20 300 m 550 300 l S EMC Q";
            page.Contents.ReplaceContent(PdfSharp.Pdf.Content.ContentReader.ReadContent(System.Text.Encoding.ASCII.GetBytes(raw)));
            document.Save(source);
        }
        var output = Path.Combine(_directory, "shared-result.pdf");
        var report = output + ".conduits.txt";
        var job = new LayeredPdfJob
        {
            BasePdfPath = basePdf, OutputPath = output, ConduitReportPath = report,
            ConduitPatterns = new() { Enabled = true },
            Layers = { new() { Name = "Shared state", SourcePdfPath = source, ConduitGuidePdfPath = source,
                ExcludedElementIds = { 123 },
                Conduits = { new() { ElementId = 27, Symbol = ConduitSymbol.Circle, Label = "27" },
                    new() { ElementId = 456, Symbol = ConduitSymbol.Triangle, Label = "35" } } } }
        };
        LayeredPdfComposer.Compose(job);
        Assert.Contains("2/2 requested conduits marked", File.ReadAllText(report));
        using var result = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        var forms = result.Pages[0].Resources.Elements.GetDictionary("/XObject")!.Elements.Values
            .Cast<PdfReference>().Select(r => (PdfDictionary)r.Value)
            .Select(f => System.Text.Encoding.ASCII.GetString(f.Stream!.UnfilteredValue));
        var content = Assert.Single(forms, f => f.Contains("/Element456", StringComparison.Ordinal));
        Assert.DoesNotContain("/Element123", content);
        Assert.Contains("10 10 30 30 re\nn", content);
        Assert.Contains("3 Tr\n(Hidden title)Tj\nQ", content);
        Assert.Contains("(Visible suffix)Tj", content);
        Assert.Contains("0 0 1 rg", content);
        Assert.Contains("1 0 0 rg", content);
        Assert.Contains("[6 3]2 d", content);
    }

    [Fact]
    public void Compose_CustomGroupsMergeNonAdjacentLayersWithoutChangingPaintOrder()
    {
        var source = CreateSource("group-source.pdf", XColors.Black, "VIEW", new XRect(10, 10, 100, 100));
        var output = Path.Combine(_directory, "custom-groups.pdf");
        var job = new LayeredPdfJob
        {
            BasePdfPath = source, OutputPath = output,
            LayerGroupOrder = { "Architecture", "Electrical", "Empty group" },
            Layers = {
                new() { Name = "View 1", GroupName = "Electrical", SourcePdfPath = source },
                new() { Name = "View 2", GroupName = "Architecture", SourcePdfPath = source },
                new() { Name = "View 3", GroupName = "Electrical", SourcePdfPath = source },
                new() { Name = "Unassigned view", SourcePdfPath = source }
            }
        };
        LayeredPdfComposer.Compose(job);
        using var document = PdfReader.Open(output, PdfDocumentOpenMode.Import);
        var properties = document.Internals.Catalog.Elements.GetDictionary("/OCProperties")!;
        var all = properties.Elements.GetArray("/OCGs")!;
        var order = properties.Elements.GetDictionary("/D")!.Elements.GetArray("/Order")!;
        Assert.Equal(5, all.Elements.Count); Assert.Equal(4, order.Elements.Count);
        Assert.Equal(all.Elements[0], order.Elements[0]);
        var architecture = Assert.IsType<PdfArray>(order.Elements[1]);
        var electrical = Assert.IsType<PdfArray>(order.Elements[2]);
        Assert.Equal("Architecture", Assert.IsType<PdfString>(architecture.Elements[0]).Value);
        Assert.Equal(all.Elements[2], architecture.Elements[1]);
        Assert.Equal("Electrical", Assert.IsType<PdfString>(electrical.Elements[0]).Value);
        Assert.Equal(3, electrical.Elements.Count);
        Assert.Equal(all.Elements[1], electrical.Elements[1]); Assert.Equal(all.Elements[3], electrical.Elements[2]);
        Assert.Equal(all.Elements[4], order.Elements[3]);
        var streams = document.Pages[0].Contents.Elements.Cast<PdfReference>().Select(r => (PdfContent)r.Value).ToList();
        for (var i = 0; i < streams.Count; i++)
            Assert.StartsWith($"/OC /L{i + 1} BDC", System.Text.Encoding.ASCII.GetString(streams[i].Stream!.UnfilteredValue));
    }

    private string CreateSource(
        string fileName,
        XColor color,
        string label,
        XRect rectangle,
        double width = 612,
        double height = 792)
    {
        var path = Path.Combine(_directory, fileName);
        using var document = new PdfDocument();
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(width);
        page.Height = XUnit.FromPoint(height);
        using (var graphics = XGraphics.FromPdfPage(page))
        {
            graphics.DrawRectangle(new XPen(color, 3), rectangle);
            graphics.DrawString(label, new XFont("Arial", 18), new XSolidBrush(color), rectangle.TopLeft);
        }
        document.Save(path);
        return path;
    }

    private string CreateTaggedSource(string fileName)
    {
        var path = Path.Combine(_directory, fileName);
        using var document = new PdfDocument();
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        var bytes = System.Text.Encoding.ASCII.GetBytes(
            "/Element123 BMC\n1 0 0 rg\n0 0 612 792 re f\nEMC\n" +
            "/Element456 BMC\n0 0 1 rg\n20 20 100 100 re f\nEMC\n");
        page.Contents.ReplaceContent(PdfSharp.Pdf.Content.ContentReader.ReadContent(bytes));
        document.Save(path);
        return path;
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
