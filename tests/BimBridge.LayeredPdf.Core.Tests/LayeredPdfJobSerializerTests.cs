using BimBridge.LayeredPdf.Core.Jobs;
using BimBridge.LayeredPdf.Core.Conduits;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class LayeredPdfJobSerializerTests
{
    [Fact]
    public void RoundTrip_PreservesLayerData()
    {
        var path = Path.Combine(Path.GetTempPath(), $"layered-pdf-{Guid.NewGuid():N}.xml");
        try
        {
            var expected = new LayeredPdfJob
            {
                OutputPath = "out.pdf",
                BasePdfPath = "base.pdf",
                ConduitPatterns = new() { Enabled = true, Placement = MarkerPlacement.Beside, RepeatDistanceMm = 30 },
                Layers =
                {
                    new PdfLayerJob
                    {
                        GroupName = "A101 - 总平面",
                        Name = "01 - 平面图",
                        SourcePdfPath = "layer.pdf",
                        ExcludedElementIds = { 12345678901, 42 },
                        ConduitGuidePdfPath = "guide.pdf",
                        Conduits = { new() { ElementId = 321, Symbol = ConduitSymbol.Triangle, Label = "27" } },
                        ClipLeft = 0.1,
                        ClipBottom = 0.2,
                        ClipRight = 0.8,
                        ClipTop = 0.9,
                        HasLabelClip = true,
                        LabelClipLeft = 0.15,
                        LabelClipBottom = 0.1,
                        LabelClipRight = 0.45,
                        LabelClipTop = 0.2,
                    },
                },
            };

            LayeredPdfJobSerializer.Write(path, expected);
            var actual = LayeredPdfJobSerializer.Read(path);

            Assert.Equal(expected.OutputPath, actual.OutputPath);
            Assert.Equal(expected.BasePdfPath, actual.BasePdfPath);
            Assert.True(actual.ConduitPatterns.Enabled);
            Assert.Equal(MarkerPlacement.Beside, actual.ConduitPatterns.Placement);
            Assert.Equal(30, actual.ConduitPatterns.RepeatDistanceMm);
            Assert.Single(actual.Layers);
            Assert.Equal("A101 - 总平面", actual.Layers[0].GroupName);
            Assert.Equal("01 - 平面图", actual.Layers[0].Name);
            Assert.Equal("guide.pdf", actual.Layers[0].ConduitGuidePdfPath);
            Assert.Equal(ConduitSymbol.Triangle, Assert.Single(actual.Layers[0].Conduits).Symbol);
            Assert.Equal("27", actual.Layers[0].Conduits[0].Label);
            Assert.Equal(new long[] { 12345678901, 42 }, actual.Layers[0].ExcludedElementIds);
            Assert.Equal(0.1, actual.Layers[0].ClipLeft);
            Assert.Equal(0.9, actual.Layers[0].ClipTop);
            Assert.True(actual.Layers[0].HasLabelClip);
            Assert.Equal(0.15, actual.Layers[0].LabelClipLeft);
            Assert.Equal(0.2, actual.Layers[0].LabelClipTop);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
