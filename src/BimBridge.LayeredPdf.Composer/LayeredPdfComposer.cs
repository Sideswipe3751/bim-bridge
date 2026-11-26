using BimBridge.LayeredPdf.Core.Jobs;
using BimBridge.LayeredPdf.Core.Naming;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;
using System.Globalization;
using System.Text;

namespace BimBridge.LayeredPdf.Composer;

public static class LayeredPdfComposer
{
    public static void Compose(LayeredPdfJob job)
    {
        ArgumentNullException.ThrowIfNull(job);
        Validate(job);

        var outputDirectory = Path.GetDirectoryName(Path.GetFullPath(job.OutputPath));
        if (outputDirectory is null)
        {
            throw new InvalidOperationException("The output path does not have a parent directory.");
        }

        Directory.CreateDirectory(outputDirectory);
        using var document = new PdfDocument();
        document.Info.Title = Path.GetFileNameWithoutExtension(job.OutputPath);
        document.Info.Creator = "BIM Bridge Layered PDF " + ExportDiagnosticArchive.Build;
        using var boxLayers = BoxLayerExpansion.Create(job);
        var uniqueNames = LayerNameBuilder.MakeUnique(boxLayers.Layers.Select(l => l.Name));

        var sources = new List<(string Name, string Path, PdfLayerJob? Layer)>
        {
            ("Sheet Base", job.BasePdfPath, null),
        };
        sources.AddRange(boxLayers.Layers.Select((layer, index) => (uniqueNames[index], layer.SourcePdfPath, (PdfLayerJob?)layer)));

        var firstForm = XPdfForm.FromFile(sources[0].Path);
        EnsureOnePage(firstForm, sources[0].Path);
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(firstForm.PointWidth);
        page.Height = XUnit.FromPoint(firstForm.PointHeight);
        firstForm.Dispose();

        var layerReferences = new List<PdfReference>();
        var conduitReport = new List<string>
        {
            "Layered PDF " + ExportDiagnosticArchive.Build,
            "Conduit markers: host and directly linked models, straight single-line conduits. Linked elements are matched by ID and projected position; ambiguous overlaps remain unchanged.",
            "Unmapped sizes and RevitDefault rules are unchanged. Colors, original dash patterns and line widths come from the original PDF.",
        };
        for (var index = 0; index < sources.Count; index++)
        {
            var source = sources[index];
            var ocg = CreateOptionalContentGroup(document, source.Name);
            layerReferences.Add(ocg.ReferenceNotNull);
            AddLayerResource(page, $"/L{index + 1}", ocg.ReferenceNotNull);

            string? strippedPath = null;
            string? decoratedPath = null;
            try
            {
                var formPath = source.Path;
                if (source.Layer?.ExcludedElementIds.Count > 0)
                {
                    strippedPath = RevitElementContentStripper.CreateCopyWithoutElements(
                        source.Path,
                        source.Layer.ExcludedElementIds);
                    formPath = strippedPath;
                }

                if (source.Layer is not null && job.ConduitPatterns.Enabled)
                {
                    if (!string.IsNullOrWhiteSpace(job.DiagnosticArchivePath))
                    {
                        var patterns = source.Layer.Conduits;
                        conduitReport.Add($"{source.Name}: collected {patterns.Count} conduit records; " +
                            $"{patterns.Count(p => p.LinkInstanceId != 0)} linked; " +
                            $"{patterns.Count(p => p.Symbol != BimBridge.LayeredPdf.Core.Conduits.ConduitSymbol.RevitDefault)} custom; " +
                            $"{patterns.Count(p => !p.HasMatchingRule)} without a matching size/standard rule. Full metadata: job.xml in diagnostic package.");
                    }
                    var candidate = ConduitPdfDecorator.CreateDecoratedCopy(formPath, source.Layer, job.ConduitPatterns, conduitReport);
                    if (candidate != formPath) decoratedPath = candidate;
                    formPath = candidate;
                }

                using var form = XPdfForm.FromFile(formPath);
                EnsureOnePage(form, source.Path);
                EnsureSamePageSize(page, form, source.Path);

                var contentCountBefore = GetContents(page.Contents).Count;
                using (var graphics = XGraphics.FromPdfPage(page, XGraphicsPdfPageOptions.Append))
                {
                    if (source.Layer is not null)
                    {
                        var clipPath = CreateClipPath(source.Layer, page.Width.Point, page.Height.Point);
                        graphics.IntersectClip(clipPath);
                    }

                    graphics.DrawImage(form, 0, 0, page.Width.Point, page.Height.Point);
                }

                var content = GetContents(page.Contents).Skip(contentCountBefore).Single();
                WrapInOptionalContentGroup(content, $"/L{index + 1}");
            }
            finally
            {
                if (decoratedPath is not null) TryDeleteFile(decoratedPath);
                if (strippedPath is not null)
                {
                    TryDeleteFile(strippedPath);
                }
            }
        }

        AddOptionalContentProperties(document, layerReferences, boxLayers.Layers, job.LayerGroupOrder);
        // Keep any previously exported PDF intact if composition or guide processing fails.
        var stagedPdf = job.OutputPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var stagedReport = job.ConduitReportPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var stagedBoxReport = job.BoxReportPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            document.Save(stagedPdf);
            using (var readback = PdfReader.Open(stagedPdf, PdfDocumentOpenMode.Import))
            {
                var groups = readback.Internals.Catalog.Elements.GetDictionary("/OCProperties")?.Elements.GetArray("/OCGs");
                if (readback.PageCount != 1 || groups == null || groups.Elements.Count != sources.Count)
                    throw new InvalidDataException("Composed PDF failed page and optional-content-group readback");
            }
            var hasReport = job.ConduitPatterns.Enabled && !string.IsNullOrWhiteSpace(job.ConduitReportPath);
            if (hasReport) File.WriteAllLines(stagedReport, conduitReport, Encoding.UTF8);
            var hasBoxReport = job.CreateBoxLayers && !string.IsNullOrWhiteSpace(job.BoxReportPath);
            if (hasBoxReport) File.WriteAllLines(stagedBoxReport, boxLayers.Report, Encoding.UTF8);
            File.Move(stagedPdf, job.OutputPath, overwrite: true);
            if (hasReport) File.Move(stagedReport, job.ConduitReportPath, overwrite: true);
            if (hasBoxReport) File.Move(stagedBoxReport, job.BoxReportPath, overwrite: true);
            ExportDiagnosticArchive.Write(job, job.CreateBoxLayers ? conduitReport.Concat(boxLayers.Report).ToList() : conduitReport);
        }
        finally
        {
            TryDeleteFile(stagedPdf);
            TryDeleteFile(stagedReport);
            TryDeleteFile(stagedBoxReport);
        }
    }

    private static void Validate(LayeredPdfJob job)
    {
        if (string.IsNullOrWhiteSpace(job.OutputPath))
        {
            throw new ArgumentException("OutputPath is required.", nameof(job));
        }

        if (string.IsNullOrWhiteSpace(job.BasePdfPath) || !File.Exists(job.BasePdfPath))
        {
            throw new FileNotFoundException("The base PDF was not found.", job.BasePdfPath);
        }

        if (job.Layers.Count == 0)
        {
            throw new ArgumentException("At least one viewport layer is required.", nameof(job));
        }

        foreach (var layer in job.Layers)
        {
            if (string.IsNullOrWhiteSpace(layer.Name))
            {
                throw new ArgumentException("Every layer requires a name.", nameof(job));
            }

            if (!File.Exists(layer.SourcePdfPath))
            {
                throw new FileNotFoundException($"The source PDF for layer '{layer.Name}' was not found.", layer.SourcePdfPath);
            }

            if (layer.ClipLeft < 0 || layer.ClipBottom < 0 || layer.ClipRight > 1 || layer.ClipTop > 1 ||
                layer.ClipRight <= layer.ClipLeft || layer.ClipTop <= layer.ClipBottom)
            {
                throw new ArgumentException($"Layer '{layer.Name}' has an invalid normalized clip rectangle.", nameof(job));
            }

            if (layer.HasLabelClip &&
                (layer.LabelClipLeft < 0 || layer.LabelClipBottom < 0 ||
                 layer.LabelClipRight > 1 || layer.LabelClipTop > 1 ||
                 layer.LabelClipRight <= layer.LabelClipLeft ||
                 layer.LabelClipTop <= layer.LabelClipBottom))
            {
                throw new ArgumentException($"Layer '{layer.Name}' has an invalid normalized label clip rectangle.", nameof(job));
            }
        }
    }

    private static PdfDictionary CreateOptionalContentGroup(PdfDocument document, string name)
    {
        var group = new PdfDictionary(document);
        group.Elements.SetName("/Type", "/OCG");
        group.Elements["/Name"] = new PdfString(name, PdfStringEncoding.Unicode);
        document.Internals.AddObject(group);
        return group;
    }

    private static void AddLayerResource(PdfPage page, string resourceName, PdfReference groupReference)
    {
        var properties = page.Resources.Elements.GetDictionary("/Properties");
        if (properties is null)
        {
            properties = new PdfDictionary(page.Owner);
            page.Resources.Elements["/Properties"] = properties;
        }

        properties.Elements[resourceName] = groupReference;
    }

    private static void AddOptionalContentProperties(
        PdfDocument document,
        IReadOnlyList<PdfReference> layerReferences,
        IReadOnlyList<PdfLayerJob> layers,
        IReadOnlyList<string> groupOrder)
    {
        var allGroups = new PdfArray(document);
        var order = new PdfArray(document);
        var initiallyOn = new PdfArray(document);
        foreach (var reference in layerReferences)
        {
            allGroups.Elements.Add(reference);
            initiallyOn.Elements.Add(reference);
        }

        // Only change the layer panel hierarchy, never the rendering/overlay order.
        // Views from different sheets may share a group even when non-adjacent.
        order.Elements.Add(layerReferences[0]);
        var groups = new Dictionary<string, PdfArray>(StringComparer.Ordinal);
        var activeNames = layers.Select(l => l.GroupName).Where(n => !string.IsNullOrWhiteSpace(n)).ToHashSet(StringComparer.Ordinal);
        foreach (var name in groupOrder.Where(activeNames.Contains).Distinct(StringComparer.Ordinal))
        {
            var group = new PdfArray(document);
            group.Elements.Add(new PdfString(name, PdfStringEncoding.Unicode));
            groups.Add(name, group); order.Elements.Add(group);
        }
        for (var index = 0; index < layers.Count; index++)
        {
            var groupName = layers[index].GroupName;
            if (string.IsNullOrWhiteSpace(groupName))
            {
                order.Elements.Add(layerReferences[index + 1]);
                continue;
            }
            if (!groups.TryGetValue(groupName, out var group))
            {
                group = new PdfArray(document);
                group.Elements.Add(new PdfString(groupName, PdfStringEncoding.Unicode));
                groups.Add(groupName, group); order.Elements.Add(group);
            }
            group.Elements.Add(layerReferences[index + 1]);
        }

        var defaultConfiguration = new PdfDictionary(document);
        defaultConfiguration.Elements["/Name"] = new PdfString("Layered PDF", PdfStringEncoding.Unicode);
        defaultConfiguration.Elements["/Order"] = order;
        defaultConfiguration.Elements["/ON"] = initiallyOn;

        var properties = new PdfDictionary(document);
        properties.Elements["/OCGs"] = allGroups;
        properties.Elements["/D"] = defaultConfiguration;
        document.Internals.Catalog.Elements["/OCProperties"] = properties;
    }

    private static void WrapInOptionalContentGroup(PdfContent content, string resourceName)
    {
        var original = content.Stream?.UnfilteredValue ?? Array.Empty<byte>();
        var prefix = Encoding.ASCII.GetBytes($"/OC {resourceName} BDC\n");
        var suffix = Encoding.ASCII.GetBytes("\nEMC\n");
        var wrapped = new byte[prefix.Length + original.Length + suffix.Length];
        Buffer.BlockCopy(prefix, 0, wrapped, 0, prefix.Length);
        Buffer.BlockCopy(original, 0, wrapped, prefix.Length, original.Length);
        Buffer.BlockCopy(suffix, 0, wrapped, prefix.Length + original.Length, suffix.Length);
        content.Elements.Remove("/Filter");
        content.Elements.Remove("/DecodeParms");
        content.Stream!.Value = wrapped;
        content.Compressed = true;
    }

    private static XRect ToPdfSharpClip(PdfLayerJob layer, double pageWidth, double pageHeight)
    {
        var left = layer.ClipLeft * pageWidth;
        var top = (1 - layer.ClipTop) * pageHeight;
        var width = (layer.ClipRight - layer.ClipLeft) * pageWidth;
        var height = (layer.ClipTop - layer.ClipBottom) * pageHeight;
        return new XRect(left, top, width, height);
    }

    private static XGraphicsPath CreateClipPath(PdfLayerJob layer, double pageWidth, double pageHeight)
    {
        var path = new XGraphicsPath { FillMode = XFillMode.Winding };
        path.AddRectangle(ToPdfSharpClip(layer, pageWidth, pageHeight));
        if (layer.HasLabelClip)
        {
            path.AddRectangle(ToPdfSharpLabelClip(layer, pageWidth, pageHeight));
        }

        return path;
    }

    private static XRect ToPdfSharpLabelClip(PdfLayerJob layer, double pageWidth, double pageHeight)
    {
        var left = layer.LabelClipLeft * pageWidth;
        var top = (1 - layer.LabelClipTop) * pageHeight;
        var width = (layer.LabelClipRight - layer.LabelClipLeft) * pageWidth;
        var height = (layer.LabelClipTop - layer.LabelClipBottom) * pageHeight;
        return new XRect(left, top, width, height);
    }

    private static void EnsureOnePage(XPdfForm form, string path)
    {
        if (form.PageCount != 1)
        {
            throw new InvalidDataException($"Expected a one-page source PDF but '{path}' has {form.PageCount.ToString(CultureInfo.InvariantCulture)} pages.");
        }
    }

    private static void EnsureSamePageSize(PdfPage page, XPdfForm form, string path)
    {
        const double toleranceInPoints = 0.5;
        if (Math.Abs(page.Width.Point - form.PointWidth) > toleranceInPoints ||
            Math.Abs(page.Height.Point - form.PointHeight) > toleranceInPoints)
        {
            throw new InvalidDataException(
                $"Source PDF '{path}' is {form.PointWidth.ToString("0.##", CultureInfo.InvariantCulture)} x " +
                $"{form.PointHeight.ToString("0.##", CultureInfo.InvariantCulture)} points, but the current-sheet base is " +
                $"{page.Width.Point.ToString("0.##", CultureInfo.InvariantCulture)} x " +
                $"{page.Height.Point.ToString("0.##", CultureInfo.InvariantCulture)} points. " +
                "All selected sheets must use the same paper size and orientation.");
        }
    }

    private static List<PdfContent> GetContents(PdfContents contents)
    {
        var result = new List<PdfContent>();
        using var enumerator = contents.GetEnumerator();
        while (enumerator.MoveNext())
        {
            result.Add(enumerator.Current);
        }

        return result;
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Temporary cleanup must not turn a successfully composed PDF into a failure.
        }
    }
}
