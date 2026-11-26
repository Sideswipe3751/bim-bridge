using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;

namespace BimBridge.Revit.LayeredPdf;

public static class PdfExportSetupProvider
{
    public const string DefaultSetupName = "<Revit API Defaults>";

    public static IReadOnlyList<string> GetNames(Document document)
    {
        var names = ExportPDFSettings.ListNames(document).OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToList();
        names.Insert(0, DefaultSetupName);
        return names;
    }

    public static string? GetActiveName(Document document) => ExportPDFSettings.GetActivePredefinedSettings(document)?.Name;

    public static PDFExportOptions GetOptions(Document document, string setupName)
    {
        if (string.Equals(setupName, DefaultSetupName, StringComparison.Ordinal))
        {
            return new PDFExportOptions
            {
                PaperFormat = ExportPaperFormat.Default,
                PaperOrientation = PageOrientationType.Auto,
                PaperPlacement = PaperPlacementType.Center,
                ZoomType = ZoomType.FitToPage,
                AlwaysUseRaster = false,
            };
        }

        var settings = ExportPDFSettings.FindByName(document, setupName)
            ?? throw new InvalidOperationException($"The PDF export setup '{setupName}' no longer exists.");
        return settings.GetOptions();
    }

    public static void ValidateForLayeredExport(PDFExportOptions options)
    {
        if (options.PaperFormat != ExportPaperFormat.Default ||
            options.PaperOrientation != PageOrientationType.Auto ||
            options.PaperPlacement != PaperPlacementType.Center ||
            options.ZoomType != ZoomType.FitToPage ||
            options.AlwaysUseRaster)
        {
            throw new InvalidOperationException(
                "The selected PDF setup must use Sheet Size, Automatic orientation, Center placement, Fit to Page, and Vector Processing for the first version of Layered PDF.");
        }
    }
}
