using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using BimBridge.LayeredPdf.Core.Geometry;

namespace BimBridge.Revit.LayeredPdf;

public sealed class ViewportLayer
{
    public ViewportLayer(
        ElementId viewportId,
        string name,
        RectangleD normalizedViewClip,
        RectangleD? normalizedLabelClip)
    {
        ViewportId = viewportId;
        Name = name;
        NormalizedViewClip = normalizedViewClip;
        NormalizedLabelClip = normalizedLabelClip;
    }

    public ElementId ViewportId { get; }

    public string Name { get; }

    public RectangleD NormalizedViewClip { get; }

    public RectangleD? NormalizedLabelClip { get; }

    public ViewportLayer WithName(string name) => new(
        ViewportId,
        name,
        NormalizedViewClip,
        NormalizedLabelClip);
}
