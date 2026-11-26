using System;
using System.Collections.Generic;
using System.Linq;

namespace BimBridge.Host;

public sealed class ConnectorLayeredPdfOptions
{
    public long BaseSheetId { get; set; }
    public List<long> SheetIds { get; set; } = new List<long>();
    public string? SetupName { get; set; }
    public string FileStem { get; set; } = "layered-pdf";
    public bool IncludeSheetAndDetail { get; set; } = true;
    public bool CreateBoxLayers { get; set; }

    public void Validate()
    {
        if (BaseSheetId <= 0 || SheetIds == null || SheetIds.Count < 1 || SheetIds.Count > 100 ||
            SheetIds.Any(id => id <= 0) || SheetIds.Distinct().Count() != SheetIds.Count)
            throw new ArgumentException("Specify a baseSheetId and 1-100 distinct positive sheetIds");
        FamilySessionPaths.ValidateName(FileStem);
        if (SetupName != null && (string.IsNullOrWhiteSpace(SetupName) || SetupName.Length > 256))
            throw new ArgumentException("setupName must contain 1-256 characters");
    }
}
