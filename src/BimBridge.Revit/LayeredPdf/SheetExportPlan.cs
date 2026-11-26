using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using BimBridge.LayeredPdf.Core.Geometry;
using BimBridge.LayeredPdf.Core.Naming;

namespace BimBridge.Revit.LayeredPdf;

public sealed class SheetExportPlan
{
    private SheetExportPlan(IReadOnlyList<ViewportLayer> layers)
    {
        Layers = layers;
    }

    public IReadOnlyList<ViewportLayer> Layers { get; }

    public static SheetExportPlan Create(Document document, ViewSheet sheet)
    {
        var sheetOutline = ToRectangle(sheet.Outline);
        const double clipPaddingInFeet = 1.0 / 192.0;
        var layers = sheet.GetAllViewports()
            .Select(id => document.GetElement(id))
            .OfType<Viewport>()
            .Where(viewport => !viewport.IsHidden(sheet))
            .Select(viewport => CreateLayer(document, sheet, viewport, sheetOutline, clipPaddingInFeet))
            .ToList();
        var uniqueNames = LayerNameBuilder.MakeUnique(layers.Select(layer => layer.Name));
        var uniquelyNamedLayers = layers
            .Select((layer, index) => layer.WithName(uniqueNames[index]))
            .ToList();
        return new SheetExportPlan(uniquelyNamedLayers);
    }

    private static ViewportLayer CreateLayer(
        Document document,
        ViewSheet sheet,
        Viewport viewport,
        RectangleD sheetOutline,
        double padding)
    {
        if (!viewport.CanBeHidden(sheet))
        {
            throw new InvalidOperationException($"Viewport {viewport.Id.Value} cannot be temporarily hidden on this sheet.");
        }

        var view = document.GetElement(viewport.ViewId) as View
            ?? throw new InvalidOperationException($"Viewport {viewport.Id.Value} does not reference a valid view.");
        var detailNumber = viewport.get_Parameter(BuiltInParameter.VIEWPORT_DETAIL_NUMBER)?.AsString();
        var name = LayerNameBuilder.Build(detailNumber, view.Name);
        var box = ToRectangle(viewport.GetBoxOutline());
        var label = ToRectangle(viewport.GetLabelOutline());
        var normalizedViewClip = SheetCoordinateMapper.ToNormalized(sheetOutline, box, padding);
        var candidateLabelClip = label.Width > 0 && label.Height > 0
            ? SheetCoordinateMapper.ToNormalized(sheetOutline, label, padding)
            : new RectangleD(0, 0, 0, 0);
        var normalizedLabelClip = candidateLabelClip.Width > 0 && candidateLabelClip.Height > 0
            ? candidateLabelClip
            : (RectangleD?)null;
        return new ViewportLayer(viewport.Id, name, normalizedViewClip, normalizedLabelClip);
    }

    private static RectangleD ToRectangle(BoundingBoxUV box) => new(
        box.Min.U,
        box.Min.V,
        box.Max.U,
        box.Max.V);

    private static RectangleD ToRectangle(Outline outline) => new(
        outline.MinimumPoint.X,
        outline.MinimumPoint.Y,
        outline.MaximumPoint.X,
        outline.MaximumPoint.Y);
}
