using System.Collections.Generic;
using System.Xml.Serialization;
using BimBridge.LayeredPdf.Core.Conduits;

namespace BimBridge.LayeredPdf.Core.Jobs;

[XmlRoot("LayeredPdfJob")]
public sealed class LayeredPdfJob
{
    public string OutputPath { get; set; } = string.Empty;

    public string BasePdfPath { get; set; } = string.Empty;

    public bool OpenAfterCreate { get; set; }

    public ConduitPatternSettings ConduitPatterns { get; set; } = new();

    public string ConduitReportPath { get; set; } = string.Empty;
    public string DiagnosticArchivePath { get; set; } = string.Empty;
    public string DiagnosticContext { get; set; } = string.Empty;
    public bool CreateBoxLayers { get; set; }
    public string BoxReportPath { get; set; } = string.Empty;

    [XmlArrayItem("Group")]
    public List<string> LayerGroupOrder { get; set; } = new();

    [XmlArrayItem("Layer")]
    public List<PdfLayerJob> Layers { get; set; } = new();
}

public sealed class PdfLayerJob
{
    public string BoxLayerName { get; set; } = string.Empty;
    [XmlArrayItem("ElementId")]
    public List<long> BoxElementIds { get; set; } = new();
    [XmlArrayItem("ElementId")]
    public List<long> BoxConduitElementIds { get; set; } = new();
    [XmlArrayItem("ElementId")]
    public List<long> AmbiguousBoxElementIds { get; set; } = new();
    public string GroupName { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string SourcePdfPath { get; set; } = string.Empty;

    public string ConduitGuidePdfPath { get; set; } = string.Empty;

    [XmlArrayItem("Conduit")]
    public List<ConduitElementPattern> Conduits { get; set; } = new();

    [XmlArrayItem("ElementId")]
    public List<long> ExcludedElementIds { get; set; } = new();

    public double ClipLeft { get; set; }

    public double ClipBottom { get; set; }

    public double ClipRight { get; set; } = 1;

    public double ClipTop { get; set; } = 1;

    public bool HasLabelClip { get; set; }

    public double LabelClipLeft { get; set; }

    public double LabelClipBottom { get; set; }

    public double LabelClipRight { get; set; } = 1;

    public double LabelClipTop { get; set; } = 1;
}
