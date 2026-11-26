using System.IO.Compression;
using System.Text;
using System.Xml.Serialization;
using BimBridge.LayeredPdf.Core.Jobs;

namespace BimBridge.LayeredPdf.Composer;

public static class ExportDiagnosticArchive
{
    public static readonly string Build = typeof(ExportDiagnosticArchive).Assembly.GetName().Version?.ToString() ?? "development";

    public static void Write(LayeredPdfJob job, IReadOnlyList<string> report)
    {
        if (string.IsNullOrWhiteSpace(job.DiagnosticArchivePath)) return;
        var target = Path.GetFullPath(job.DiagnosticArchivePath);
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        // Serialize a copy: packaging must not change the live export job or its paths.
        var serializer = new XmlSerializer(typeof(LayeredPdfJob));
        using var buffer = new MemoryStream();
        serializer.Serialize(buffer, job);
        buffer.Position = 0;
        var replay = (LayeredPdfJob)serializer.Deserialize(buffer)!;
        replay.OutputPath = "replay.pdf";
        replay.ConduitReportPath = "replay.pdf.conduits.txt";
        replay.BoxReportPath = job.CreateBoxLayers ? "replay.pdf.boxes.txt" : string.Empty;
        replay.DiagnosticArchivePath = string.Empty;
        replay.OpenAfterCreate = false;
        try
        {
            using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
            {
                string Copy(string source, string entry)
                {
                    archive.CreateEntryFromFile(source, entry, CompressionLevel.Optimal);
                    return entry;
                }
                replay.BasePdfPath = Copy(job.BasePdfPath, "base.pdf");
                for (var i = 0; i < job.Layers.Count; i++)
                {
                    replay.Layers[i].SourcePdfPath = Copy(job.Layers[i].SourcePdfPath, $"layers/{i + 1:000}.pdf");
                    replay.Layers[i].ConduitGuidePdfPath = string.IsNullOrEmpty(job.Layers[i].ConduitGuidePdfPath)
                        ? string.Empty : Copy(job.Layers[i].ConduitGuidePdfPath, $"layers/{i + 1:000}.guide.pdf");
                }
                using (var stream = archive.CreateEntry("job.xml").Open()) serializer.Serialize(stream, replay);
                using (var writer = new StreamWriter(archive.CreateEntry("conduits.txt").Open(), Encoding.UTF8))
                    foreach (var line in report) writer.WriteLine(line);
                using (var writer = new StreamWriter(archive.CreateEntry("README.txt").Open(), Encoding.UTF8))
                {
                    writer.WriteLine($"Layered PDF {Build}");
                    writer.WriteLine(job.DiagnosticContext);
                    writer.WriteLine("Contains original layer PDFs, solid geometry guides, size rules and collected conduit metadata. No RVT files are included.");
                    writer.WriteLine("job.xml includes default and unmatched conduit sizes when captured with Save diagnostic package.");
                    writer.WriteLine("To replay: extract into a new folder; use that folder as the working directory; run BimBridge.LayeredPdf.Composer.exe job.xml.");
                    writer.WriteLine("Conduit matching uses bounded paper-coordinate tolerances; original print colors, weights and dash operations are retained.");
                }
            }
            File.Move(temporary, target, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
