using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.Electrical;
using BimBridge.LayeredPdf.Core.Boxes;

namespace BimBridge.Revit.LayeredPdf;

public sealed class BoxLayerCandidates
{
    public List<long> ConduitIds { get; } = new();
    public List<long> BoxIds { get; } = new();
    public List<long> AmbiguousIds { get; } = new();
}

public static class BoxLayerProvider
{
    private static bool IsBox(Element element) => element is FamilyInstance instance &&
        BoxFamilyMatcher.Matches(element.Category?.Id.Value == (long)BuiltInCategory.OST_ConduitFitting,
            instance.Symbol.Family.Name);

    public static BoxLayerCandidates GetCandidates(Document document, ElementId viewId)
    {
        var result = new BoxLayerCandidates();
        var links = new FilteredElementCollector(document, viewId).OfClass(typeof(RevitLinkInstance))
            .Cast<RevitLinkInstance>().Where(l => l.GetLinkDocument() != null).ToList();
        // Only collectors scoped to this host view determine candidate visibility.
        var scopes = new List<Func<FilteredElementCollector>> { () => new FilteredElementCollector(document, viewId) };
        foreach (var link in links)
        {
            var linkId = link.Id;
            scopes.Add(() => new FilteredElementCollector(document, viewId, linkId));
        }
        foreach (var scope in scopes)
        {
            using var collector = scope();
            result.ConduitIds.AddRange(collector.OfClass(typeof(Conduit)).Select(e => e.Id.Value));
        }
        if (result.ConduitIds.Count == 0) return result;
        var candidates = new HashSet<long>();
        foreach (var scope in scopes)
        {
            using var collector = scope();
            foreach (var box in collector.OfCategory(BuiltInCategory.OST_ConduitFitting).WhereElementIsNotElementType().Where(IsBox))
                candidates.Add(box.Id.Value);
        }
        if (candidates.Count == 0) return result;
        // Native PDF tags contain raw element IDs but no link-instance identity.
        // If that ID also belongs to a visible non-box, never copy its paint.
        var ambiguous = new HashSet<long>();
        using var idFilter = new ElementIdSetFilter(candidates.Select(id => new ElementId(id)).ToList());
        foreach (var scope in scopes)
        {
            using var collector = scope();
            foreach (var element in collector.WherePasses(idFilter).WhereElementIsNotElementType())
                if (!IsBox(element)) ambiguous.Add(element.Id.Value);
        }
        result.BoxIds.AddRange(candidates.Where(id => !ambiguous.Contains(id)).OrderBy(id => id));
        result.AmbiguousIds.AddRange(ambiguous.OrderBy(id => id));
        return result;
    }
}
