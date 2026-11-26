using System.IO;
using System.Xml;
using System.Xml.Serialization;

namespace BimBridge.LayeredPdf.Core.Conduits;

public static class ConduitProfileSerializer
{
    public static ConduitPatternSettings Read(string path)
    {
        using var reader = XmlReader.Create(path, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
        var result = (ConduitPatternSettings)new XmlSerializer(typeof(ConduitPatternSettings)).Deserialize(reader)!;
        result.Validate();
        return result;
    }

    public static void Write(string path, ConduitPatternSettings settings)
    {
        settings.Validate();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + System.Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var writer = XmlWriter.Create(temporary, new XmlWriterSettings { Indent = true }))
                new XmlSerializer(typeof(ConduitPatternSettings)).Serialize(writer, settings);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
