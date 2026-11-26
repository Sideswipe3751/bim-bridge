using System.IO.Compression;
using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.IO;
using System.Text;

namespace BimBridge.LayeredPdf.Composer.Tests;

public sealed class ExportDiagnosticArchiveTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "LayeredDiagnosticTests", Guid.NewGuid().ToString("N"));
    public ExportDiagnosticArchiveTests() => Directory.CreateDirectory(_directory);

    [Fact]
    public void PackagePreservesSourceGeometryAndDefaultMetadataAndReplaysAfterRelocation()
    {
        var source = Path.Combine(_directory, "source.pdf");
        using (var document = new PdfDocument())
        {
            var page = document.AddPage();
            page.Contents.ReplaceContent(ContentReader.ReadContent(Encoding.ASCII.GetBytes("/Element27 BMC 0 0 1 RG 1.4 w 20 160 m 480 160 l S EMC")));
            document.Save(source);
        }
        var job = new LayeredPdfJob
        {
            BasePdfPath = source,
            OutputPath = Path.Combine(_directory, "output.pdf"),
            DiagnosticArchivePath = Path.Combine(_directory, "output.pdf.diagnostics.zip"),
            ConduitPatterns = new() { Enabled = true },
            Layers = { new() { Name = "Linked view", SourcePdfPath = source, ConduitGuidePdfPath = source,
                Conduits = { new() { ElementId = 27, LinkInstanceId = 101, SourceDocument = "Linked model", Standard = "EMT", NominalDiameterMm = 26.64,
                    DisplayDiameter = "27 mm", Symbol = ConduitSymbol.RevitDefault, HasMatchingRule = false } } } }
        };
        LayeredPdfComposer.Compose(job);
        var extracted = Path.Combine(_directory, "relocated");
        ZipFile.ExtractToDirectory(job.DiagnosticArchivePath, extracted);
        Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(Path.Combine(extracted, "layers", "001.pdf")));
        Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(Path.Combine(extracted, "layers", "001.guide.pdf")));
        Assert.Contains("1 without a matching", File.ReadAllText(Path.Combine(extracted, "conduits.txt")));
        var replay = LayeredPdfJobSerializer.Read(Path.Combine(extracted, "job.xml"));
        var conduit = Assert.Single(Assert.Single(replay.Layers).Conduits);
        Assert.Equal(26.64, conduit.NominalDiameterMm);
        Assert.Equal("27 mm", conduit.DisplayDiameter);
        Assert.Equal("EMT", conduit.Standard);
        Assert.False(conduit.HasMatchingRule);
        Assert.Equal(string.Empty, replay.DiagnosticArchivePath);
        Assert.Equal(source, job.Layers[0].SourcePdfPath);
        replay.BasePdfPath = Path.Combine(extracted, replay.BasePdfPath);
        replay.OutputPath = Path.Combine(extracted, replay.OutputPath);
        replay.ConduitReportPath = Path.Combine(extracted, replay.ConduitReportPath);
        foreach (var layer in replay.Layers)
        {
            layer.SourcePdfPath = Path.Combine(extracted, layer.SourcePdfPath);
            layer.ConduitGuidePdfPath = Path.Combine(extracted, layer.ConduitGuidePdfPath);
        }
        LayeredPdfComposer.Compose(replay);
        using var original = PdfReader.Open(job.OutputPath, PdfDocumentOpenMode.Import);
        using var rerun = PdfReader.Open(replay.OutputPath, PdfDocumentOpenMode.Import);
        string Commands(PdfPage page) => System.Text.RegularExpressions.Regex.Replace(
            Encoding.ASCII.GetString(ContentReader.ReadContent(page).ToContent()), @"/Fm\d+", "/Form");
        Assert.Equal(Commands(original.Pages[0]), Commands(rerun.Pages[0]));
        var originalForms = original.Pages[0].Resources.Elements.GetDictionary("/XObject")!;
        var replayForms = rerun.Pages[0].Resources.Elements.GetDictionary("/XObject")!;
        var expected = originalForms.Elements.GetDictionary(originalForms.Elements.Keys.First())!.Stream.UnfilteredValue;
        foreach (var key in replayForms.Elements.Keys)
            Assert.Equal(expected, replayForms.Elements.GetDictionary(key)!.Stream.UnfilteredValue);
    }

    [Fact]
    public void MissingInputPreservesPreviousArchiveAndRemovesIncompletePackage()
    {
        var target = Path.Combine(_directory, "diagnostics.zip");
        File.WriteAllText(target, "previous archive");
        var job = new LayeredPdfJob { BasePdfPath = Path.Combine(_directory, "missing.pdf"), DiagnosticArchivePath = target };
        Assert.Throws<FileNotFoundException>(() => ExportDiagnosticArchive.Write(job, Array.Empty<string>()));
        Assert.Equal("previous archive", File.ReadAllText(target));
        Assert.Empty(Directory.GetFiles(_directory, "*.tmp"));
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}
