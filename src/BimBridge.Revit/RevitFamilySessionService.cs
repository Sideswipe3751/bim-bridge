using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BimBridge.Host;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace BimBridge.Revit;

// One UI-thread-owned session per Revit process. Lifecycle APIs deliberately run
// outside the connector's modeling transaction. A failed lifecycle is not rollback.
internal sealed class RevitFamilySessionService
{
    private Document? _parking;
    private string? _parkingPath;
    private Session? _session;
    public string Stage { get; private set; } = "validate";
    public List<string> Warnings { get; } = new List<string>();
    private sealed class Session
    {
        public string JobId = "", DocumentName = "", TaskId = "", Path = "";
        public Document Family = null!;
        public long? ViewId;
        public bool Saved;
    }

    public object Execute(UIApplication app, ConnectorRequest request, Action refresh)
    {
        Stage = "validate";
        Warnings.Clear();
        var options = request.FamilySession ?? throw new InvalidOperationException("family_options_required");
        if (request.Mode != "write" || request.ExpectedTarget?.Document == null || string.IsNullOrEmpty(request.TaskId))
            throw new InvalidOperationException("family_task_and_target_required");
        FamilySessionPaths.ValidateName(options.JobId);
        FamilySessionPaths.ValidateName(options.DocumentName);
        var active = app.ActiveUIDocument?.Document ?? throw new InvalidOperationException("family_active_document_required");
        if (active.IsModifiable) throw new InvalidOperationException("family_lifecycle_requires_no_transaction");
        var action = options.Action;
        if (action == "begin") Begin(app, request, options, active);
        else
        {
            var session = _session ?? throw new InvalidOperationException("family_session_missing");
            if (session.JobId != options.JobId || session.DocumentName != options.DocumentName || session.TaskId != request.TaskId)
                throw new InvalidOperationException("family_session_owner_mismatch");
            var abortFromParking = action == "abort" && MatchesOwnedDocument(app, _parking, active, _parkingPath);
            if (!session.Family.IsValidObject ||
                (!MatchesOwnedDocument(app, session.Family, active, session.Path, action == "abort") && !abortFromParking))
                throw new InvalidOperationException("family_session_document_changed");
            AssertParking(app);
            if (action == "prepare_view") { Stage = "prepare_view"; PrepareView(app, session, Warnings); }
            else if (action == "save_close" || action == "abort")
            {
                if (action == "save_close")
                {
                    FamilySessionPaths.AssertNoLinks(session.Path);
                    Stage = "save";
                    request.MarkSaveStarted();
                    session.Family.Save();
                    request.MarkSaveCompleted();
                    session.Saved = true;
                }
                Stage = "activate_parking";
                if (!MatchesOwnedDocument(app, _parking, app.ActiveUIDocument?.Document, _parkingPath))
                    app.OpenAndActivateDocument(_parkingPath);
                if (!MatchesOwnedDocument(app, _parking, app.ActiveUIDocument?.Document, _parkingPath))
                    throw new InvalidOperationException("family_parking_activation_failed");
                // Snapshot while the native document is valid. Abort deliberately
                // leaves its pending modifications unsaved on disk.
                var isModified = session.Family.IsModified;
                var hasSavedFile = session.Saved && File.Exists(session.Path);
                Stage = "close_family";
                if (!session.Family.Close(false)) throw new InvalidOperationException("family_close_failed");
                _session = null;
                // Refresh BEFORE completion so immediately-following requests see parking.
                refresh();
                var result = Result(action, session, true, hasSavedFile, isModified);
                return result;
            }
            else throw new InvalidOperationException("family_action_invalid");
        }
        refresh();
        return Result(action, _session!, false, _session!.Saved && File.Exists(_session.Path), _session.Family.IsModified);
    }

    private void Begin(UIApplication app, ConnectorRequest request, ConnectorFamilySessionOptions options, Document active)
    {
        if (_session != null) throw new InvalidOperationException("family_session_already_open");
        if (active.IsFamilyDocument || active.IsReadOnly || string.IsNullOrEmpty(active.PathName) || !File.Exists(active.PathName))
            throw new InvalidOperationException("family_saved_parking_required");
        if (_parking != null)
        {
            AssertParking(app);
            if (!MatchesOwnedDocument(app, _parking, active, _parkingPath)) throw new InvalidOperationException("family_parking_changed");
        }
        var template = options.TemplatePath;
        if (string.IsNullOrWhiteSpace(template) || !Path.IsPathRooted(template) ||
            !string.Equals(Path.GetExtension(template), ".rft", StringComparison.OrdinalIgnoreCase) || !File.Exists(template))
            throw new InvalidOperationException("family_existing_rft_required");
        var workspace = Environment.GetEnvironmentVariable("BIM_BRIDGE_FAMILY_WORKSPACE");
        if (string.IsNullOrWhiteSpace(workspace)) workspace = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BIM Bridge", "family-jobs");
        if (!Path.IsPathRooted(workspace)) throw new InvalidOperationException("family_workspace_must_be_absolute");
        var path = FamilySessionPaths.Resolve(workspace!, options.JobId, options.DocumentName);
        var directory = Path.GetDirectoryName(path)!;
        if (Directory.Exists(directory) || File.Exists(path)) throw new InvalidOperationException("family_job_already_exists");
        Directory.CreateDirectory(directory);
        FamilySessionPaths.AssertNoLinks(directory);
        using (new FileStream(Path.Combine(directory, ".session-reserved"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        // Parking identity is registered only after every input and output boundary validates.
        if (_parking == null) { _parking = active; _parkingPath = Path.GetFullPath(active.PathName); }
        AssertParking(app);
        Stage = "create_family";
        var family = app.Application.NewFamilyDocument(template);
        _session = new Session { JobId = options.JobId, DocumentName = options.DocumentName, TaskId = request.TaskId!, Path = path, Family = family };
        FamilySessionPaths.AssertNoLinks(path);
        Stage = "save_as";
        request.MarkSaveStarted();
        using (var save = new SaveAsOptions { OverwriteExistingFile = false }) family.SaveAs(path, save);
        request.MarkSaveCompleted();
        _session.Saved = true;
        Stage = "activate_family";
        app.OpenAndActivateDocument(path);
        if (!MatchesOwnedDocument(app, family, app.ActiveUIDocument?.Document, path)) throw new InvalidOperationException("family_activation_failed");
    }

    private void AssertParking(UIApplication app)
    {
        if (_parking == null || !_parking.IsValidObject || _parking.IsFamilyDocument || _parking.IsModifiable ||
            !MatchesOwnedDocument(app, _parking, _parking, _parkingPath))
            throw new InvalidOperationException("family_parking_document_changed");
    }

    // Revit can expose several managed wrappers for the same native document.
    // Never use managed reference equality as native identity. Keep the original
    // wrapper alive and valid so a closed/reopened same-path file is not adopted;
    // require exactly one matching native document in this UIApplication as well.
    private static bool MatchesOwnedDocument(UIApplication app, Document? original, Document? candidate,
        string? expectedPath, bool allowUnsaved = false)
    {
        if (original == null || candidate == null || !original.IsValidObject || !candidate.IsValidObject ||
            original.IsFamilyDocument != candidate.IsFamilyDocument ||
            !string.Equals(original.Title, candidate.Title, StringComparison.Ordinal)) return false;
        if (allowUnsaved && string.IsNullOrEmpty(original.PathName) && string.IsNullOrEmpty(candidate.PathName))
            return app.Application.Documents.Cast<Document>().Count(d => d.IsValidObject && d.IsFamilyDocument &&
                string.IsNullOrEmpty(d.PathName) && string.Equals(d.Title, original.Title, StringComparison.Ordinal)) == 1;
        if (string.IsNullOrEmpty(expectedPath) || string.IsNullOrEmpty(original.PathName) || string.IsNullOrEmpty(candidate.PathName))
            return false;
        var normalized = Path.GetFullPath(expectedPath!);
        if (!string.Equals(Path.GetFullPath(original.PathName), normalized, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetFullPath(candidate.PathName), normalized, StringComparison.OrdinalIgnoreCase)) return false;
        return app.Application.Documents.Cast<Document>().Count(d => d.IsValidObject && !string.IsNullOrEmpty(d.PathName) &&
            string.Equals(Path.GetFullPath(d.PathName), normalized, StringComparison.OrdinalIgnoreCase)) == 1;
    }

    private static void PrepareView(UIApplication app, Session session, List<string> warnings)
    {
        var doc = session.Family;
        View3D view;
        using (var transaction = new Transaction(doc, "BIM Bridge family preview"))
        {
            transaction.Start();
            var failures = new RevitFailurePreprocessor();
            using (var options = transaction.GetFailureHandlingOptions())
            {
                options.SetFailuresPreprocessor(failures);
                options.SetClearAfterRollback(true);
                options.SetDelayedMiniWarnings(false);
                options.SetForcedModalHandling(false);
                transaction.SetFailureHandlingOptions(options);
            }
            view = new FilteredElementCollector(doc).OfClass(typeof(View3D)).Cast<View3D>()
                .FirstOrDefault(v => !v.IsTemplate && v.Name == "BIM Bridge Preview")!;
            if (view == null)
            {
                var type = new FilteredElementCollector(doc).OfClass(typeof(ViewFamilyType)).Cast<ViewFamilyType>()
                    .First(t => t.ViewFamily == ViewFamily.ThreeDimensional);
                view = View3D.CreateIsometric(doc, type.Id);
                view.Name = "BIM Bridge Preview";
            }
            view.DisplayStyle = DisplayStyle.ShadingWithEdges;
            view.DetailLevel = ViewDetailLevel.Fine;
            view.AreAnnotationCategoriesHidden = true;
            view.Scale = 20;
            var bounds = ModelBounds(doc);
            var size = Math.Max(bounds.Max.X - bounds.Min.X, Math.Max(bounds.Max.Y - bounds.Min.Y, bounds.Max.Z - bounds.Min.Z));
            var padding = Math.Max(100.0 / 304.8, size * 0.2);
            var offset = new XYZ(padding, padding, padding);
            view.SetSectionBox(new BoundingBoxXYZ { Min = bounds.Min - offset, Max = bounds.Max + offset });
            view.IsSectionBoxActive = true;
            var center = (bounds.Min + bounds.Max) * 0.5;
            var forward = new XYZ(-0.48, 0.64, -0.6);
            view.SetOrientation(new ViewOrientation3D(center - forward * Math.Max(1, size) * 3,
                new XYZ(-0.36, 0.48, 0.8), forward));
            doc.Regenerate();
            // Native export obeys CropBox, not the UI zoom. Compute it in the
            // oriented view coordinates rather than fitting reference planes.
            var crop = view.CropBox;
            var inverse = crop.Transform.Inverse;
            var cropMin = new XYZ(double.MaxValue, double.MaxValue, double.MaxValue);
            var cropMax = new XYZ(double.MinValue, double.MinValue, double.MinValue);
            foreach (var form in new FilteredElementCollector(doc).OfClass(typeof(GenericForm)).Cast<GenericForm>())
            {
                if (!form.IsSolid) continue;
                var box = form.get_BoundingBox(null);
                if (box == null) continue;
                for (var i = 0; i < 8; i++)
                {
                    var world = box.Transform.OfPoint(new XYZ((i & 1) == 0 ? box.Min.X : box.Max.X,
                        (i & 2) == 0 ? box.Min.Y : box.Max.Y, (i & 4) == 0 ? box.Min.Z : box.Max.Z));
                    var point = inverse.OfPoint(world);
                    cropMin = new XYZ(Math.Min(cropMin.X, point.X), Math.Min(cropMin.Y, point.Y), Math.Min(cropMin.Z, point.Z));
                    cropMax = new XYZ(Math.Max(cropMax.X, point.X), Math.Max(cropMax.Y, point.Y), Math.Max(cropMax.Z, point.Z));
                }
            }
            crop.Min = cropMin - offset;
            crop.Max = cropMax + offset;
            view.CropBox = crop;
            view.CropBoxActive = true;
            view.CropBoxVisible = false;
            view.TemporaryViewModes.PreviewFamilyVisibility = PreviewFamilyVisibilityMode.On;
            view.RevealConstraintsMode = false;
            TransactionStatus commit;
            try { commit = transaction.Commit(); }
            finally { warnings.AddRange(failures.Warnings); }
            if (commit != TransactionStatus.Committed)
                throw new InvalidOperationException(failures.BuildErrorMessage());
        }
        session.ViewId = RevitApiCompatibility.GetElementIdValue(view.Id);
        app.ActiveUIDocument.ActiveView = view;
    }

    private static BoundingBoxXYZ ModelBounds(Document doc)
    {
        var min = new XYZ(double.MaxValue, double.MaxValue, double.MaxValue);
        var max = new XYZ(double.MinValue, double.MinValue, double.MinValue);
        var found = false;
        foreach (var form in new FilteredElementCollector(doc).OfClass(typeof(GenericForm)).Cast<GenericForm>())
        {
            if (!form.IsSolid) continue;
            var bounds = form.get_BoundingBox(null);
            if (bounds == null) continue;
            for (var i = 0; i < 8; i++)
            {
                var point = bounds.Transform.OfPoint(new XYZ((i & 1) == 0 ? bounds.Min.X : bounds.Max.X,
                    (i & 2) == 0 ? bounds.Min.Y : bounds.Max.Y, (i & 4) == 0 ? bounds.Min.Z : bounds.Max.Z));
                min = new XYZ(Math.Min(min.X, point.X), Math.Min(min.Y, point.Y), Math.Min(min.Z, point.Z));
                max = new XYZ(Math.Max(max.X, point.X), Math.Max(max.Y, point.Y), Math.Max(max.Z, point.Z));
                found = true;
            }
        }
        if (!found) throw new InvalidOperationException("family_preview_requires_solid_geometry");
        return new BoundingBoxXYZ { Min = min, Max = max };
    }

    private object Result(string action, Session s, bool closed, bool hasSavedFile, bool isModified) => new
    {
        action, jobId = s.JobId, document = Describe(closed ? _parking! : s.Family),
        parkingDocument = Describe(_parking!), familyDocument = new DocumentDescriptor
        { Id = "path:" + s.Path.ToLowerInvariant(), Title = s.DocumentName, Path = s.Path },
        viewId = s.ViewId, artifactPath = s.Path, hasSavedFile, isModified,
        saved = hasSavedFile && !isModified, closed
    };

    public object FailureState() => new
    {
        stage = Stage, sessionOpen = _session != null && _session.Family.IsValidObject,
        artifactPath = _session?.Path,
        hasSavedFile = _session != null && _session.Saved && File.Exists(_session.Path),
        isModified = _session != null && _session.Family.IsValidObject ? (bool?)_session.Family.IsModified : null,
        saved = _session != null && _session.Saved && File.Exists(_session.Path) && _session.Family.IsValidObject && !_session.Family.IsModified,
        parkingDocument = _parking != null && _parking.IsValidObject ? Describe(_parking) : null
    };

    private static DocumentDescriptor Describe(Document doc) => new DocumentDescriptor
    { Id = "path:" + doc.PathName.ToLowerInvariant(), Title = doc.Title, Path = doc.PathName };
}
