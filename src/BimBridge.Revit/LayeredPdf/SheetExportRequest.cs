using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;

namespace BimBridge.Revit.LayeredPdf;

public sealed class SheetExportRequest
{
    public SheetExportRequest(ViewSheet sheet, SheetExportPlan plan)
    {
        Sheet = sheet;
        Plan = plan;
    }

    public ViewSheet Sheet { get; }

    public SheetExportPlan Plan { get; }

    public string DisplayName => $"{Sheet.SheetNumber} - {Sheet.Name}";
}
