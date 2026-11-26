using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Jobs;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using PdfSharp.Pdf.IO;
using System.Text;
using static BimBridge.LayeredPdf.Composer.ConduitPdfGeometry;

namespace BimBridge.LayeredPdf.Composer;

public static class ConduitPdfDecorator
{
    public static string CreateDecoratedCopy(string sourcePath, PdfLayerJob layer, ConduitPatternSettings settings, IList<string> report)
    {
        if (!settings.Enabled || layer.Conduits.Count == 0) return sourcePath;
        settings.Validate();
        var ids = layer.Conduits.Where(p => p.Symbol != ConduitSymbol.RevitDefault).Select(p => p.Identity).ToHashSet();
        if (ids.Count == 0) return sourcePath;
        if (string.IsNullOrEmpty(layer.ConduitGuidePdfPath) || !File.Exists(layer.ConduitGuidePdfPath))
            throw new InvalidDataException($"Conduit geometry guide is missing for '{layer.Name}'.");
        using var original = PdfReader.Open(sourcePath, PdfDocumentOpenMode.Modify);
        using var guide = PdfReader.Open(layer.ConduitGuidePdfPath, PdfDocumentOpenMode.Import);
        if (original.PageCount != 1 || guide.PageCount != 1 ||
            Math.Abs(original.Pages[0].Width.Point - guide.Pages[0].Width.Point) > .01 ||
            Math.Abs(original.Pages[0].Height.Point - guide.Pages[0].Height.Point) > .01)
            throw new InvalidDataException("Conduit guide and original PDF must have identical single-page coordinates.");
        var sourceGeometry = new ConduitPdfGeometry(original.Pages[0], layer.Conduits);
        var guideGeometry = new ConduitPdfGeometry(guide.Pages[0], layer.Conduits);
        var clipping = new Dictionary<int, List<Marker>>();
        var drawings = new Dictionary<int, List<(Marker Marker, ConduitStroke Stroke)>>();
        var ownedDrawings = new List<ConduitMarkerDrawing>();
        var marked = 0; var markers = 0;
        try
        {
            foreach (var pattern in layer.Conduits.Where(p => p.Symbol != ConduitSymbol.RevitDefault))
            {
                var source = sourceGeometry.Strokes.Where(s => s.Identity == pattern.Identity).ToList();
                var geometry = guideGeometry.Strokes.Where(s => s.Identity == pattern.Identity).ToList();
                void Skip(string reason) => report.Add($"{layer.Name} | {pattern.Description}: unchanged - {reason}");
                if (pattern.LinkInstanceId != 0 && !pattern.HasProjectedAxis) { Skip("unsupported linked conduit projection (straight, unsplit orthographic views are required)"); continue; }
                if (guideGeometry.ComplexElements.Contains(pattern.Identity) || sourceGeometry.ComplexElements.Contains(pattern.Identity))
                { Skip("complex, double-line or ambiguous overlapping geometry; original appearance preserved"); continue; }
                if (geometry.Count == 0 || source.Count == 0) { Skip("no supported visible line in the exported PDF"); continue; }
                var reference = geometry.OrderByDescending(s => s.Length).First();
                if (reference.Length <= .01) { Skip("no measurable line in the solid guide"); continue; }
                var axis = (reference.End - reference.Start) * (1 / reference.Length);
                if (axis.X < -.0001 || Math.Abs(axis.X) <= .0001 && axis.Y < 0) axis *= -1;
                var origin = reference.Start;
                bool OnAxis(ConduitStroke s) => Math.Abs((s.Start - origin).Cross(axis)) < .06 && Math.Abs((s.End - origin).Cross(axis)) < .06;
                if (!geometry.All(OnAxis) || !source.All(OnAxis)) { Skip("multiple projected edges or directions; original appearance preserved"); continue; }
                var drawing = new ConduitMarkerDrawing(pattern, settings); ownedDrawings.Add(drawing);
                var pad = 1.5 * 72 / 25.4;
                var required = drawing.Width + 2 * pad;
                var pitch = Math.Max(settings.RepeatDistanceMm * 72 / 25.4, required + pad);
                var count = 0;
                foreach (var clipGroup in geometry.GroupBy(s => s.State.ClipId))
                {
                    var intervals = clipGroup.Select(s => Interval(s, origin, axis)).OrderBy(v => v.Start).ToList();
                    var runs = new List<(double Start, double End)>();
                    foreach (var interval in intervals)
                    {
                        if (runs.Count > 0 && interval.Start <= runs[^1].End + .08)
                            runs[^1] = (runs[^1].Start, Math.Max(runs[^1].End, interval.End));
                        else runs.Add(interval);
                    }
                    foreach (var run in runs)
                    {
                        var length = run.End - run.Start;
                        if (length < required) continue;
                        var number = Math.Max(1, (int)Math.Floor((length - required) / pitch) + 1);
                        for (var i = 0; i < number; i++)
                        {
                            var t = (run.Start + run.End) / 2 + (i - (number - 1) / 2.0) * pitch;
                            var candidates = source.Where(s =>
                            {
                                var interval = Interval(s, origin, axis);
                                return interval.End >= run.Start - .06 && interval.Start <= run.End + .06;
                            }).ToList();
                            if (candidates.Count == 0) continue;
                            var anchor = candidates.OrderBy(s =>
                            {
                                var v = Interval(s, origin, axis); return Math.Max(v.Start - t, Math.Max(t - v.End, 0));
                            }).First();
                            if (!anchor.State.SupportedColor || anchor.State.StrokeAlpha <= 0) continue;
                            var center = origin + axis * t;
                            if (settings.Placement == MarkerPlacement.Beside)
                                center += new PdfPoint(-axis.Y, axis.X) * (drawing.Height / 2 + pad);
                            var marker = new Marker(center, axis, drawing);
                            if (!drawings.TryGetValue(anchor.EndIndex, out var list)) drawings[anchor.EndIndex] = list = new();
                            list.Add((marker, anchor));
                            if (settings.Placement == MarkerPlacement.Inline)
                            {
                                foreach (var s in candidates)
                                {
                                    var v = Interval(s, origin, axis);
                                    if (v.Start > t + required / 2 || v.End < t - required / 2) continue;
                                    if (!clipping.TryGetValue(s.StartIndex, out var holes)) clipping[s.StartIndex] = holes = new();
                                    holes.Add(marker);
                                }
                            }
                            count++;
                        }
                    }
                }
                if (count == 0) Skip("too short for a complete marker, or unsupported print color");
                else { marked++; markers += count; report.Add($"{layer.Name} | {pattern.Description}: {pattern.Symbol} + {pattern.Label}, {count} markers"); }
            }
            report.Add($"{layer.Name}: {marked}/{ids.Count} requested conduits marked; {markers} marker groups.");
            if (markers == 0) return sourcePath;
            var starts = sourceGeometry.Strokes.ToDictionary(s => s.StartIndex);
            var result = new CSequence();
            void Append(string commands) { foreach (var item in ContentReader.ReadContent(Encoding.ASCII.GetBytes(commands))) result.Add(item); }
            var alphaNames = new Dictionary<double, string>();
            string Alpha(double opacity)
            {
                if (alphaNames.TryGetValue(opacity, out var name)) return name;
                var resources = original.Pages[0].Resources;
                var states = resources.Elements.GetDictionary("/ExtGState");
                if (states == null) { states = new PdfDictionary(original); resources.Elements["/ExtGState"] = states; }
                name = "LPConduitAlpha" + alphaNames.Count;
                while (states.Elements.ContainsKey("/" + name)) name += "x";
                var state = new PdfDictionary(original); state.Elements.SetReal("/ca", opacity); state.Elements.SetReal("/CA", opacity);
                original.Internals.AddObject(state); states.Elements["/" + name] = state.Reference!; alphaNames[opacity] = name; return name;
            }
            for (var i = 0; i < sourceGeometry.Content.Count; i++)
            {
                var end = i;
                if (clipping.TryGetValue(i, out var holes))
                {
                    var stroke = starts[i]; Append(ClipHoles(stroke, holes));
                    for (; i <= stroke.EndIndex; i++) result.Add(sourceGeometry.Content[i]);
                    i--; end = i; Append("Q\n");
                }
                else result.Add(sourceGeometry.Content[i]);
                if (drawings.TryGetValue(end, out var groups))
                    foreach (var (marker, stroke) in groups) Append(marker.Drawing.Draw(marker.Center, marker.Axis, stroke.State, Alpha(stroke.State.StrokeAlpha)));
            }
            original.Pages[0].Contents.ReplaceContent(result);
            var path = sourcePath + ".conduits.pdf"; original.Save(path); return path;
        }
        finally { foreach (var drawing in ownedDrawings) drawing.Dispose(); }
    }

    private static (double Start, double End) Interval(ConduitStroke s, PdfPoint origin, PdfPoint axis)
    {
        var a = (s.Start - origin).Dot(axis); var b = (s.End - origin).Dot(axis); return (Math.Min(a, b), Math.Max(a, b));
    }
    private static string ClipHoles(ConduitStroke stroke, IEnumerable<Marker> markers)
    {
        var start = stroke.State.Matrix.Inverse(stroke.Start);
        var end = stroke.State.Matrix.Inverse(stroke.End);
        var margin = Math.Max(100, stroke.State.LineWidth * 4);
        var b = new StringBuilder($"q\n{N(Math.Min(start.X, end.X) - margin)} {N(Math.Min(start.Y, end.Y) - margin)} {N(Math.Abs(start.X - end.X) + 2 * margin)} {N(Math.Abs(start.Y - end.Y) + 2 * margin)} re\n");
        foreach (var marker in markers)
        {
            var normal = new PdfPoint(-marker.Axis.Y, marker.Axis.X);
            var w = marker.Drawing.Width / 2 + 1.5;
            var h = Math.Max(marker.Drawing.Height / 2 + 1.5, stroke.State.LineWidth * stroke.State.Matrix.Scale);
            var corners = new[] { new PdfPoint(-w, -h), new PdfPoint(-w, h), new PdfPoint(w, h), new PdfPoint(w, -h) };
            for (var i = 0; i < 4; i++)
            {
                var p = stroke.State.Matrix.Inverse(marker.Center + marker.Axis * corners[i].X + normal * corners[i].Y);
                b.AppendLine($"{N(p.X)} {N(p.Y)} {(i == 0 ? "m" : "l")}");
            }
            b.AppendLine("h");
        }
        b.AppendLine("W* n"); return b.ToString();
    }
    private sealed record Marker(PdfPoint Center, PdfPoint Axis, ConduitMarkerDrawing Drawing);
}
