using BimBridge.LayeredPdf.Core.Naming;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class LayerNameBuilderTests
{
    [Theory]
    [InlineData(false, "Power - Level 1")]
    [InlineData(true, "E101 - Electrical Plans - 2 - Power - Level 1")]
    public void ExportNamingSwitchUsesRawViewNameWithoutParsingHyphens(bool expanded, string expected)
    {
        Assert.Equal(expected, LayerNameBuilder.BuildForExport(expanded, "E101", "Electrical Plans", "2", "Power - Level 1"));
    }

    [Fact]
    public void GeneratedSuffixesCannotCollideWithExistingViewNames()
    {
        var result = LayerNameBuilder.MakeUnique(new[] { "Plan", "Plan", "Plan (2)", "plan", "Plan (2)" });
        Assert.Equal(result.Count, result.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public void NamingPreferenceSurvivesSaveAndReload()
    {
        var path = Path.Combine(Path.GetTempPath(), "ExportPreferences-" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            Assert.True(ExportPreferencesSerializer.Read(path).IncludeSheetAndDetailInLayerNames);
            ExportPreferencesSerializer.Write(path, new() { IncludeSheetAndDetailInLayerNames = false });
            Assert.False(ExportPreferencesSerializer.Read(path).IncludeSheetAndDetailInLayerNames);
            ExportPreferencesSerializer.Write(path, new() { IncludeSheetAndDetailInLayerNames = true });
            Assert.True(ExportPreferencesSerializer.Read(path).IncludeSheetAndDetailInLayerNames);
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData("1", "Level 1", "1 - Level 1")]
    [InlineData("", "Level 1", "Level 1")]
    [InlineData("1", "", "1")]
    [InlineData(null, null, "Unnamed View")]
    public void Build_ProducesStableNames(string? detail, string? name, string expected)
    {
        Assert.Equal(expected, LayerNameBuilder.Build(detail, name));
    }

    [Fact]
    public void MakeUnique_DisambiguatesManyDuplicateNamesCaseInsensitively()
    {
        var names = Enumerable.Range(0, 12)
            .Select(index => index % 2 == 0 ? "Level Plan" : "level plan")
            .ToArray();

        var result = LayerNameBuilder.MakeUnique(names);

        Assert.Equal(12, result.Count);
        Assert.Equal("Level Plan", result[0]);
        Assert.Equal("level plan (2)", result[1]);
        Assert.Equal("level plan (12)", result[11]);
        Assert.Equal(12, result.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }
}
