using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Groups;
using BimBridge.LayeredPdf.Core.Naming;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class ExportPreferencesTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "ExportPreferencesTests", Guid.NewGuid().ToString("N"));
    public ExportPreferencesTests() => Directory.CreateDirectory(_directory);

    [Fact]
    public void CompletePrintSnapshotSurvivesRestartIncludingDisabledOptionsAndOrderedSheets()
    {
        var path = Path.Combine(_directory, "project.xml");
        var saved = new ExportPreferences
        {
            IncludeSheetAndDetailInLayerNames = false, OpenAfterExport = false, SaveDiagnostics = true, CreateBoxLayers = true,
            SelectedSetupName = "Color 1:100", SelectedSavedSetName = "Power", OutputPath = @"C:\Prints\Power.pdf", OutputDirectory = @"C:\Prints",
            SelectedSheetKeys = new() { "sheet-b", "sheet-a" },
            ConduitPatterns = new() { Enabled = false, Placement = MarkerPlacement.Beside, SymbolSizeMm = 2, TextSizePoints = 6, RepeatDistanceMm = 15,
                Rules = { new() { Standard = "RNC Schedule40", NominalDiameterMm = 27, Symbol = ConduitSymbol.Circle, Label = "27" } } },
            LayerGroups = new() { ProjectKey = "model-1", Enabled = false,
                Groups = { new() { Id = "group-1", Name = "Power", ViewKeys = new() { "viewport-2", "viewport-1" } } } }
        };
        ExportPreferencesSerializer.Write(path, saved);
        var loaded = ExportPreferencesSerializer.Read(path);
        Assert.False(loaded.IncludeSheetAndDetailInLayerNames); Assert.False(loaded.OpenAfterExport); Assert.True(loaded.SaveDiagnostics);
        Assert.True(loaded.CreateBoxLayers); Assert.True(loaded.GeneralDefaults().CreateBoxLayers);
        Assert.Equal(saved.SelectedSetupName, loaded.SelectedSetupName); Assert.Equal(saved.SelectedSavedSetName, loaded.SelectedSavedSetName);
        Assert.Equal(saved.OutputPath, loaded.OutputPath); Assert.Equal(saved.OutputDirectory, loaded.OutputDirectory);
        Assert.Equal(saved.SelectedSheetKeys, loaded.SelectedSheetKeys);
        Assert.False(loaded.ConduitPatterns!.Enabled); Assert.Equal(MarkerPlacement.Beside, loaded.ConduitPatterns.Placement);
        Assert.Equal(2, loaded.ConduitPatterns.SymbolSizeMm); Assert.Equal(6, loaded.ConduitPatterns.TextSizePoints); Assert.Equal(15, loaded.ConduitPatterns.RepeatDistanceMm);
        Assert.Equal(ConduitSymbol.Circle, loaded.ConduitPatterns.Match("RNC Schedule40", 27)!.Symbol);
        Assert.Equal("27", loaded.ConduitPatterns.Match("RNC Schedule40", 27)!.Label);
        Assert.False(loaded.LayerGroups!.Enabled); Assert.Equal("model-1", loaded.LayerGroups.ProjectKey);
        Assert.Equal(new[] { "viewport-2", "viewport-1" }, Assert.Single(loaded.LayerGroups.Groups).ViewKeys);
        // Editing the next dialog's data cannot change the previously saved print.
        loaded.ConduitPatterns.Rules[0].Symbol = ConduitSymbol.Star; loaded.LayerGroups.Groups.Clear();
        Assert.Equal(ConduitSymbol.Circle, ExportPreferencesSerializer.Read(path).ConduitPatterns!.Rules[0].Symbol);
        Assert.Single(ExportPreferencesSerializer.Read(path).LayerGroups!.Groups);
    }

    [Fact]
    public void DeletedSheetsAreRemovedWithoutChangingOrderAndAllMissingFallsBackToCurrent()
    {
        var saved = new ExportPreferences { SelectedSheetKeys = new() { "b", "deleted", "a", "b" } };
        Assert.Equal(new[] { "b", "a" }, saved.RestoreSheets(new[] { "a", "b", "new" }, "new"));
        Assert.Equal(new[] { "new" }, saved.RestoreSheets(new[] { "new" }, "new"));
        Assert.Equal(new[] { "new" }, new ExportPreferences().RestoreSheets(new[] { "new" }, "new"));
    }

    [Fact]
    public void UpgradeReadsLegacyFileAndGeneralDefaultsDoNotCopyProjectSpecificChoices()
    {
        var path = Path.Combine(_directory, "legacy.xml");
        File.WriteAllText(path, "<ExportPreferences><IncludeSheetAndDetailInLayerNames>false</IncludeSheetAndDetailInLayerNames></ExportPreferences>");
        var legacy = ExportPreferencesSerializer.Read(path);
        Assert.False(legacy.IncludeSheetAndDetailInLayerNames); Assert.True(legacy.OpenAfterExport);
        Assert.False(legacy.CreateBoxLayers);
        Assert.Null(legacy.ConduitPatterns); Assert.Null(legacy.LayerGroups);
        legacy.OutputDirectory = @"C:\Prints"; legacy.OutputPath = @"C:\Prints\specific.pdf";
        legacy.SelectedSheetKeys.Add("private-to-project"); legacy.SelectedSavedSetName = "project set";
        legacy.SaveDiagnostics = true; legacy.OpenAfterExport = false; legacy.SelectedSetupName = "Color";
        legacy.LayerGroups = new() { ProjectKey = "project" }; legacy.ConduitPatterns = new();
        var other = legacy.GeneralDefaults();
        Assert.Empty(other.SelectedSheetKeys); Assert.Empty(other.OutputPath); Assert.Empty(other.SelectedSavedSetName);
        Assert.Null(other.LayerGroups); Assert.Null(other.ConduitPatterns);
        Assert.Equal(@"C:\Prints", other.OutputDirectory); Assert.Equal("Color", other.SelectedSetupName);
        Assert.True(other.SaveDiagnostics); Assert.False(other.OpenAfterExport);
    }

    [Fact]
    public void FailedPreferenceWritePreservesPreviousSuccessfulPrint()
    {
        var path = Path.Combine(_directory, "project.xml");
        ExportPreferencesSerializer.Write(path, new() { SelectedSetupName = "Last successful print" });
        var before = File.ReadAllBytes(path);
        Assert.ThrowsAny<Exception>(() => ExportPreferencesSerializer.Write(path, new() { SelectedSetupName = "Invalid XML \u0001" }));
        Assert.Equal(before, File.ReadAllBytes(path));
        Assert.Empty(Directory.GetFiles(_directory, "*.tmp"));
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}
