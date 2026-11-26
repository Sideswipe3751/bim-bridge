using System;
using System.IO;
using System.Xml;
using System.Xml.Serialization;

namespace BimBridge.LayeredPdf.Core.Jobs;

public static class LayeredPdfJobSerializer
{
    private static readonly XmlSerializer Serializer = new(typeof(LayeredPdfJob));

    public static void Write(string path, LayeredPdfJob job)
    {
        if (job is null)
        {
            throw new ArgumentNullException(nameof(job));
        }

        var settings = new XmlWriterSettings { Indent = true };
        using var writer = XmlWriter.Create(path, settings);
        Serializer.Serialize(writer, job);
    }

    public static LayeredPdfJob Read(string path)
    {
        using var stream = File.OpenRead(path);
        return (LayeredPdfJob)(Serializer.Deserialize(stream) ?? throw new InvalidDataException("The layered PDF job is empty."));
    }
}
