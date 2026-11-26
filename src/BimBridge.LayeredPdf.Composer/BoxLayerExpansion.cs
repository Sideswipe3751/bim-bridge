using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using PdfSharp.Pdf.IO;

namespace BimBridge.LayeredPdf.Composer;

internal sealed class BoxLayerExpansion : IDisposable
{
    public List<PdfLayerJob> Layers { get; } = new();
    public List<string> Report { get; } = new()
    {
        "BOX layers duplicate printed Conduit Fittings with 'box' in the family name (case-insensitive). Original view layers are retained.",
        "Host and directly linked models are included. Views without printed conduit or printed boxes do not create an empty BOX layer."
    };
    private readonly List<string> _temporaryFiles = new();

    public static BoxLayerExpansion Create(LayeredPdfJob job)
    {
        var result = new BoxLayerExpansion();
        try
        {
            foreach (var layer in job.Layers)
            {
                result.Layers.Add(layer);
                if (!job.CreateBoxLayers) continue;
                if (layer.AmbiguousBoxElementIds.Count > 0)
                    result.Report.Add($"{layer.Name}: skipped ambiguous host/link element IDs: {string.Join(", ", layer.AmbiguousBoxElementIds)}.");
                if (layer.BoxConduitElementIds.Count == 0)
                {
                    result.Report.Add($"{layer.Name}: no visible conduit candidates; no BOX layer.");
                    continue;
                }
                var ids = layer.BoxElementIds.Except(layer.ExcludedElementIds).Except(layer.AmbiguousBoxElementIds).ToHashSet();
                if (ids.Count == 0)
                {
                    result.Report.Add($"{layer.Name}: no matching box candidates; no BOX layer.");
                    continue;
                }
                var (path, count, hasConduit) = Extract(layer.SourcePdfPath, ids, layer.BoxConduitElementIds.ToHashSet());
                if (path == null)
                {
                    result.Report.Add($"{layer.Name}: {(hasConduit ? "no printed boxes" : "no printed conduit")}; no BOX layer.");
                    continue;
                }
                result._temporaryFiles.Add(path);
                var name = string.IsNullOrWhiteSpace(layer.BoxLayerName) ? layer.Name + " BOX" : layer.BoxLayerName;
                result.Layers.Add(new PdfLayerJob
                {
                    Name = name, GroupName = layer.GroupName, SourcePdfPath = path,
                    ClipLeft = layer.ClipLeft, ClipBottom = layer.ClipBottom, ClipRight = layer.ClipRight, ClipTop = layer.ClipTop,
                    HasLabelClip = layer.HasLabelClip, LabelClipLeft = layer.LabelClipLeft, LabelClipBottom = layer.LabelClipBottom,
                    LabelClipRight = layer.LabelClipRight, LabelClipTop = layer.LabelClipTop
                });
                result.Report.Add($"{layer.Name}: created {name}; copied {count} printed box element IDs; group: {(string.IsNullOrEmpty(layer.GroupName) ? "(ungrouped)" : layer.GroupName)}.");
            }
            if (job.CreateBoxLayers) result.Report.Add($"Created {result.Layers.Count - job.Layers.Count} BOX layers.");
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    private static (string? Path, int Count, bool HasConduit) Extract(string source, HashSet<long> boxes, HashSet<long> conduits)
    {
        using var document = PdfReader.Open(source, PdfDocumentOpenMode.Modify);
        if (document.PageCount != 1) throw new InvalidDataException("BOX extraction requires a single-page source PDF.");
        var page = document.Pages[0];
        var content = ContentReader.ReadContent(page);
        var filtered = new CSequence();
        var tags = new Stack<long?>();
        long? element = null;
        var printedBoxes = new HashSet<long>();
        var printedConduit = false;
        var graphicsDepth = 0;
        foreach (var item in content)
        {
            if (item is not COperator op) { filtered.Add(item); continue; }
            if (op.Name is "BMC" or "BDC")
            {
                tags.Push(element);
                // Keep ownership of the outermost element; nested family tags
                // cannot promote a non-box element to a selected box.
                if (element == null && op.Operands.Count > 0 && op.Operands[0] is CName name &&
                    name.Name.StartsWith("/Element", StringComparison.Ordinal) && long.TryParse(name.Name.Substring(8), out var id))
                    element = id;
            }
            else if (op.Name == "EMC")
            {
                if (tags.Count == 0) throw new InvalidDataException("Unbalanced PDF marked content during BOX extraction.");
                element = tags.Pop();
            }
            if (op.Name == "q") graphicsDepth++;
            if (op.Name == "Q" && --graphicsDepth < 0) throw new InvalidDataException("Unbalanced PDF graphics state during BOX extraction.");
            var selected = element.HasValue && boxes.Contains(element.Value);
            var paints = op.Name is "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "Do" or "sh" or "Tj" or "TJ" or "'" or "\"";
            if (paints && element.HasValue)
            {
                if (selected) printedBoxes.Add(element.Value);
                if (conduits.Contains(element.Value)) printedConduit = true;
            }
            // Graphics transforms, clipping, color, line weight and text position
            // are shared across Revit elements and must survive filtering.
            if (selected) filtered.Add(op);
            else RevitElementContentStripper.SuppressPainting(filtered, op);
        }
        if (tags.Count != 0 || graphicsDepth != 0) throw new InvalidDataException("Unbalanced Revit source PDF during BOX extraction.");
        if (!printedConduit || printedBoxes.Count == 0) return (null, printedBoxes.Count, printedConduit);
        page.Contents.ReplaceContent(filtered);
        var path = source + ".boxes-" + Guid.NewGuid().ToString("N") + ".pdf";
        try { document.Save(path); }
        catch { if (File.Exists(path)) File.Delete(path); throw; }
        return (path, printedBoxes.Count, true);
    }

    public void Dispose()
    {
        foreach (var file in _temporaryFiles)
            try { File.Delete(file); } catch { /* Cleanup must not obscure the export result. */ }
    }
}
