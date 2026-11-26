using BimBridge.LayeredPdf.Core.Conduits;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Text;
using static BimBridge.LayeredPdf.Composer.ConduitPdfGeometry;

namespace BimBridge.LayeredPdf.Composer;

internal sealed class ConduitMarkerDrawing : IDisposable
{
    private readonly GraphicsPath _text = new();
    private readonly RectangleF _bounds;
    private readonly double _diameter;
    private readonly ConduitSymbol _symbol;
    public double Width { get; }
    public double Height { get; }
    public ConduitMarkerDrawing(ConduitElementPattern pattern, ConduitPatternSettings settings)
    {
        _symbol = pattern.Symbol; _diameter = settings.SymbolSizeMm * 72 / 25.4;
        using var family = new FontFamily("Arial");
        _text.AddString(pattern.Label, family, (int)FontStyle.Regular, (float)settings.TextSizePoints, PointF.Empty, StringFormat.GenericTypographic);
        _bounds = _text.PointCount > 0 ? _text.GetBounds() : RectangleF.Empty;
        Width = _diameter + 2.5 + _bounds.Width;
        Height = Math.Max(_diameter, _bounds.Height);
    }

    public string Draw(PdfPoint center, PdfPoint axis, ConduitStrokeState state, string alphaName)
    {
        var b = new StringBuilder("q\n[] 0 d\n0 J 0 j\n");
        b.AppendLine(state.FillColor);
        b.AppendLine($"/{alphaName} gs");
        var normal = new PdfPoint(-axis.Y, axis.X);
        PdfPoint Map(double x, double y) => state.Matrix.Inverse(center + axis * x + normal * y);
        void Move(double x, double y) { var p = Map(x, y); b.AppendLine($"{N(p.X)} {N(p.Y)} m"); }
        void Line(double x, double y) { var p = Map(x, y); b.AppendLine($"{N(p.X)} {N(p.Y)} l"); }
        void Curve(double x1, double y1, double x2, double y2, double x3, double y3)
        {
            var a = Map(x1, y1); var p = Map(x2, y2); var q = Map(x3, y3);
            b.AppendLine($"{N(a.X)} {N(a.Y)} {N(p.X)} {N(p.Y)} {N(q.X)} {N(q.Y)} c");
        }
        var r = _diameter / 2; var x = -Width / 2 + r;
        void Poly(IEnumerable<PdfPoint> points)
        {
            var ps = points.ToArray(); Move(x + ps[0].X, ps[0].Y);
            foreach (var p in ps.Skip(1)) Line(x + p.X, p.Y);
            b.AppendLine("h S");
        }
        void Segment(double a, double v, double d, double e) { Move(x + a, v); Line(x + d, e); b.AppendLine("S"); }
        void Open(params PdfPoint[] points)
        {
            Move(x + points[0].X, points[0].Y);
            foreach (var p in points.Skip(1)) Line(x + p.X, p.Y);
            b.AppendLine("S");
        }
        switch (_symbol)
        {
            case ConduitSymbol.Circle:
                const double k = .552284749831;
                Move(x + r, 0); Curve(x + r, k * r, x + k * r, r, x, r); Curve(x - k * r, r, x - r, k * r, x - r, 0);
                Curve(x - r, -k * r, x - k * r, -r, x, -r); Curve(x + k * r, -r, x + r, -k * r, x + r, 0); b.AppendLine("h S"); break;
            case ConduitSymbol.Triangle: Poly(new[] { new PdfPoint(0, r), new PdfPoint(-r, -r), new PdfPoint(r, -r) }); break;
            case ConduitSymbol.Square: Poly(new[] { new PdfPoint(-r, -r), new PdfPoint(-r, r), new PdfPoint(r, r), new PdfPoint(r, -r) }); break;
            case ConduitSymbol.Diamond: Poly(new[] { new PdfPoint(0, r), new PdfPoint(r, 0), new PdfPoint(0, -r), new PdfPoint(-r, 0) }); break;
            case ConduitSymbol.Hexagon: Poly(Enumerable.Range(0, 6).Select(i => new PdfPoint(r * Math.Cos(i * Math.PI / 3), r * Math.Sin(i * Math.PI / 3)))); break;
            case ConduitSymbol.Cross: Segment(-r, -r, r, r); Segment(-r, r, r, -r); break;
            case ConduitSymbol.Plus: Segment(-r, 0, r, 0); Segment(0, -r, 0, r); break;
            case ConduitSymbol.DoubleSlash: Segment(-r, -r, 0, r); Segment(0, -r, r, r); break;
            case ConduitSymbol.DoubleBar: Segment(-r * .55, -r, -r * .55, r); Segment(r * .55, -r, r * .55, r); break;
            case ConduitSymbol.Star: Poly(Enumerable.Range(0, 10).Select(i => new PdfPoint((i % 2 == 0 ? r : r * .43) * Math.Cos(Math.PI / 2 + i * Math.PI / 5), (i % 2 == 0 ? r : r * .43) * Math.Sin(Math.PI / 2 + i * Math.PI / 5)))); break;
            case ConduitSymbol.DownTriangle: Poly(new[] { new PdfPoint(-r, r), new PdfPoint(r, r), new PdfPoint(0, -r) }); break;
            case ConduitSymbol.Chevron: Open(new(-r, r), new(r, 0), new(-r, -r)); break;
            case ConduitSymbol.DoubleChevron:
                Open(new(-r, r), new(0, 0), new(-r, -r));
                Open(new(0, r), new(r, 0), new(0, -r)); break;
            case ConduitSymbol.Arrow:
                Segment(-r, 0, r, 0); Open(new(0, r), new(r, 0), new(0, -r)); break;
            case ConduitSymbol.Tee: Segment(-r, r, r, r); Segment(0, -r, 0, r); break;
            case ConduitSymbol.IBeam:
                Segment(-r, r, r, r); Segment(0, -r, 0, r); Segment(-r, -r, r, -r); break;
            case ConduitSymbol.Hourglass: Poly(new[] { new PdfPoint(-r, r), new PdfPoint(r, r), new PdfPoint(-r, -r), new PdfPoint(r, -r) }); break;
            case ConduitSymbol.BowTie: Poly(new[] { new PdfPoint(-r, -r), new PdfPoint(-r, r), new PdfPoint(r, -r), new PdfPoint(r, r) }); break;
            case ConduitSymbol.Brackets:
                Open(new(-r * .4, -r), new(-r, -r), new(-r, r), new(-r * .4, r));
                Open(new(r * .4, -r), new(r, -r), new(r, r), new(r * .4, r)); break;
            case ConduitSymbol.Zigzag: Open(new(-r, -r), new(-r / 3, r), new(r / 3, -r), new(r, r)); break;
            default: throw new InvalidOperationException($"No custom marker drawing is defined for {_symbol}.");
        }
        // Outlined text avoids PDF font substitution and supports user-entered fractions/units.
        var pts = _text.PathPoints; var types = _text.PathTypes;
        PdfPoint TextPoint(int i) => new(-Width / 2 + _diameter + 2.5 + pts[i].X - _bounds.Left, _bounds.Top + _bounds.Height / 2 - pts[i].Y);
        for (var i = 0; i < pts.Length; i++)
        {
            var p = TextPoint(i); var type = types[i] & 7;
            if (type == 0) Move(p.X, p.Y);
            else if (type == 1) Line(p.X, p.Y);
            else if (type == 3)
            {
                var p2 = TextPoint(i + 1); var p3 = TextPoint(i + 2); Curve(p.X, p.Y, p2.X, p2.Y, p3.X, p3.Y); i += 2;
            }
            if ((types[i] & 128) != 0) b.AppendLine("h");
        }
        b.AppendLine("f\nQ"); return b.ToString();
    }
    public void Dispose() => _text.Dispose();
}
