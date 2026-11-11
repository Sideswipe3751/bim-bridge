using System;
using System.Linq;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.Electrical;
using BimBridge.Host;

namespace BimBridge.Revit;

internal static class RevitConduitService
{
    public static object Execute(Document document, ConnectorRequest request)
    {
        var options = request.Conduit ?? throw new InvalidOperationException("Conduit options are required");
        var first = GetConduit(document, options.FirstId);
        var second = GetConduit(document, options.SecondId);
        var firstAxis = GetAxis(first);
        var secondAxis = GetAxis(second);
        if (request.Operation == "conduit.ends")
            return new { first = Describe(first, firstAxis), second = Describe(second, secondAxis) };

        int firstEnd = options.FirstEnd ?? throw new InvalidOperationException("firstEnd is required");
        int secondEnd = options.SecondEnd ?? throw new InvalidOperationException("secondEnd is required");
        var created = ConduitRouter.Connect(
            document, first, firstAxis.GetEndPoint(firstEnd), second, secondAxis.GetEndPoint(secondEnd));
        return new
        {
            firstId = options.FirstId,
            secondId = options.SecondId,
            firstEnd,
            secondEnd,
            route = created.Length == 0 ? "direct" : created.Length == 1 ? "elbow" : "bridge",
            createdIds = created.Select(RevitApiCompatibility.GetElementIdValue).ToArray()
        };
    }

    private static Conduit GetConduit(Document document, long id) =>
        document.GetElement(new ElementId(id)) as Conduit
        ?? throw new InvalidOperationException($"Element {id} is not a conduit");

    private static Line GetAxis(Conduit conduit) =>
        (conduit.Location as LocationCurve)?.Curve as Line
        ?? throw new InvalidOperationException("Both conduits must be straight");

    private static object Describe(Conduit conduit, Line axis) => new
    {
        id = RevitApiCompatibility.GetElementIdValue(conduit.Id),
        diameterFeet = conduit.Diameter,
        pinned = conduit.Pinned,
        ends = Enumerable.Range(0, 2).Select(index =>
        {
            var point = axis.GetEndPoint(index);
            var port = conduit.ConnectorManager.Connectors.Cast<Connector>().Single(
                c => c.ConnectorType == ConnectorType.End && c.Origin.DistanceTo(point) < 1e-6);
            return new { index, xyzFeet = new[] { point.X, point.Y, point.Z }, connected = port.IsConnected };
        }).ToArray()
    };
}
