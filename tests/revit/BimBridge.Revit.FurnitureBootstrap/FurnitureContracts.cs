using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;

namespace BimBridge.Revit.FurnitureTest;

[DataContract]
internal sealed class FurnitureRequest
{
    [DataMember(Name="schemaVersion", IsRequired=true)] public int SchemaVersion { get; set; }
    [DataMember(Name="runId", IsRequired=true)] public string RunId { get; set; } = "";
    [DataMember(Name="token", IsRequired=true)] public string Token { get; set; } = "";
    [DataMember(Name="version", IsRequired=true)] public string Version { get; set; } = "";
    [DataMember(Name="sessionId", IsRequired=true)] public string SessionId { get; set; } = "";
    [DataMember(Name="mode", IsRequired=true)] public string Mode { get; set; } = "";
    [DataMember(Name="templatePath", IsRequired=true)] public string TemplatePath { get; set; } = "";
    [DataMember(Name="documentName", IsRequired=true)] public string DocumentName { get; set; } = "";
    [DataMember(Name="families")] public FurniturePlacement[]? Families { get; set; }
}

[DataContract]
internal sealed class FurniturePlacement
{
    [DataMember(Name="fileName", IsRequired=true)] public string FileName { get; set; } = "";
    [DataMember(Name="xMm")] public double XMm { get; set; }
    [DataMember(Name="yMm")] public double YMm { get; set; }
    [DataMember(Name="rotationDegrees")] public double RotationDegrees { get; set; }
}

[DataContract]
internal sealed class FinishRequest
{
    [DataMember(Name="runId", IsRequired=true)] public string RunId { get; set; } = "";
    [DataMember(Name="sessionId", IsRequired=true)] public string SessionId { get; set; } = "";
    [DataMember(Name="token", IsRequired=true)] public string Token { get; set; } = "";
}

[DataContract]
internal sealed class FurnitureEvent
{
    [DataMember(Name="schemaVersion")] public int SchemaVersion { get; set; } = 1;
    [DataMember(Name="runId")] public string RunId { get; set; } = "";
    [DataMember(Name="sessionId")] public string SessionId { get; set; } = "";
    [DataMember(Name="stage")] public string Stage { get; set; } = "";
    [DataMember(Name="timestampUtc")] public string TimestampUtc { get; set; } = DateTime.UtcNow.ToString("o");
    [DataMember(Name="processId")] public int ProcessId { get; set; }
    [DataMember(Name="version")] public string Version { get; set; } = "";
    [DataMember(Name="versionBuild")] public string VersionBuild { get; set; } = "";
    [DataMember(Name="documentTitle")] public string DocumentTitle { get; set; } = "";
    [DataMember(Name="documentPath")] public string DocumentPath { get; set; } = "";
    [DataMember(Name="placedElementIds")] public long[] PlacedElementIds { get; set; } = Array.Empty<long>();
    [DataMember(Name="message")] public string? Message { get; set; }
}

internal static class FurnitureJson
{
    internal static T Read<T>(string path)
    {
        using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return (T)new DataContractJsonSerializer(typeof(T)).ReadObject(stream);
    }
    internal static void Write<T>(string path, T value)
    {
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = File.Create(temp)) new DataContractJsonSerializer(typeof(T)).WriteObject(stream, value);
            // Each stage is emitted once; never overwrite a prior run's evidence.
            File.Move(temp, path);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
