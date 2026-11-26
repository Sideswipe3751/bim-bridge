using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using System.Globalization;
using BimBridge.LayeredPdf.Core.Conduits;

namespace BimBridge.LayeredPdf.Composer;

internal readonly record struct PdfPoint(double X, double Y)
{
    public static PdfPoint operator +(PdfPoint a, PdfPoint b) => new(a.X + b.X, a.Y + b.Y);
    public static PdfPoint operator -(PdfPoint a, PdfPoint b) => new(a.X - b.X, a.Y - b.Y);
    public static PdfPoint operator *(PdfPoint a, double s) => new(a.X * s, a.Y * s);
    public double Length => Math.Sqrt(X * X + Y * Y);
    public double Dot(PdfPoint b) => X * b.X + Y * b.Y;
    public double Cross(PdfPoint b) => X * b.Y - Y * b.X;
}

internal readonly record struct PdfMatrix(double A, double B, double C, double D, double E, double F)
{
    public static PdfMatrix Identity => new(1, 0, 0, 1, 0, 0);
    public PdfPoint Apply(PdfPoint p) => new(A * p.X + C * p.Y + E, B * p.X + D * p.Y + F);
    public PdfMatrix Multiply(PdfMatrix m) => new(A * m.A + C * m.B, B * m.A + D * m.B, A * m.C + C * m.D, B * m.C + D * m.D, A * m.E + C * m.F + E, B * m.E + D * m.F + F);
    public PdfPoint Inverse(PdfPoint p)
    {
        var det = A * D - B * C;
        return new((D * (p.X - E) - C * (p.Y - F)) / det, (-B * (p.X - E) + A * (p.Y - F)) / det);
    }
    public double Scale => Math.Sqrt(A * A + B * B);
    public bool IsUniform => Scale > 1e-8 && Math.Abs(A * C + B * D) < 1e-6 && Math.Abs(Scale - Math.Sqrt(C * C + D * D)) < 1e-6;
}

internal sealed class ConduitStrokeState
{
    public PdfMatrix Matrix { get; set; } = PdfMatrix.Identity;
    public string FillColor { get; set; } = "0 g";
    public bool SupportedColor { get; set; } = true;
    public double LineWidth { get; set; } = 1;
    public double StrokeAlpha { get; set; } = 1;
    public int ClipId { get; set; }
    public ConduitStrokeState Clone() => (ConduitStrokeState)MemberwiseClone();
}

internal sealed record ConduitStroke(string Identity, int StartIndex, int EndIndex, PdfPoint Start, PdfPoint End, ConduitStrokeState State)
{
    public double Length => (End - Start).Length;
}

internal sealed class ConduitPdfGeometry
{
    public CSequence Content { get; }
    public List<ConduitStroke> Strokes { get; } = new();
    public HashSet<string> ComplexElements { get; } = new();
    public static string N(double v) => v.ToString("0.######", CultureInfo.InvariantCulture);
    private static double Number(CObject o) => o switch { CInteger i => i.Value, CReal r => r.Value, _ => throw new InvalidDataException("Invalid PDF number.") };

    public ConduitPdfGeometry(PdfPage page, IReadOnlyList<ConduitElementPattern> patterns)
    {
        var candidates = patterns.GroupBy(p => p.ElementId).ToDictionary(g => g.Key, g => g.ToList());
        string? Resolve(long id, IReadOnlyList<PdfPoint> path)
        {
            var choices = candidates[id];
            if (choices.Count == 1 && !choices[0].HasProjectedAxis && choices[0].LinkInstanceId == 0) return choices[0].Identity;
            var matching = choices.Where(p => p.HasProjectedAxis && MatchesProjection(p, path, page)).ToList();
            if (matching.Count == 1) return matching[0].Identity;
            // Revit's flat Element tags do not encode link instance identity. Never
            // guess when multiple projected elements occupy the same printed segment.
            foreach (var match in matching) ComplexElements.Add(match.Identity);
            return null;
        }
        Content = ContentReader.ReadContent(page);
        var state = new ConduitStrokeState();
        var states = new Stack<ConduitStrokeState>();
        var tags = new Stack<long?>();
        long? element = null;
        var points = new List<PdfPoint>();
        var pathStart = -1; var straight = true; var clipCounter = 0; var subpaths = 0;
        for (var i = 0; i < Content.Count; i++)
        {
            if (Content[i] is not COperator op) continue;
            double V(int j) => Number(op.Operands[j]);
            switch (op.Name)
            {
                case "BMC":
                case "BDC":
                    tags.Push(element);
                    if (element == null && op.Operands.Count > 0 && op.Operands[0] is CName name &&
                        name.Name.StartsWith("/Element", StringComparison.Ordinal) && long.TryParse(name.Name.Substring(8), out var id))
                        element = id; // Nested element IDs in linked/family content cannot impersonate the host element.
                    break;
                case "EMC": element = tags.Count > 0 ? tags.Pop() : null; break;
                case "q": states.Push(state.Clone()); break;
                case "Q": if (states.Count == 0) throw new InvalidDataException("Unbalanced PDF graphics state."); state = states.Pop(); break;
                case "cm": state.Matrix = state.Matrix.Multiply(new PdfMatrix(V(0), V(1), V(2), V(3), V(4), V(5))); break;
                case "w": state.LineWidth = V(0); break;
                case "G": state.FillColor = $"{N(V(0))} g"; state.SupportedColor = true; break;
                case "RG": state.FillColor = $"{N(V(0))} {N(V(1))} {N(V(2))} rg"; state.SupportedColor = true; break;
                case "K": state.FillColor = $"{N(V(0))} {N(V(1))} {N(V(2))} {N(V(3))} k"; state.SupportedColor = true; break;
                case "CS": case "SC": case "SCN": state.SupportedColor = false; break;
                case "gs":
                    if (op.Operands[0] is CName gsName)
                    {
                        var gs = page.Resources.Elements.GetDictionary("/ExtGState")?.Elements.GetDictionary(gsName.Name);
                        if (gs is null) state.SupportedColor = false;
                        else
                        {
                            if (gs.Elements.ContainsKey("/CA")) state.StrokeAlpha = gs.Elements.GetReal("/CA");
                            if (gs.Elements.ContainsKey("/LW")) state.LineWidth = gs.Elements.GetReal("/LW");
                        }
                    }
                    break;
                case "m":
                    if (pathStart < 0) pathStart = i;
                    subpaths++; points.Add(state.Matrix.Apply(new PdfPoint(V(0), V(1)))); break;
                case "l": points.Add(state.Matrix.Apply(new PdfPoint(V(0), V(1)))); break;
                case "re":
                case "c":
                case "v":
                case "y":
                case "h":
                    if (pathStart < 0) pathStart = i;
                    straight = false; break;
                case "W": case "W*": state.ClipId = ++clipCounter; break;
                case "S":
                case "s":
                case "f":
                case "F":
                case "f*":
                case "B":
                case "B*":
                case "b":
                case "b*":
                case "n":
                    if (element.HasValue && candidates.ContainsKey(element.Value) && op.Name != "n")
                    {
                        var delta = points.Count >= 2 ? points[points.Count - 1] - points[0] : new PdfPoint();
                        var contiguous = pathStart >= 0 && Enumerable.Range(pathStart, i - pathStart).All(j =>
                            Content[j] is COperator p && (p.Name == "m" || p.Name == "l"));
                        // A zero-length round-cap stroke is a legitimate dot in a Revit line pattern.
                        if (op.Name == "S" && straight && subpaths == 1 && points.Count > 0 && contiguous &&
                            points.All(p => delta.Length <= .01 ? (p - points[0]).Length <= .01 :
                                Math.Abs((p - points[0]).Cross(delta)) / delta.Length < .03) && state.Matrix.IsUniform)
                        {
                            var identity = Resolve(element.Value, points);
                            if (identity != null) Strokes.Add(new ConduitStroke(identity, pathStart, i, points[0], points[points.Count - 1], state.Clone()));
                        }
                        else foreach (var candidate in candidates[element.Value]) ComplexElements.Add(candidate.Identity);
                    }
                    points.Clear(); pathStart = -1; straight = true; subpaths = 0; break;
                case "Do":
                    if (element.HasValue && candidates.TryGetValue(element.Value, out var affected))
                        foreach (var candidate in affected) ComplexElements.Add(candidate.Identity);
                    break;
            }
        }
        if (tags.Count != 0 || states.Count != 0) throw new InvalidDataException("Unbalanced Revit PDF content.");
    }

    private static bool MatchesProjection(ConduitElementPattern pattern, IReadOnlyList<PdfPoint> path, PdfPage page)
    {
        var box = page.MediaBox;
        var start = new PdfPoint(box.X1 + pattern.StartX * box.Width, box.Y1 + pattern.StartY * box.Height);
        var end = new PdfPoint(box.X1 + pattern.EndX * box.Width, box.Y1 + pattern.EndY * box.Height);
        var delta = end - start;
        if (delta.Length < .01 || path.Count == 0) return false;
        var axis = delta * (1 / delta.Length);
        // Native sheet-size PDFs round their page dimensions independently of
        // the model projection. On large sheets this caused sub-point offsets
        // to reject long, valid runs. Revit also extends printed conduit ends
        // into connection symbols beyond LocationCurve's projected endpoints.
        // Keep both allowances bounded in paper units. ID ownership still has
        // to be unique; close host/link candidates are rejected by Resolve.
        const double axisTolerance = .2 * 72 / 25.4; // 0.2 mm on paper
        var endTolerance = Math.Min(1.5 * 72 / 25.4, delta.Length * .2);
        endTolerance = Math.Max(axisTolerance, endTolerance);
        var positions = path.Select(p => (p - start).Dot(axis)).ToList();
        return path.All(p => Math.Abs((p - start).Cross(axis)) <= axisTolerance) &&
            positions.Min() >= -endTolerance && positions.Max() <= delta.Length + endTolerance &&
            positions.Max() >= 0 && positions.Min() <= delta.Length;
    }
}
