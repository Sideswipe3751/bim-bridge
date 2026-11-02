using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using BimBridge.Host;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace BimBridge.Revit;

internal sealed class RevitConnectorExecutor : IConnectorExecutor, IExternalEventHandler
{
    private readonly object _infoLock = new object();
    private readonly ConcurrentQueue<ConnectorRequest> _queue = new ConcurrentQueue<ConnectorRequest>();
    private readonly string _instanceId;
    private ConnectorInfo _cachedInfo;
    private ExternalEvent? _externalEvent;
    private ConnectorServer? _server;
    private readonly RevitFamilySessionService _familySessions = new RevitFamilySessionService();

    public RevitConnectorExecutor(string versionNumber)
    {
        var processId = Process.GetCurrentProcess().Id;
        _instanceId = "revit-" + versionNumber + "-" + processId;
        _cachedInfo = CreateInfo(versionNumber, processId, null);
    }

    public void Attach(ExternalEvent externalEvent) =>
        _externalEvent = externalEvent ?? throw new ArgumentNullException(nameof(externalEvent));

    public void Attach(ConnectorServer server) =>
        _server = server ?? throw new ArgumentNullException(nameof(server));

    public ConnectorInfo GetCachedInfo()
    {
        lock (_infoLock) return CloneInfo(_cachedInfo);
    }

    public void Submit(ConnectorRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        if (_externalEvent == null)
        {
            request.Complete(Failed("Revit ExternalEvent is unavailable", "external_event"));
            return;
        }
        request.SetStatus(ConnectorRequestStatus.WaitingForApplication);
        _queue.Enqueue(request);
        var result = _externalEvent.Raise();
        if (result != ExternalEventRequest.Accepted && result != ExternalEventRequest.Pending)
            request.Complete(Failed("Revit rejected the ExternalEvent request", "external_event"));
    }

    public void Execute(UIApplication application)
    {
        RefreshCachedInfo(application);
        while (_queue.TryDequeue(out var request))
        {
            if (request.IsTerminal) continue;
            if (DateTime.UtcNow > request.DeadlineUtc)
            {
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Expired,
                    Message = "Request expired before Revit execution",
                    ErrorType = "timeout"
                });
                AuditLog.TryWrite(GetCachedInfo(), request.Snapshot());
                continue;
            }
            var targetError = ConnectorTargetGuard.Validate(request.ExpectedTarget, GetCachedInfo());
            if (targetError != null)
            {
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Rejected,
                    Message = "The active Revit target changed before execution",
                    ErrorType = targetError
                });
                AuditLog.TryWrite(GetCachedInfo(), request.Snapshot());
                continue;
            }
            if (!request.TryStart()) continue;
            try
            {
                if (request.Kind == ConnectorRequestKind.Selection)
                    ExecuteSelection(application, request);
                else if (request.Operation == "view.capture")
                    ExecuteViewCapture(application, request);
                else if (request.Operation == "family.session")
                    ExecuteFamilySession(application, request);
                else
                    ExecuteCode(application, request);
            }
            catch (Exception exception)
            {
                request.Complete(Failed(exception.Message, exception.GetType().Name));
            }
            finally
            {
                AuditLog.TryWrite(GetCachedInfo(), request.Snapshot());
            }
        }
        RefreshCachedInfo(application);
        _server?.RefreshDescriptor();
    }

    public string GetName() => "BIM Bridge Revit Connector";

    private void ExecuteFamilySession(UIApplication application, ConnectorRequest request)
    {
        Action refresh = () => { RefreshCachedInfo(application); _server?.RefreshDescriptor(); };
        try
        {
            var result = _familySessions.Execute(application, request, refresh);
            request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Succeeded, Result = result,
                Warnings = _familySessions.Warnings.ToList() });
        }
        catch (Exception exception)
        {
            refresh();
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Failed, ErrorType = "family_session_failed",
                Message = exception.Message, RolledBack = false,
                Warnings = _familySessions.Warnings.ToList(),
                Result = new { document = GetCachedInfo().Document, action = request.FamilySession?.Action,
                    jobId = request.FamilySession?.JobId, atomic = false, lifecycle = _familySessions.FailureState() }
            });
        }
    }

    public void RefreshCachedInfo(UIApplication application)
    {
        var uiDocument = application.ActiveUIDocument;
        DocumentDescriptor? document = null;
        if (uiDocument?.Document != null)
        {
            var activeDocument = uiDocument.Document;
            document = new DocumentDescriptor
            {
                Id = BuildDocumentId(activeDocument),
                Title = activeDocument.Title ?? "",
                Path = string.IsNullOrEmpty(activeDocument.PathName) ? null : activeDocument.PathName
            };
        }
        lock (_infoLock)
        {
            _cachedInfo = CreateInfo(
                application.Application.VersionNumber,
                Process.GetCurrentProcess().Id,
                document);
        }
    }

    private static void ExecuteSelection(UIApplication application, ConnectorRequest request)
    {
        var uiDocument = application.ActiveUIDocument;
        if (uiDocument == null)
        {
            request.Complete(Failed("No active Revit document", "no_active_document"));
            return;
        }
        var document = uiDocument.Document;
        var elements = uiDocument.Selection.GetElementIds().Select(id =>
        {
            var element = document.GetElement(id);
            return new
            {
                id = RevitApiCompatibility.GetElementIdValue(id),
                uniqueId = element?.UniqueId,
                name = element?.Name,
                category = element?.Category?.Name,
                type = element?.GetType().FullName
            };
        }).ToList();
        request.Complete(new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Succeeded,
            Result = new { count = elements.Count, elements }
        });
    }

    private static void ExecuteCode(UIApplication application, ConnectorRequest request)
    {
        var uiDocument = application.ActiveUIDocument;
        if (uiDocument == null)
        {
            request.Complete(Failed("No active Revit document", "no_active_document"));
            return;
        }
        if (request.Mode == "read")
        {
            var result = DynamicRevitCode.Execute(request.Code, application, null);
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = result
            });
            return;
        }

        var document = uiDocument.Document;
        using (var group = new TransactionGroup(document, "BIM Bridge: " + request.Description))
        {
            Transaction? transaction = null;
            RevitFailurePreprocessor? failurePreprocessor = null;
            var changed = false;
            try
            {
                if (group.Start() != TransactionStatus.Started)
                    throw new InvalidOperationException("Unable to start the Revit transaction group");
                transaction = new Transaction(document, "BIM Bridge: " + request.Description);
                if (transaction.Start() != TransactionStatus.Started)
                    throw new InvalidOperationException("Unable to start the Revit transaction");
                failurePreprocessor = new RevitFailurePreprocessor();
                using (var failureOptions = transaction.GetFailureHandlingOptions())
                {
                    failureOptions.SetFailuresPreprocessor(failurePreprocessor);
                    failureOptions.SetClearAfterRollback(true);
                    failureOptions.SetDelayedMiniWarnings(false);
                    failureOptions.SetForcedModalHandling(false);
                    transaction.SetFailureHandlingOptions(failureOptions);
                }
                var result = DynamicRevitCode.Execute(request.Code, application, transaction);
                if (transaction.Commit() != TransactionStatus.Committed)
                    throw new InvalidOperationException(failurePreprocessor.BuildErrorMessage());
                transaction.Dispose();
                transaction = null;
                if (group.Assimilate() != TransactionStatus.Committed)
                    throw new InvalidOperationException("Revit did not assimilate the transaction group");
                changed = true;
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Succeeded,
                    Result = result,
                    RolledBack = false,
                    Warnings = failurePreprocessor.Warnings.ToList()
                });
            }
            catch (Exception exception)
            {
                try
                {
                    if (transaction != null && transaction.GetStatus() == TransactionStatus.Started)
                        transaction.RollBack();
                }
                catch { }
                finally
                {
                    transaction?.Dispose();
                }
                try
                {
                    if (!changed && group.GetStatus() == TransactionStatus.Started)
                        group.RollBack();
                }
                catch { }
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Failed,
                    Message = failurePreprocessor != null && failurePreprocessor.Errors.Count > 0
                        ? failurePreprocessor.BuildErrorMessage()
                        : exception.Message,
                    ErrorType = failurePreprocessor != null && failurePreprocessor.Errors.Count > 0
                        ? "revit_failure"
                        : exception.GetType().Name,
                    RolledBack = true,
                    Warnings = failurePreprocessor?.Warnings.ToList() ?? new List<string>()
                });
            }
        }
    }

    private static void ExecuteViewCapture(UIApplication application, ConnectorRequest request)
    {
        if (request.Mode != "read")
        {
            request.Complete(Failed("view.capture is read-only", "invalid_mode"));
            return;
        }
        if (request.ViewCapture == null)
        {
            request.Complete(Failed("view.capture options are required", "invalid_request"));
            return;
        }
        try
        {
            var result = RevitViewCaptureService.Capture(application, request.ViewCapture);
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = result,
                RolledBack = false
            });
        }
        catch (Exception exception)
        {
            request.Complete(Failed(exception.Message, "view_capture_failed"));
        }
    }

    private ConnectorInfo CreateInfo(string version, int processId, DocumentDescriptor? document) =>
        new ConnectorInfo
        {
            InstanceId = _instanceId,
            Application = "revit",
            ApplicationVersion = version,
            ProcessId = processId,
            ConnectorVersion = "1.1.0-rc.3",
            Document = document,
            Capabilities = new List<string>
            {
                "document.info", "selection.read", "view.capture", "code.read", "code.write", "transaction.rollback", "task.coordination", "family.session"
            }
        };

    private static ConnectorInfo CloneInfo(ConnectorInfo source) => new ConnectorInfo
    {
        ProtocolVersion = source.ProtocolVersion,
        InstanceId = source.InstanceId,
        Application = source.Application,
        ApplicationVersion = source.ApplicationVersion,
        ProcessId = source.ProcessId,
        ConnectorVersion = source.ConnectorVersion,
        Document = source.Document == null ? null : new DocumentDescriptor
        {
            Id = source.Document.Id,
            Title = source.Document.Title,
            Path = source.Document.Path
        },
        Capabilities = new List<string>(source.Capabilities)
    };

    private static string BuildDocumentId(Document document) =>
        string.IsNullOrEmpty(document.PathName)
            ? "unsaved:" + document.GetHashCode()
            : "path:" + document.PathName.ToLowerInvariant();

    private static ConnectorCompletion Failed(string message, string errorType) =>
        new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Failed,
            Message = message,
            ErrorType = errorType
        };
}
