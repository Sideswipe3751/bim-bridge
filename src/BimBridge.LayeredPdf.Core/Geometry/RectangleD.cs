using System;

namespace BimBridge.LayeredPdf.Core.Geometry;

public readonly struct RectangleD : IEquatable<RectangleD>
{
    public RectangleD(double left, double bottom, double right, double top)
    {
        if (double.IsNaN(left) || double.IsNaN(bottom) || double.IsNaN(right) || double.IsNaN(top))
        {
            throw new ArgumentException("Rectangle coordinates must be numbers.");
        }

        if (right < left || top < bottom)
        {
            throw new ArgumentException("Rectangle maximum coordinates must be greater than or equal to minimum coordinates.");
        }

        Left = left;
        Bottom = bottom;
        Right = right;
        Top = top;
    }

    public double Left { get; }

    public double Bottom { get; }

    public double Right { get; }

    public double Top { get; }

    public double Width => Right - Left;

    public double Height => Top - Bottom;

    public RectangleD Union(RectangleD other) => new(
        Math.Min(Left, other.Left),
        Math.Min(Bottom, other.Bottom),
        Math.Max(Right, other.Right),
        Math.Max(Top, other.Top));

    public RectangleD Expand(double amount) => new(
        Left - amount,
        Bottom - amount,
        Right + amount,
        Top + amount);

    public bool Equals(RectangleD other) =>
        Left.Equals(other.Left) &&
        Bottom.Equals(other.Bottom) &&
        Right.Equals(other.Right) &&
        Top.Equals(other.Top);

    public override bool Equals(object? obj) => obj is RectangleD other && Equals(other);

    public override int GetHashCode()
    {
        unchecked
        {
            var hashCode = Left.GetHashCode();
            hashCode = (hashCode * 397) ^ Bottom.GetHashCode();
            hashCode = (hashCode * 397) ^ Right.GetHashCode();
            return (hashCode * 397) ^ Top.GetHashCode();
        }
    }
}
