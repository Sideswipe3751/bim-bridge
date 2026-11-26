using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using BimBridge.Host;
using BimBridge.Revit.LayeredPdf;

namespace BimBridge.Revit;

internal sealed class RevitLayeredPdfService
{
    private RevitSheetLayerExporter? _exporter;
    public bool ModelRestored => _exporter?.ModelRestored ?? true;
    public IReadOnlyList<string> Warnings => _exporter?.Warnings ?? new List<string>();
    public static bool ComposerAvailable => File.Exists(ComposerProcessRunner.ExecutablePath);

    public object Execute(UIApplication application, ConnectorRequest request)
    {
        var document = application.ActiveUIDocument?.Document
            ?? throw new InvalidOperationException("No active Revit document");
        if (document.IsFamilyDocument)
            throw new InvalidOperationException("Layered PDF requires a project document containing sheets");
        if (request.Operation == "layered_pdf.catalog")
        {
            if (request.Mode != "read") throw new InvalidOperationException("catalog requires read mode");
            var sheets = new FilteredElementCollector(document).OfClass(typeof(ViewSheet)).Cast<ViewSheet>()
                .Where(s => !s.IsPlaceholder && s.CanBePrinted)
                .OrderBy(s => s.SheetNumber, StringComparer.OrdinalIgnoreCase).Take(1001).ToList();
            return new
            {
                documentTitle = document.Title, composerAvailable = ComposerAvailable,
                activeSheetId = document.ActiveView is ViewSheet active ? (long?)active.Id.Value : null,
                truncated = sheets.Count > 1000,
                sheets = sheets.Take(1000).Select(s => new
                {
                    sheetId = s.Id.Value, sheetNumber = s.SheetNumber, sheetName = s.Name,
                    widthFeet = s.Outline.Max.U - s.Outline.Min.U, heightFeet = s.Outline.Max.V - s.Outline.Min.V,
                    viewports = s.GetAllViewports().Select(id => document.GetElement(id)).OfType<Viewport>()
                        .Where(v => !v.IsHidden(s)).Take(251).Select(v => new
                        { viewportId = v.Id.Value, viewId = v.ViewId.Value, viewName = document.GetElement(v.ViewId)?.Name }).ToList()
                }).ToList(),
                setupNames = PdfExportSetupProvider.GetNames(document),
                limits = new { maxSheets = 100, maxViewports = 250 },
                outputRoot = ExportRoot(application.Application.VersionNumber)
            };
        }
        if (request.Mode != "write") throw new InvalidOperationException("export requires write mode");
        var options = request.LayeredPdf ?? throw new ArgumentException("layeredPdf options are required");
        options.Validate();
        if (!ComposerAvailable) throw new FileNotFoundException("Build the adjacent BIM Bridge PDF composer first", ComposerProcessRunner.ExecutablePath);
        if (document.IsReadOnly || document.IsModifiable)
            throw new InvalidOperationException("Layered PDF requires an editable document outside a transaction");
        var baseSheet = ResolveSheet(document, options.BaseSheetId);
        var sheetsToExport = options.SheetIds.Select(id => ResolveSheet(document, id)).ToList();
        var plans = sheetsToExport.Select(s => new SheetExportRequest(s, SheetExportPlan.Create(document, s))).ToList();
        var layerCount = plans.Sum(p => p.Plan.Layers.Count);
        if (layerCount < 1 || layerCount > 250)
            throw new ArgumentException("Select sheets containing between 1 and 250 visible viewports");
        using var pdfOptions = PdfExportSetupProvider.GetOptions(document, options.SetupName ?? PdfExportSetupProvider.DefaultSetupName);
        PdfExportSetupProvider.ValidateForLayeredExport(pdfOptions);
        CheckDeadline(request);
        var directory = Path.Combine(ExportRoot(application.Application.VersionNumber), Guid.NewGuid().ToString("N"));
        FamilySessionPaths.AssertNoLinks(directory);
        Directory.CreateDirectory(directory);
        var output = Path.Combine(directory, options.FileStem + ".pdf");
        FamilySessionPaths.AssertNoLinks(output);
        _exporter = new RevitSheetLayerExporter(() => CheckDeadline(request), request.DeadlineUtc);
        var result = _exporter.Export(document, baseSheet, plans, pdfOptions, output,
            includeSheetAndDetail: options.IncludeSheetAndDetail, createBoxLayers: options.CreateBoxLayers);
        if (!ModelRestored) throw new InvalidOperationException("Temporary Revit changes were not restored");
        var file = new FileInfo(result.OutputPath);
        if (!file.Exists || file.Length == 0) throw new IOException("PDF composer produced no output");
        string digest;
        using (var hash = SHA256.Create())
        using (var stream = File.OpenRead(output))
            digest = BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        return new
        {
            path = output, format = "pdf", pageCount = 1, sha256 = digest, fileSizeBytes = file.Length,
            baseSheetId = baseSheet.Id.Value, sheetIds = options.SheetIds,
            sheetCount = result.SheetCount, viewportLayerCount = result.LayerCount,
            modelRestored = true, createBoxLayers = options.CreateBoxLayers,
            boxReportPath = options.CreateBoxLayers ? output + ".boxes.txt" : null,
            exportedAtUtc = DateTime.UtcNow.ToString("o")
        };
    }

    private static ViewSheet ResolveSheet(Document document, long id)
    {
        var sheet = document.GetElement(new ElementId(id)) as ViewSheet;
        if (sheet == null || sheet.IsPlaceholder || !sheet.CanBePrinted)
            throw new ArgumentException("Not a printable sheet: " + id);
        return sheet;
    }

    private static string ExportRoot(string version) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "BIM Bridge", "exports", "revit", version);

    private static void CheckDeadline(ConnectorRequest request)
    {
        if (DateTime.UtcNow >= request.DeadlineUtc)
            throw new TimeoutException("Layered PDF deadline reached; completed temporary exports were rolled back");
    }
}
