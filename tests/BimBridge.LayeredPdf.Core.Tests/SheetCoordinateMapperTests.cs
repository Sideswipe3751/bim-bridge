using BimBridge.LayeredPdf.Core.Geometry;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class SheetCoordinateMapperTests
{
    [Fact]
    public void ToNormalized_MapsSheetCoordinates()
    {
        var sheet = new RectangleD(-1, -2, 3, 6);
        var item = new RectangleD(0, 0, 2, 4);

        var result = SheetCoordinateMapper.ToNormalized(sheet, item);

        Assert.Equal(0.25, result.Left, 8);
        Assert.Equal(0.25, result.Bottom, 8);
        Assert.Equal(0.75, result.Right, 8);
        Assert.Equal(0.75, result.Top, 8);
    }

    [Fact]
    public void ToNormalized_ClampsExpandedRectangleToSheet()
    {
        var sheet = new RectangleD(0, 0, 10, 10);
        var item = new RectangleD(1, 1, 9, 9);

        var result = SheetCoordinateMapper.ToNormalized(sheet, item, 2);

        Assert.Equal(new RectangleD(0, 0, 1, 1), result);
    }

    [Fact]
    public void ToNormalized_RejectsZeroSizeSheet()
    {
        Assert.Throws<ArgumentException>(() => SheetCoordinateMapper.ToNormalized(
            new RectangleD(0, 0, 0, 10),
            new RectangleD(0, 0, 0, 1)));
    }
}
