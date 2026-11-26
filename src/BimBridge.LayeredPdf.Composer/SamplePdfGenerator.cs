using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace BimBridge.LayeredPdf.Composer;

internal static class SamplePdfGenerator
{
    public static void Create(string outputPath)
    {
        var outputFullPath = Path.GetFullPath(outputPath);
        var outputDirectory = Path.GetDirectoryName(outputFullPath)
            ?? throw new InvalidOperationException("The sample output path has no parent directory.");
        Directory.CreateDirectory(outputDirectory);
        var tempDirectory = Path.Combine(Path.GetTempPath(), "LayeredPdfSample", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);
        try
        {
            var basePath = CreatePage(
                Path.Combine(tempDirectory, "base.pdf"),
                graphics =>
                {
                    graphics.DrawRectangle(new XPen(XColors.Black, 2), new XRect(18, 18, 756, 576));
                    graphics.DrawString(
                        "SHEET BASE",
                        new XFont("Arial", 15, XFontStyleEx.Bold),
                        XBrushes.Black,
                        new XPoint(30, 45));
                });
            var architecturalPath = CreatePage(
                Path.Combine(tempDirectory, "architectural.pdf"),
                graphics =>
                {
                    graphics.DrawRectangle(new XPen(XColors.Firebrick, 4), new XRect(90, 110, 300, 360));
                    graphics.DrawLine(new XPen(XColors.Firebrick, 2), 90, 110, 390, 470);
                    graphics.DrawString("01 - ARCHITECTURAL", new XFont("Arial", 18), XBrushes.Firebrick, new XPoint(110, 150));
                });
            var mechanicalPath = CreatePage(
                Path.Combine(tempDirectory, "mechanical.pdf"),
                graphics =>
                {
                    graphics.DrawEllipse(new XPen(XColors.RoyalBlue, 4), new XRect(380, 180, 280, 280));
                    graphics.DrawLine(new XPen(XColors.RoyalBlue, 2), 380, 320, 660, 320);
                    graphics.DrawString("02 - MECHANICAL", new XFont("Arial", 18), XBrushes.RoyalBlue, new XPoint(420, 230));
                });

            LayeredPdfComposer.Compose(new LayeredPdfJob
            {
                OutputPath = outputFullPath,
                BasePdfPath = basePath,
                Layers =
                {
                    new PdfLayerJob
                    {
                        Name = "01 - Architectural",
                        SourcePdfPath = architecturalPath,
                        ClipLeft = 0.08,
                        ClipBottom = 0.15,
                        ClipRight = 0.52,
                        ClipTop = 0.88,
                        HasLabelClip = true,
                        LabelClipLeft = 0.08,
                        LabelClipBottom = 0.08,
                        LabelClipRight = 0.3,
                        LabelClipTop = 0.13,
                    },
                    new PdfLayerJob
                    {
                        Name = "02 - Mechanical",
                        SourcePdfPath = mechanicalPath,
                        ClipLeft = 0.45,
                        ClipBottom = 0.18,
                        ClipRight = 0.9,
                        ClipTop = 0.78,
                    },
                },
            });
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    private static string CreatePage(string path, Action<XGraphics> draw)
    {
        using var document = new PdfDocument();
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(792);
        page.Height = XUnit.FromPoint(612);
        using (var graphics = XGraphics.FromPdfPage(page))
        {
            draw(graphics);
        }

        document.Save(path);
        return path;
    }
}
