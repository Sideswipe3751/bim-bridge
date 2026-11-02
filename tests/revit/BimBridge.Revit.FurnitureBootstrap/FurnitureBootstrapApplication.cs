using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace BimBridge.Revit.FurnitureTest;

public sealed class FurnitureBootstrapApplication : IExternalApplication
{
    private FurnitureRequest? _request;
    private string _runDirectory = "";
    private string _documentPath = "";
    private bool _ready, _failed, _exitRequested;
    private long[] _placedIds = Array.Empty<long>();
    public Result OnStartup(UIControlledApplication application)
    {
        string? requestPath = Environment.GetEnvironmentVariable("BIM_BRIDGE_REVIT_FURNITURE_REQUEST");
        if (string.IsNullOrWhiteSpace(requestPath)) return Result.Succeeded;
        try
        {
            _request = FurnitureJson.Read<FurnitureRequest>(requestPath);
            Validate(requestPath, application.ControlledApplication.VersionNumber);
            application.Idling += OnIdling;
        }
        catch (Exception e)
        {
            _failed = true;
            // Report only after trusted containment has been established. No arbitrary failure path.
            if (_runDirectory.Length > 0) TryReport("failed", null, "startup: " + e.Message);
        }
        // Never fail add-in startup into a publisher/error dialog or close user documents.
        return Result.Succeeded;
    }
    public Result OnShutdown(UIControlledApplication application)
    {
        application.Idling -= OnIdling;
        if (_request != null && _runDirectory.Length > 0) TryReport("stopped", null, null);
        return Result.Succeeded;
    }
    private void OnIdling(object? sender, IdlingEventArgs args)
    {
        if (_request == null || _failed || _exitRequested || !(sender is UIApplication app)) return;
        try
        {
            if (!_ready)
            {
                Initialize(app);
                _ready = true;
                TryReport("ready", app, null);
            }
            string finishPath = RunFile(_request.SessionId + ".finish.json");
            if (!File.Exists(finishPath)) return;
            FinishRequest finish = FurnitureJson.Read<FinishRequest>(finishPath);
            if (finish.RunId != _request.RunId || finish.SessionId != _request.SessionId || finish.Token != _request.Token)
                throw new InvalidOperationException("Finish marker run/session/token mismatch");
            Document document = app.ActiveUIDocument?.Document ?? throw new InvalidOperationException("No active test document");
            if (!PathsEqual(document.PathName, _documentPath) || document.IsModifiable)
                throw new InvalidOperationException("Refused to save an unexpected or modifiable document");
            // Only test documents may be open before posting clean exit; never prompt for user documents.
            foreach (Document open in app.Application.Documents)
                if (!PathsEqual(open.PathName, _documentPath)) throw new InvalidOperationException("Unexpected additional document; exit refused");
            SafePath(_documentPath);
            if (document.IsModified) document.Save();
            TryReport("saved", app, null);
            RevitCommandId command = RevitCommandId.LookupPostableCommandId(PostableCommand.ExitRevit);
            if (!app.CanPostCommand(command)) throw new InvalidOperationException("Clean exit is unavailable");
            app.PostCommand(command);
            _exitRequested = true;
        }
        catch (Exception e) { _failed = true; TryReport("failed", app, e.ToString()); }
    }
    private void Initialize(UIApplication app)
    {
        FurnitureRequest request = _request!;
        if (app.ActiveUIDocument != null || app.Application.Documents.Size != 0)
            throw new InvalidOperationException("Cold-start safety gate: existing documents are forbidden");
        if (File.Exists(_documentPath)) throw new InvalidOperationException("Output document already exists; replay refused");
        Document document = request.Mode == "family"
            ? app.Application.NewFamilyDocument(request.TemplatePath)
            : app.Application.NewProjectDocument(request.TemplatePath);
        try
        {
            if (request.Mode == "project") Assemble(document, request.Families!);
            SafePath(_documentPath);
            using var options = new SaveAsOptions { OverwriteExistingFile = false, MaximumBackups = 1 };
            document.SaveAs(_documentPath, options);
        }
        finally { if (document.IsValidObject) document.Close(false); }
        UIDocument uiDocument = app.OpenAndActivateDocument(_documentPath);
        if (!PathsEqual(uiDocument.Document.PathName, _documentPath)) throw new InvalidOperationException("Unexpected activation target");
        // Do not switch ActiveView inside Idling: Revit 2024 temporarily disables
        // that setter immediately after activation. The connector can discover
        // the prepared 3D view and capture it explicitly by view ID.
    }
    private void Assemble(Document project, FurniturePlacement[] placements)
    {
        using var transaction = new Transaction(project, "BIM Bridge disposable furniture assembly");
        if (transaction.Start() != TransactionStatus.Started)
            throw new InvalidOperationException("Unable to start furniture assembly transaction");
        var preprocessor = new RollbackErrors();
        using (FailureHandlingOptions failure = transaction.GetFailureHandlingOptions())
        {
            failure.SetFailuresPreprocessor(preprocessor);
            failure.SetClearAfterRollback(true);
            failure.SetForcedModalHandling(false);
            transaction.SetFailureHandlingOptions(failure);
        }
        try
        {
            List<Tuple<FamilySymbol,FurniturePlacement>> symbols = new();
            foreach (FurniturePlacement placement in placements)
            {
                string file = RunFile(placement.FileName);
                if (!File.Exists(file)) throw new FileNotFoundException("Prepared family is missing", file);
                // The file-path overload modifies the target project inside this
                // fixture-owned transaction. It differs from sourceDoc.LoadFamily(targetDoc).
                if (!project.LoadFamily(file, out Family family)) throw new InvalidOperationException("Family load failed: " + placement.FileName);
                ElementId symbolId = family.GetFamilySymbolIds().OrderBy(id => id.Value).First();
                symbols.Add(Tuple.Create((FamilySymbol)project.GetElement(symbolId), placement));
            }
            List<long> ids = new();
            Level? level = new FilteredElementCollector(project).OfClass(typeof(Level)).Cast<Level>().OrderBy(l=>Math.Abs(l.Elevation)).FirstOrDefault();
            foreach (var item in symbols)
            {
                FamilySymbol symbol = item.Item1;
                FurniturePlacement placement = item.Item2;
                if (!symbol.IsActive) { symbol.Activate(); project.Regenerate(); }
                XYZ point = new XYZ(placement.XMm/304.8, placement.YMm/304.8, level?.Elevation ?? 0);
                FamilyInstance instance = level == null
                    ? project.Create.NewFamilyInstance(point, symbol, Autodesk.Revit.DB.Structure.StructuralType.NonStructural)
                    : project.Create.NewFamilyInstance(point, symbol, level, Autodesk.Revit.DB.Structure.StructuralType.NonStructural);
                if (placement.RotationDegrees != 0) ElementTransformUtils.RotateElement(project, instance.Id, Line.CreateBound(point,point+XYZ.BasisZ),placement.RotationDegrees*Math.PI/180);
                ids.Add(instance.Id.Value);
            }
            ViewFamilyType type = new FilteredElementCollector(project).OfClass(typeof(ViewFamilyType)).Cast<ViewFamilyType>().First(t=>t.ViewFamily==ViewFamily.ThreeDimensional);
            View3D view = View3D.CreateIsometric(project,type.Id);
            view.Name = "BIM Bridge Furniture Test";
            view.DetailLevel = ViewDetailLevel.Fine;
            view.DisplayStyle = DisplayStyle.Shading;
            view.SetOrientation(new ViewOrientation3D(new XYZ(12,-16,10),new XYZ(-0.3,0.4,0.866025403784439),new XYZ(-0.519615242270663,0.692820323027551,-0.5)));
            if (transaction.Commit() != TransactionStatus.Committed) throw new InvalidOperationException("Furniture assembly transaction rolled back");
            _placedIds = ids.ToArray();
        }
        catch
        {
            if (transaction.GetStatus() == TransactionStatus.Started) transaction.RollBack();
            throw;
        }
    }
    private void Validate(string requestPath, string actualVersion)
    {
        FurnitureRequest r = _request!;
        if (r.SchemaVersion != 1 || r.Version != "2024" || r.Version != actualVersion) throw new InvalidOperationException("Wrong schema or Revit version");
        if (!Regex.IsMatch(r.RunId,@"^[A-Za-z0-9][A-Za-z0-9_-]{5,79}$") || !Regex.IsMatch(r.SessionId,@"^[A-Za-z0-9][A-Za-z0-9_-]{1,60}$") || !Regex.IsMatch(r.Token,@"^[A-Fa-f0-9]{64}$")) throw new InvalidOperationException("Invalid run/session/token");
        string root = typeof(FurnitureBootstrapApplication).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().Single(a=>a.Key=="FurnitureOutputRoot").Value!;
        string run = Path.GetFullPath(Path.Combine(root,r.RunId));
        SafePath(run);
        if (!Directory.Exists(run) || !PathsEqual(Path.GetDirectoryName(Path.GetFullPath(requestPath)),run)) throw new InvalidOperationException("Request must be inside fixed output root/runId");
        _runDirectory = run;
        if (r.Mode != "family" && r.Mode != "project" && r.Mode != "resident") throw new InvalidOperationException("Mode must be family, project or resident");
        ValidateFileName(r.DocumentName,r.Mode=="family" ? ".rfa" : ".rvt");
        if (!r.DocumentName.StartsWith("BB_",StringComparison.Ordinal)) throw new InvalidOperationException("Disposable document must begin BB_");
        _documentPath = RunFile(r.DocumentName);
        if (File.Exists(_documentPath)) throw new InvalidOperationException("Output exists; replay refused");
        if (!File.Exists(r.TemplatePath) || !string.Equals(Path.GetExtension(r.TemplatePath),r.Mode=="family" ? ".rft" : ".rte",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Existing exact RFT/RTE is required");
        if (r.Mode=="project")
        {
            if (r.Families==null || r.Families.Length<1 || r.Families.Length>15) throw new InvalidOperationException("Project requires 1-15 families");
            HashSet<string> names=new(StringComparer.OrdinalIgnoreCase);
            foreach (FurniturePlacement p in r.Families)
            {
                ValidateFileName(p.FileName,".rfa");
                if (!names.Add(p.FileName)) throw new InvalidOperationException("Duplicate family path");
                if (!Finite(p.XMm) || !Finite(p.YMm) || !Finite(p.RotationDegrees) || Math.Abs(p.XMm)>50000 || Math.Abs(p.YMm)>50000 || Math.Abs(p.RotationDegrees)>360) throw new InvalidOperationException("Placement exceeds test scope");
                RunFile(p.FileName);
            }
        }
    }
    private static bool Finite(double x) => !double.IsNaN(x) && !double.IsInfinity(x);
    private static void ValidateFileName(string file,string extension)
    {
        if (!Regex.IsMatch(file,@"^[A-Za-z0-9][A-Za-z0-9_.-]{1,120}$") || file.Contains("..") || Path.GetExtension(file).ToLowerInvariant()!=extension) throw new InvalidOperationException("Unsafe file name");
    }
    private string RunFile(string name)
    {
        string path=Path.GetFullPath(Path.Combine(_runDirectory,name));
        if (!path.StartsWith(_runDirectory+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Output containment failure");
        SafePath(path);
        return path;
    }
    private static bool PathsEqual(string? a,string? b) => a!=null && b!=null && string.Equals(Path.GetFullPath(a).TrimEnd('\\'),Path.GetFullPath(b).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);
    private static void SafePath(string path)
    {
        // Reject redirecting link tags while permitting OneDrive cloud placeholders.
        string? current=Path.GetFullPath(path);
        while (!string.IsNullOrEmpty(current))
        {
            if ((File.Exists(current)||Directory.Exists(current)) && (File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)
            {
                IntPtr handle=FindFirstFile(current,out FindData data);
                if (handle==new IntPtr(-1)) throw new IOException("Cannot inspect reparse point");
                FindClose(handle);
                if (data.Reserved0==0 || data.Reserved0==0xA0000003 || data.Reserved0==0xA000000C) throw new IOException("Redirecting or unknown path tag refused");
            }
            current=Path.GetDirectoryName(current);
        }
    }
    private void TryReport(string stage,UIApplication? app,string? message)
    {
        try
        {
            if (_request==null) return;
            FurnitureJson.Write(RunFile(_request.SessionId+"."+stage+".json"),new FurnitureEvent { RunId=_request.RunId,SessionId=_request.SessionId,Stage=stage,ProcessId=Process.GetCurrentProcess().Id,Version=app?.Application.VersionNumber??_request.Version,VersionBuild=app?.Application.VersionBuild??"",DocumentTitle=app?.ActiveUIDocument?.Document.Title??"",DocumentPath=app?.ActiveUIDocument?.Document.PathName??_documentPath,PlacedElementIds=_placedIds,Message=message });
        }
        catch { /* Parent enforces a bounded readiness timeout if reporting itself fails. */ }
    }
    private sealed class RollbackErrors : IFailuresPreprocessor
    {
        public FailureProcessingResult PreprocessFailures(FailuresAccessor accessor)
        {
            bool errors=false;
            foreach (FailureMessageAccessor failure in accessor.GetFailureMessages())
                if (failure.GetSeverity()==FailureSeverity.Warning) accessor.DeleteWarning(failure); else errors=true;
            return errors ? FailureProcessingResult.ProceedWithRollBack : FailureProcessingResult.Continue;
        }
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    private struct FindData
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
        public uint SizeHigh,SizeLow,Reserved0,Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=14)] public string Alternate;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr FindFirstFile(string file,out FindData data);
    [DllImport("kernel32.dll")] private static extern bool FindClose(IntPtr handle);
}
