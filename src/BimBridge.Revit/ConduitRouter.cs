using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.Electrical;

namespace BimBridge.Revit
{
    internal static class ConduitRouter
    {
        private const double PositionTolerance = 1e-6; // Revit internal feet
        private const double DirectionTolerance = 1e-7;

        public static ElementId[] Connect(Document doc, Conduit first, XYZ firstPick, Conduit second, XYZ secondPick)
        {
            if (first.Id == second.Id)
                throw new InvalidOperationException("Select two distinct conduits.");
            if (first.Pinned || second.Pinned)
                throw new InvalidOperationException("The selected conduit is pinned.");
            if (Math.Abs(first.Diameter - second.Diameter) > PositionTolerance)
                throw new InvalidOperationException("The conduits must have the same nominal diameter.");

            var a = new End(first, firstPick);
            var b = new End(second, secondPick);
            double minLength = doc.Application.ShortCurveTolerance * 2;
            string? lastError = null;

            foreach (var route in Routes(a, b, minLength))
            {
                using (var attempt = new SubTransaction(doc))
                {
                    attempt.Start();
                    try
                    {
                        ElementId[] created = Build(doc, a, b, route);
                        doc.Regenerate();
                        a.VerifyFixedEnd();
                        b.VerifyFixedEnd();
                        if (attempt.Commit() != TransactionStatus.Committed)
                            throw new InvalidOperationException("Revit did not commit the candidate route.");
                        return created;
                    }
                    catch (Exception error) when (
                        error is Autodesk.Revit.Exceptions.ArgumentException ||
                        error is Autodesk.Revit.Exceptions.InvalidOperationException ||
                        error is InvalidOperationException)
                    {
                        lastError = error.Message;
                        if (attempt.GetStatus() == TransactionStatus.Started)
                            attempt.RollBack();
                    }
                }
            }

            throw new InvalidOperationException("The available conduit fittings could not connect the selected ends."
                + (lastError == null ? "" : Environment.NewLine + lastError));
        }

        private static IEnumerable<Route> Routes(End a, End b, double minLength)
        {
            XYZ delta = b.Point - a.Point;
            XYZ normal = a.Outward.CrossProduct(b.Outward);
            double normalLength = normal.GetLength();
            if (normalLength < DirectionTolerance)
            {
                if (delta.CrossProduct(a.Outward).GetLength() < PositionTolerance)
                {
                    XYZ midpoint = (a.Point + b.Point) * 0.5;
                    if (a.Outward.DotProduct(b.Outward) < 0 &&
                        a.HasLength(midpoint, minLength) && b.HasLength(midpoint, minLength))
                    {
                        yield return new Route(midpoint, midpoint, false, true);
                    }
                    yield break;
                }
            }
            else if (Math.Abs(delta.DotProduct(normal) / normalLength) < PositionTolerance &&
                     CanBend(a.Outward, b.Outward.Negate()))
            {
                double shift = delta.CrossProduct(b.Outward).DotProduct(normal) / normal.DotProduct(normal);
                XYZ corner = a.Point + a.Outward * shift;
                if (a.HasLength(corner, minLength) && b.HasLength(corner, minLength))
                    yield return new Route(corner, corner, false, false);
            }

            // Slide the selected ends along their own axes. Each resulting corner
            // lies in the plane of its original conduit and the bridge.
            var candidates = new List<Route>();
            void Add(double shiftA, double shiftB)
            {
                XYZ start = a.Point + a.Outward * shiftA;
                XYZ end = b.Point + b.Outward * shiftB;
                XYZ bridge = end - start;
                if (bridge.GetLength() <= minLength ||
                    !a.HasLength(start, minLength) || !b.HasLength(end, minLength))
                    return;
                XYZ travel = bridge.Normalize();
                if (!CanBend(a.Outward, travel) || !CanBend(travel, b.Outward.Negate()))
                    return;
                if (candidates.Any(r => r.Start.DistanceTo(start) < PositionTolerance &&
                                        r.End.DistanceTo(end) < PositionTolerance))
                    return;
                candidates.Add(new Route(start, end, true, false));
            }

            Add(0, 0);
            if (normalLength < DirectionTolerance)
            {
                double axial = delta.DotProduct(a.Outward);
                double offset = delta.CrossProduct(a.Outward).GetLength();
                foreach (double angle in new[] { 45.0, 90.0, 60.0, 30.0, 22.5 })
                {
                    double target = angle == 90 ? 0 : offset / Math.Tan(angle * Math.PI / 180);
                    double change = target - axial;
                    double sign = a.Outward.DotProduct(b.Outward);
                    Add(-change / 2, change / (2 * sign));
                    Add(-change, 0);
                    Add(0, change / sign);
                }
            }

            double scale = Math.Max(delta.GetLength(), 4 * a.Pipe.Diameter);
            double[] shifts = { 0, -0.125, 0.125, -0.25, 0.25, -0.5, 0.5, -1, 1, -2, 2 };
            foreach (double x in shifts)
                foreach (double y in shifts)
                    Add(scale * x, scale * y);

            foreach (var candidate in candidates.OrderBy(r =>
                r.Start.DistanceTo(a.Point) + r.End.DistanceTo(b.Point)).Take(32))
                yield return candidate;
        }

        private static bool CanBend(XYZ incoming, XYZ outgoing)
        {
            double dot = incoming.DotProduct(outgoing);
            return dot >= Math.Cos(95 * Math.PI / 180) && dot <= Math.Cos(2 * Math.PI / 180);
        }

        private static ElementId[] Build(Document doc, End a, End b, Route route)
        {
            a.MoveTo(route.Start);
            b.MoveTo(route.End);
            doc.Regenerate();
            var first = a.At(route.Start);
            var second = b.At(route.End);

            if (!route.HasBridge)
            {
                if (route.IsStraight)
                {
                    first.ConnectTo(second);
                    doc.Regenerate();
                    if (!first.IsConnectedTo(second))
                        throw new InvalidOperationException("The collinear ports did not connect directly.");
                    return Array.Empty<ElementId>();
                }
                var elbow = doc.Create.NewElbowFitting(first, second);
                doc.Regenerate();
                VerifyLinks(elbow.Id, a.Pipe, b.Pipe);
                return new[] { elbow.Id };
            }

            var bridge = Conduit.Create(doc, a.Pipe.GetTypeId(), route.Start, route.End, a.Pipe.ReferenceLevel.Id);
            bridge.get_Parameter(BuiltInParameter.RBS_CONDUIT_DIAMETER_PARAM).Set(a.Pipe.Diameter);
            doc.Regenerate();
            var elbowA = doc.Create.NewElbowFitting(first, Closest(bridge, route.Start));
            doc.Regenerate();
            var elbowB = doc.Create.NewElbowFitting(Closest(bridge, route.End), b.At(route.End));
            doc.Regenerate();
            VerifyLinks(elbowA.Id, a.Pipe, bridge);
            VerifyLinks(elbowB.Id, bridge, b.Pipe);
            return new[] { bridge.Id, elbowA.Id, elbowB.Id };
        }

        private static void VerifyLinks(ElementId fitting, Conduit a, Conduit b)
        {
            if (!References(a).Contains(fitting) || !References(b).Contains(fitting))
                throw new InvalidOperationException("The elbow did not connect to both conduits.");
        }

        private static IEnumerable<ElementId> References(Conduit pipe) =>
            Ends(pipe).SelectMany(c => c.AllRefs.Cast<Connector>())
                .Where(c => c.ConnectorType == ConnectorType.End && c.Owner.Id != pipe.Id)
                .Select(c => c.Owner.Id);

        private static IEnumerable<Connector> Ends(Conduit pipe) =>
            pipe.ConnectorManager.Connectors.Cast<Connector>()
                .Where(c => c.ConnectorType == ConnectorType.End);

        private static Connector Closest(Conduit pipe, XYZ point) =>
            Ends(pipe).OrderBy(c => c.Origin.DistanceTo(point)).First();

        private sealed class End
        {
            public Conduit Pipe { get; }
            public XYZ Point { get; }
            public XYZ Outward { get; }
            private readonly XYZ fixedPoint;
            private readonly (ElementId Owner, int Port)[] fixedReferences;
            private readonly int movingIndex;

            public End(Conduit pipe, XYZ pick)
            {
                Pipe = pipe;
                if (!(pipe.Location is LocationCurve location) || !(location.Curve is Line))
                    throw new InvalidOperationException("Only straight conduits are supported.");
                var moving = Closest(pipe, pick);
                if (moving.IsConnected)
                    throw new InvalidOperationException("The selected end is already connected.");
                Point = moving.Origin;
                var fixedEnd = Ends(pipe).Single(c => c.Id != moving.Id);
                fixedPoint = fixedEnd.Origin;
                fixedReferences = PortReferences(fixedEnd);
                Outward = (Point - fixedPoint).Normalize();
                movingIndex = location.Curve.GetEndPoint(0).DistanceTo(Point) < PositionTolerance ? 0 : 1;
            }

            public bool HasLength(XYZ point, double minLength) =>
                (point - fixedPoint).DotProduct(Outward) > minLength;

            public Connector At(XYZ point) => Closest(Pipe, point);

            public void MoveTo(XYZ point)
            {
                if (Point.DistanceTo(point) <= PositionTolerance)
                    return;
                var location = (LocationCurve)Pipe.Location;
                location.Curve = movingIndex == 0 ? Line.CreateBound(point, fixedPoint) : Line.CreateBound(fixedPoint, point);
            }

            public void VerifyFixedEnd()
            {
                var connector = At(fixedPoint);
                if (connector.Origin.DistanceTo(fixedPoint) > PositionTolerance ||
                    !new HashSet<(ElementId, int)>(fixedReferences).SetEquals(PortReferences(connector)))
                    throw new InvalidOperationException("The operation would change the opposite end or its connections.");
            }

            private (ElementId, int)[] PortReferences(Connector connector) =>
                connector.AllRefs.Cast<Connector>()
                    .Where(c => c.ConnectorType == ConnectorType.End && c.Owner.Id != Pipe.Id)
                    .Select(c => (c.Owner.Id, c.Id)).ToArray();
        }

        private sealed class Route
        {
            public XYZ Start { get; }
            public XYZ End { get; }
            public bool HasBridge { get; }
            public bool IsStraight { get; }

            public Route(XYZ start, XYZ end, bool hasBridge, bool isStraight)
            {
                Start = start;
                End = end;
                HasBridge = hasBridge;
                IsStraight = isStraight;
            }
        }
    }
}
