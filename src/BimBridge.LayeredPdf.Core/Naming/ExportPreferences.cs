using System.IO;
using System.Xml;
using System.Xml.Serialization;
using System.Collections.Generic;
using System.Linq;
using BimBridge.LayeredPdf.Core.Conduits;
using BimBridge.LayeredPdf.Core.Groups;

namespace BimBridge.LayeredPdf.Core.Naming;

public sealed class ExportPreferences
{
    public bool IncludeSheetAndDetailInLayerNames { get; set; } = true;
    public bool OpenAfterExport { get; set; } = true;
    public bool SaveDiagnostics { get; set; }
    public bool CreateBoxLayers { get; set; }
    public string SelectedSetupName { get; set; } = string.Empty;
    public string SelectedSavedSetName { get; set; } = string.Empty;
    public string OutputPath { get; set; } = string.Empty;
    public string OutputDirectory { get; set; } = string.Empty;
    [XmlArrayItem("Sheet")]
    public List<string> SelectedSheetKeys { get; set; } = new();
    public ConduitPatternSettings? ConduitPatterns { get; set; }
    public LayerGroupSettings? LayerGroups { get; set; }

    public List<string> RestoreSheets(IEnumerable<string> available, string current)
    {
        var availableKeys = new HashSet<string>(available);
        var restored = SelectedSheetKeys.Where(availableKeys.Contains).Distinct().ToList();
        if (restored.Count == 0 && availableKeys.Contains(current)) restored.Add(current);
        return restored;
    }

    // Project element identifiers, groups and output filenames must never leak
    // into another model. General UI defaults may follow the user's last export.
    public ExportPreferences GeneralDefaults() => new()
    {
        IncludeSheetAndDetailInLayerNames = IncludeSheetAndDetailInLayerNames,
        OpenAfterExport = OpenAfterExport, SaveDiagnostics = SaveDiagnostics, CreateBoxLayers = CreateBoxLayers,
        SelectedSetupName = SelectedSetupName, OutputDirectory = OutputDirectory
    };
}

public static class ExportPreferencesSerializer
{
    public static ExportPreferences Read(string path)
    {
        if (!File.Exists(path)) return new ExportPreferences();
        using var reader = XmlReader.Create(path, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
        return (ExportPreferences)new XmlSerializer(typeof(ExportPreferences)).Deserialize(reader)!;
    }

    public static void Write(string path, ExportPreferences settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + System.Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var writer = XmlWriter.Create(temporary, new XmlWriterSettings { Indent = true }))
                new XmlSerializer(typeof(ExportPreferences)).Serialize(writer, settings);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
