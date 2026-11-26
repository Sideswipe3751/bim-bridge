using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using BimBridge.LayeredPdf.Core.Jobs;
using BimBridge.LayeredPdf.Core.Naming;
using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Groups;
using System.IO;

namespace BimBridge.Revit.LayeredPdf;

public sealed class RevitSheetLayerExporter
{
    private readonly Action _checkDeadline;
    private readonly DateTime _deadlineUtc;
    public bool ModelRestored { get; private set; } = true;
    public List<string> Warnings { get; } = new List<string>();
    public RevitSheetLayerExporter(Action checkDeadline, DateTime deadlineUtc)
    { _checkDeadline = checkDeadline; _deadlineUtc = deadlineUtc; }

    private void ConfigureFailures(Transaction transaction)
    {
        var preprocessor = new RevitFailurePreprocessor();
        _failureProcessors.Add(preprocessor);
        using var failures = transaction.GetFailureHandlingOptions();
        failures.SetFailuresPreprocessor(preprocessor);
        failures.SetClearAfterRollback(true);
        failures.SetDelayedMiniWarnings(false);
        failures.SetForcedModalHandling(false);
        transaction.SetFailureHandlingOptions(failures);
    }
    private readonly List<RevitFailurePreprocessor> _failureProcessors = new List<RevitFailurePreprocessor>();
    public ExportResult Export(
        Document document,
        ViewSheet baseSheet,
        IReadOnlyList<SheetExportRequest> sheetRequests,
        PDFExportOptions options,
        string outputPath,
        ConduitPatternSettings? conduitPatterns = null,
        LayerGroupSettings? layerGroups = null,
        bool includeSheetAndDetail = true,
        bool saveDiagnostics = false,
        bool createBoxLayers = false)
    {
        if (sheetRequests.Count == 0)
        {
            throw new ArgumentException("At least one source sheet must be selected.", nameof(sheetRequests));
        }

        conduitPatterns ??= new ConduitPatternSettings();
        conduitPatterns.Validate();
        layerGroups?.Validate();
        EnsureCompatibleSheetOutlines(baseSheet, sheetRequests);
        var tempDirectory = Path.Combine(Path.GetTempPath(), "BimBridge.LayeredPdf", Guid.NewGuid().ToString("N"));
        BimBridge.Host.FamilySessionPaths.AssertNoLinks(tempDirectory);
        Directory.CreateDirectory(tempDirectory);
        var succeeded = false;
        try
        {
            var basePath = Path.Combine(tempDirectory, "000.pdf");
            ExportBase(document, baseSheet, options, tempDirectory, basePath);

            var layerSources = new List<LayerSource>();
            for (var sheetIndex = 0; sheetIndex < sheetRequests.Count; sheetIndex++)
            {
                var request = sheetRequests[sheetIndex];
                var sheetDirectory = Path.Combine(tempDirectory, $"s{sheetIndex + 1:000}");
                Directory.CreateDirectory(sheetDirectory);
                var sourcePaths = request.Plan.Layers
                    .Select((layer, layerIndex) => Path.Combine(sheetDirectory, $"{layerIndex + 1:000}.pdf"))
                    .ToList();
                var titleBlockIds = GetTitleBlockIds(document, request.Sheet);
                var conduits = request.Plan.Layers.Select(layer => ConduitPatternProvider.GetElements(document,
                    request.Sheet, (Viewport)document.GetElement(layer.ViewportId), conduitPatterns, saveDiagnostics)).ToList();
                ExportLayerPages(document, request.Sheet, request.Plan, options, sheetDirectory, sourcePaths, conduits);
                for (var layerIndex = 0; layerIndex < request.Plan.Layers.Count; layerIndex++)
                {
                    layerSources.Add(new LayerSource(
                        request,
                        request.Plan.Layers[layerIndex],
                        sourcePaths[layerIndex],
                        titleBlockIds,
                        conduits[layerIndex]));
                }
            }

            var job = CreateJob(outputPath, basePath, layerSources, document, layerGroups, includeSheetAndDetail, createBoxLayers);
            job.ConduitPatterns = conduitPatterns;
            if (saveDiagnostics)
            {
                job.DiagnosticArchivePath = outputPath + ".diagnostics.zip";
                job.DiagnosticContext = $"Revit {document.Application.VersionNumber}, build {document.Application.VersionBuild}; document: {document.Title}";
            }
            if (conduitPatterns.Enabled) job.ConduitReportPath = outputPath + ".conduits.txt";
            var jobPath = Path.Combine(tempDirectory, "job.xml");
            LayeredPdfJobSerializer.Write(jobPath, job);
            _checkDeadline();
            ComposerProcessRunner.Run(jobPath, _deadlineUtc);
            succeeded = true;
            return new ExportResult(outputPath, sheetRequests.Count, layerSources.Count);
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                $"{exception.Message}\n\nTemporary diagnostic files were retained at:\n{tempDirectory}",
                exception);
        }
        finally
        {
            if (succeeded)
            {
                TryDeleteDirectory(tempDirectory);
            }
        }
    }

    private void ExportBase(
        Document document,
        ViewSheet sheet,
        PDFExportOptions options,
        string tempDirectory,
        string basePath)
    {
        ExportWithTemporaryViewportSet(
            document,
            sheet,
            options,
            tempDirectory,
            basePath,
            sheet.GetAllViewports().ToList(),
            viewportToKeep: null,
            hideSheetBaseElements: false,
            Array.Empty<ElementId>());
    }

    private void ExportLayerPages(
        Document document,
        ViewSheet sheet,
        SheetExportPlan plan,
        PDFExportOptions options,
        string tempDirectory,
        IReadOnlyList<string> sourcePaths,
        IReadOnlyList<List<ConduitElementPattern>> conduits)
    {
        var allViewportIds = sheet.GetAllViewports().ToList();
        var sheetBaseElementIds = GetVisibleHideableSheetBaseElementIds(document, sheet);
        for (var index = 0; index < plan.Layers.Count; index++)
        {
            ExportWithTemporaryViewportSet(
                document,
                sheet,
                options,
                tempDirectory,
                sourcePaths[index],
                allViewportIds,
                plan.Layers[index].ViewportId,
                hideSheetBaseElements: true,
                sheetBaseElementIds,
                conduits[index]);
        }
    }

    private void ExportWithTemporaryViewportSet(
        Document document,
        ViewSheet sheet,
        PDFExportOptions options,
        string outputDirectory,
        string outputPath,
        IReadOnlyCollection<ElementId> allViewportIds,
        ElementId? viewportToKeep,
        bool hideSheetBaseElements,
        IReadOnlyCollection<ElementId> sheetBaseElementIds,
        IReadOnlyList<ConduitElementPattern>? conduits = null)
    {
        _checkDeadline();
        using var group = new TransactionGroup(document, "BIM Bridge PDF temporary viewport isolation");
        if (group.Start() != TransactionStatus.Started)
        {
            throw new InvalidOperationException("Could not start the temporary viewport isolation group.");
        }

        ModelRestored = false;
        try
        {
            using (var transaction = new Transaction(document, "Prepare isolated sheet export"))
            {
                if (transaction.Start() != TransactionStatus.Started)
                {
                    throw new InvalidOperationException("Could not start temporary sheet isolation.");
                }

                ConfigureFailures(transaction);
                foreach (var viewportId in allViewportIds)
                {
                    if (viewportToKeep is not null && viewportId.Value == viewportToKeep.Value)
                    {
                        continue;
                    }

                    if (document.GetElement(viewportId) is Viewport viewport)
                    {
                        sheet.DeleteViewport(viewport);
                    }
                }

                // Keep title blocks visible here so Revit's Use Sheet Size continues to use
                // custom paper dimensions. The composer removes their tagged PDF content by
                // Revit element ID before it creates the viewport OCG.
                if (hideSheetBaseElements && sheetBaseElementIds.Count > 0)
                {
                    sheet.HideElements(sheetBaseElementIds.ToList());
                }

                if (transaction.Commit() != TransactionStatus.Committed)
                {
                    throw new InvalidOperationException("Could not commit temporary sheet isolation.");
                }
            }

            ExportOne(document, sheet, options, outputDirectory, outputPath);

            // A separate solid-line guide supplies visible geometry even when Revit prints
            // a dashed conduit as many tiny strokes. It never becomes a final PDF layer.
            if (conduits?.Count > 0 && viewportToKeep is not null)
            {
                var view = (View)document.GetElement(((Viewport)document.GetElement(viewportToKeep)).ViewId);
                using (var guideTransaction = new Transaction(document, "Prepare conduit geometry guide"))
                {
                    guideTransaction.Start();
                    ConfigureFailures(guideTransaction);
                    foreach (var overrideId in conduits.Where(c => c.Symbol != ConduitSymbol.RevitDefault)
                        .Select(c => c.LinkInstanceId == 0 ? c.ElementId : c.LinkInstanceId).Distinct())
                    {
                        var id = new ElementId(overrideId);
                        using var overrides = new OverrideGraphicSettings(view.GetElementOverrides(id));
                        overrides.SetProjectionLinePatternId(LinePatternElement.GetSolidPatternId());
                        overrides.SetCutLinePatternId(LinePatternElement.GetSolidPatternId());
                        view.SetElementOverrides(id, overrides);
                    }
                    if (guideTransaction.Commit() != TransactionStatus.Committed)
                        throw new InvalidOperationException("Could not prepare the temporary conduit geometry guide.");
                }
                ExportOne(document, sheet, options, outputDirectory, outputPath + ".guide.pdf");
            }
        }
        finally
        {
            if (group.HasStarted())
            {
                var rollbackStatus = group.RollBack();
                ModelRestored = rollbackStatus == TransactionStatus.RolledBack;
                foreach (var processor in _failureProcessors) Warnings.AddRange(processor.Warnings);
                _failureProcessors.Clear();
                if (rollbackStatus != TransactionStatus.RolledBack)
                {
                    throw new InvalidOperationException(
                        "Revit could not roll back the temporary viewport isolation. Review the sheet before continuing.");
                }
            }
        }
    }

    private static IReadOnlyList<ElementId> GetVisibleHideableSheetBaseElementIds(Document document, ViewSheet sheet)
    {
        return new FilteredElementCollector(document, sheet.Id)
            .WhereElementIsNotElementType()
            .Where(element => element.Id.Value != sheet.Id.Value)
            .Where(element => !(element is Viewport))
            .Where(element => element.Category?.Id.Value != (long)BuiltInCategory.OST_TitleBlocks)
            .Where(element => !element.IsHidden(sheet))
            .Where(element => element.CanBeHidden(sheet))
            .Select(element => element.Id)
            .ToList();
    }

    private static IReadOnlyList<long> GetTitleBlockIds(Document document, ViewSheet sheet)
    {
        return new FilteredElementCollector(document, sheet.Id)
            .OfCategory(BuiltInCategory.OST_TitleBlocks)
            .WhereElementIsNotElementType()
            .Select(element => element.Id.Value)
            .ToList();
    }

    private void ExportOne(
        Document document,
        ViewSheet sheet,
        PDFExportOptions options,
        string outputDirectory,
        string outputPath)
    {
        _checkDeadline();
        options.Combine = true;
        options.FileName = Path.GetFileNameWithoutExtension(outputPath);
        options.StopOnError = true;
        var result = document.Export(outputDirectory, new List<ElementId> { sheet.Id }, options);
        if (!result || !File.Exists(outputPath))
        {
            throw new InvalidOperationException($"Revit did not create the expected PDF: {outputPath}");
        }
    }

    private static LayeredPdfJob CreateJob(
        string outputPath,
        string basePath,
        IReadOnlyList<LayerSource> layerSources,
        Document document,
        LayerGroupSettings? layerGroups,
        bool includeSheetAndDetail,
        bool createBoxLayers)
    {
        var job = new LayeredPdfJob
        {
            OutputPath = outputPath,
            CreateBoxLayers = createBoxLayers,
            BoxReportPath = createBoxLayers ? outputPath + ".boxes.txt" : string.Empty,
            BasePdfPath = basePath,
            LayerGroupOrder = layerGroups?.Enabled == true ? layerGroups.Groups.Select(g => g.Name).ToList() : new(),
        };
        var uniqueNames = LayerNameBuilder.MakeUnique(layerSources.Select(source =>
        {
            var viewport = (Viewport)document.GetElement(source.Layer.ViewportId);
            var view = (View)document.GetElement(viewport.ViewId);
            return LayerNameBuilder.BuildForExport(includeSheetAndDetail, source.Request.Sheet.SheetNumber,
                source.Request.Sheet.Name, viewport.get_Parameter(BuiltInParameter.VIEWPORT_DETAIL_NUMBER)?.AsString(), view.Name);
        }));
        for (var index = 0; index < layerSources.Count; index++)
        {
            var source = layerSources[index];
            var layer = source.Layer;
            var boxes = createBoxLayers ? BoxLayerProvider.GetCandidates(document,
                ((Viewport)document.GetElement(layer.ViewportId)).ViewId) : new BoxLayerCandidates();
            job.Layers.Add(new PdfLayerJob
            {
                BoxLayerName = uniqueNames[index] + " BOX",
                BoxElementIds = boxes.BoxIds,
                BoxConduitElementIds = boxes.ConduitIds.Distinct().ToList(),
                AmbiguousBoxElementIds = boxes.AmbiguousIds,
                GroupName = layerGroups?.Enabled == true
                    ? layerGroups.GroupNameFor(document.GetElement(layer.ViewportId).UniqueId)
                    : source.Request.DisplayName,
                Name = uniqueNames[index],
                SourcePdfPath = source.SourcePath,
                ExcludedElementIds = source.ExcludedElementIds.ToList(),
                Conduits = source.Conduits.ToList(),
                ConduitGuidePdfPath = source.Conduits.Count > 0 ? source.SourcePath + ".guide.pdf" : string.Empty,
                ClipLeft = layer.NormalizedViewClip.Left,
                ClipBottom = layer.NormalizedViewClip.Bottom,
                ClipRight = layer.NormalizedViewClip.Right,
                ClipTop = layer.NormalizedViewClip.Top,
                HasLabelClip = layer.NormalizedLabelClip.HasValue,
                LabelClipLeft = layer.NormalizedLabelClip?.Left ?? 0,
                LabelClipBottom = layer.NormalizedLabelClip?.Bottom ?? 0,
                LabelClipRight = layer.NormalizedLabelClip?.Right ?? 1,
                LabelClipTop = layer.NormalizedLabelClip?.Top ?? 1,
            });
        }

        return job;
    }

    private static void EnsureCompatibleSheetOutlines(
        ViewSheet baseSheet,
        IReadOnlyList<SheetExportRequest> sheetRequests)
    {
        const double toleranceInFeet = 1.0 / 12000.0;
        var baseWidth = baseSheet.Outline.Max.U - baseSheet.Outline.Min.U;
        var baseHeight = baseSheet.Outline.Max.V - baseSheet.Outline.Min.V;
        foreach (var request in sheetRequests)
        {
            var width = request.Sheet.Outline.Max.U - request.Sheet.Outline.Min.U;
            var height = request.Sheet.Outline.Max.V - request.Sheet.Outline.Min.V;
            if (Math.Abs(width - baseWidth) > toleranceInFeet ||
                Math.Abs(height - baseHeight) > toleranceInFeet)
            {
                throw new InvalidOperationException(
                    $"Sheet '{request.DisplayName}' does not use the same paper size and orientation as the current " +
                    $"sheet '{baseSheet.SheetNumber} - {baseSheet.Name}'. All selected views must share one page coordinate system.");
            }
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            BimBridge.Host.FamilySessionPaths.AssertNoLinks(path);
            Directory.Delete(path, recursive: true);
        }
        catch
        {
            // A successful export should not be reported as failed only because temporary cleanup was delayed.
        }
    }

    private sealed class LayerSource
    {
        public LayerSource(
            SheetExportRequest request,
            ViewportLayer layer,
            string sourcePath,
            IReadOnlyList<long> excludedElementIds,
            IReadOnlyList<ConduitElementPattern> conduits)
        {
            Request = request;
            Layer = layer;
            SourcePath = sourcePath;
            ExcludedElementIds = excludedElementIds;
            Conduits = conduits;
        }

        public SheetExportRequest Request { get; }

        public ViewportLayer Layer { get; }

        public string SourcePath { get; }

        public IReadOnlyList<long> ExcludedElementIds { get; }

        public IReadOnlyList<ConduitElementPattern> Conduits { get; }
    }
}

public sealed class ExportResult
{
    public ExportResult(string outputPath, int sheetCount, int layerCount)
    {
        OutputPath = outputPath;
        SheetCount = sheetCount;
        LayerCount = layerCount;
    }

    public string OutputPath { get; }

    public int SheetCount { get; }

    public int LayerCount { get; }
}
