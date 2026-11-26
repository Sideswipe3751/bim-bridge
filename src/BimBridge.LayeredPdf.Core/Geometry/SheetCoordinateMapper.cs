using System;

namespace BimBridge.LayeredPdf.Core.Geometry;

public static class SheetCoordinateMapper
{
    public static RectangleD ToNormalized(RectangleD sheetOutline, RectangleD itemOutline, double padding = 0)
    {
        if (sheetOutline.Width <= 0 || sheetOutline.Height <= 0)
        {
            throw new ArgumentException("Sheet outline must have a positive width and height.", nameof(sheetOutline));
        }

        var expanded = padding == 0 ? itemOutline : itemOutline.Expand(padding);
        var left = Clamp((expanded.Left - sheetOutline.Left) / sheetOutline.Width);
        var bottom = Clamp((expanded.Bottom - sheetOutline.Bottom) / sheetOutline.Height);
        var right = Clamp((expanded.Right - sheetOutline.Left) / sheetOutline.Width);
        var top = Clamp((expanded.Top - sheetOutline.Bottom) / sheetOutline.Height);
        return new RectangleD(left, bottom, right, top);
    }

    private static double Clamp(double value) => Math.Max(0, Math.Min(1, value));
}
