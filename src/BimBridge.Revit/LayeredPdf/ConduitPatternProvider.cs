using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.Electrical;
using BimBridge.LayeredPdf.Core.Conduits;
using System.Globalization;
using System.IO;

namespace BimBridge.Revit.LayeredPdf;

public static class ConduitPatternProvider
{
    public static string GetStandard(Document doc, Conduit conduit)
    {
        var parameter = doc.GetElement(conduit.GetTypeId()).get_Parameter(BuiltInParameter.CONDUIT_STANDARD_TYPE_PARAM);
        if (parameter == null) return "Unknown";
        // Revit 2024 stores Standard as an ElementId, not a string parameter.
        if (parameter.StorageType == StorageType.ElementId)
            return doc.GetElement(parameter.AsElementId())?.Name ?? parameter.AsValueString() ?? "Unknown";
        return parameter.AsString() ?? parameter.AsValueString() ?? "Unknown";
    }

    public static List<ConduitElementPattern> GetElements(Document document, ViewSheet sheet, Viewport viewport, ConduitPatternSettings settings, bool diagnostics = false)
    {
        var result = new List<ConduitElementPattern>();
        if (!settings.Enabled && !diagnostics) return result;
        var view = (View)document.GetElement(viewport.ViewId);
        Transform? projection = null;
        try
        {
            var regions = view.GetModelToProjectionTransforms();
            if (regions.Count == 1) projection = viewport.GetProjectionToSheetTransform().Multiply(regions[0].GetModelToProjectionTransform());
        }
        catch (Autodesk.Revit.Exceptions.InvalidOperationException) { /* Unsupported projections remain unchanged. */ }
        void Collect(Document source, IEnumerable<Conduit> conduits, long linkId, Transform modelTransform)
        {
            foreach (var conduit in conduits)
            {
                var diameter = conduit.get_Parameter(BuiltInParameter.RBS_CONDUIT_DIAMETER_PARAM);
                if (diameter?.HasValue != true) continue;
                var mm = UnitUtils.ConvertFromInternalUnits(diameter.AsDouble(), UnitTypeId.Millimeters);
                var standard = GetStandard(source, conduit);
                var rule = settings.Match(standard, mm);
                // Default entries also participate in ownership matching when host/link IDs collide.
                var pattern = new ConduitElementPattern
                {
                    ElementId = conduit.Id.Value,
                    LinkInstanceId = linkId,
                    SourceDocument = source.Title,
                    Standard = standard,
                    NominalDiameterMm = mm,
                    DisplayDiameter = diameter.AsValueString() ?? string.Empty,
                    HasMatchingRule = rule != null,
                    Symbol = rule?.Symbol ?? ConduitSymbol.RevitDefault,
                    Label = string.IsNullOrWhiteSpace(rule?.Label) ? mm.ToString("0.###", CultureInfo.InvariantCulture) : rule!.Label
                };
                if (projection != null && conduit.Location is LocationCurve location && location.Curve is Line)
                {
                    var transform = projection.Multiply(modelTransform);
                    var a = transform.OfPoint(location.Curve.GetEndPoint(0));
                    var b = transform.OfPoint(location.Curve.GetEndPoint(1));
                    var bounds = sheet.Outline;
                    pattern.StartX = (a.X - bounds.Min.U) / (bounds.Max.U - bounds.Min.U);
                    pattern.StartY = (a.Y - bounds.Min.V) / (bounds.Max.V - bounds.Min.V);
                    pattern.EndX = (b.X - bounds.Min.U) / (bounds.Max.U - bounds.Min.U);
                    pattern.EndY = (b.Y - bounds.Min.V) / (bounds.Max.V - bounds.Min.V);
                    pattern.HasProjectedAxis = true;
                }
                result.Add(pattern);
            }
        }
        Collect(document, new FilteredElementCollector(document, view.Id).OfClass(typeof(Conduit)).Cast<Conduit>(), 0, Transform.Identity);
        foreach (var link in new FilteredElementCollector(document, view.Id).OfClass(typeof(RevitLinkInstance)).Cast<RevitLinkInstance>())
        {
            var linked = link.GetLinkDocument();
            if (linked == null) continue;
            Collect(linked, new FilteredElementCollector(document, view.Id, link.Id).OfClass(typeof(Conduit)).Cast<Conduit>(), link.Id.Value, link.GetTotalTransform());
        }
        // Do not request an auxiliary PDF when all visible sizes use Revit default.
        if (!diagnostics && !result.Any(p => p.Symbol != ConduitSymbol.RevitDefault)) result.Clear();
        return result;
    }
}
