using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using BimBridge.Host;
using Autodesk.AutoCAD.ApplicationServices.Core;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;

namespace BimBridge.AutoCAD;

internal sealed class AutoCADConnectorExecutor : IConnectorExecutor
{
    private readonly object _infoLock = new object();
    private readonly ConcurrentQueue<ConnectorRequest> _queue = new ConcurrentQueue<ConnectorRequest>();
    private readonly string _instanceId;
    private ConnectorInfo _cachedInfo;
    private ConnectorServer? _server;

    public AutoCADConnectorExecutor(string version)
    {
        if (string.IsNullOrWhiteSpace(version)) throw new ArgumentException("Version is required", nameof(version));
        var processId = Process.GetCurrentProcess().Id;
        _instanceId = "autocad-" + version + "-" + processId;
        _cachedInfo = CreateInfo(version, processId, null);
    }

    public void Attach(ConnectorServer server) =>
        _server = server ?? throw new ArgumentNullException(nameof(server));

    public ConnectorInfo GetCachedInfo()
    {
        lock (_infoLock) return CloneInfo(_cachedInfo);
    }

    public void Submit(ConnectorRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        request.SetStatus(ConnectorRequestStatus.WaitingForApplication);
        _queue.Enqueue(request);
    }

    public void ProcessPending()
    {
        RefreshCachedInfo();
        while (_queue.TryDequeue(out var request))
        {
            if (request.IsTerminal) continue;
            if (DateTime.UtcNow > request.DeadlineUtc)
            {
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Expired,
                    Message = "Request expired before AutoCAD execution",
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
                    Message = "The active AutoCAD target changed before execution",
                    ErrorType = targetError
                });
                AuditLog.TryWrite(GetCachedInfo(), request.Snapshot());
                continue;
            }
            if (!request.TryStart()) continue;
            try
            {
                if (request.Kind == ConnectorRequestKind.Selection)
                    ExecuteSelection(request);
                else
                    ExecuteCode(request);
            }
            catch (Exception ex)
            {
                request.Complete(Failed(ex.Message, ex.GetType().Name));
            }
            finally
            {
                AuditLog.TryWrite(GetCachedInfo(), request.Snapshot());
            }
        }
        RefreshCachedInfo();
        _server?.RefreshDescriptor();
    }

    private static void ExecuteSelection(ConnectorRequest request)
    {
        var document = Application.DocumentManager.MdiActiveDocument;
        if (document == null)
        {
            request.Complete(Failed("No active AutoCAD document", "no_active_document"));
            return;
        }
        var selected = document.Editor.SelectImplied();
        if (selected.Status != PromptStatus.OK || selected.Value == null)
        {
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = new { count = 0, entities = Array.Empty<object>() }
            });
            return;
        }
        using (var transaction = document.Database.TransactionManager.StartOpenCloseTransaction())
        {
            var entities = selected.Value.GetObjectIds().Select(id =>
            {
                var dbObject = transaction.GetObject(id, OpenMode.ForRead, false);
                var entity = dbObject as Entity;
                return new
                {
                    objectId = id.ToString(),
                    handle = id.Handle.ToString(),
                    type = dbObject.GetRXClass().Name,
                    layer = entity?.Layer
                };
            }).ToList();
            transaction.Commit();
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = new { count = entities.Count, entities }
            });
        }
    }

    private static void ExecuteCode(ConnectorRequest request)
    {
        var document = Application.DocumentManager.MdiActiveDocument;
        if (document == null)
        {
            request.Complete(Failed("No active AutoCAD document", "no_active_document"));
            return;
        }
        if (request.Mode == "read")
        {
            using (var transaction = document.Database.TransactionManager.StartOpenCloseTransaction())
            {
                var result = DynamicAutoCADCode.Execute(request.Code, document, transaction);
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Succeeded,
                    Result = result
                });
            }
            return;
        }

        using (document.LockDocument())
        using (var transaction = document.Database.TransactionManager.StartTransaction())
        {
            try
            {
                var result = DynamicAutoCADCode.Execute(request.Code, document, transaction);
                transaction.Commit();
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Succeeded,
                    Result = result,
                    RolledBack = false
                });
            }
            catch (Exception ex)
            {
                try { transaction.Abort(); } catch { }
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Failed,
                    Message = ex.Message,
                    ErrorType = ex.GetType().Name,
                    RolledBack = true
                });
            }
        }
    }

    private void RefreshCachedInfo()
    {
        var document = Application.DocumentManager.MdiActiveDocument;
        DocumentDescriptor? descriptor = null;
        if (document != null)
        {
            var filename = document.Database.Filename;
            descriptor = new DocumentDescriptor
            {
                Id = string.IsNullOrEmpty(filename)
                    ? "unsaved:" + document.Name
                    : "path:" + filename.ToLowerInvariant(),
                Title = document.Name ?? "",
                Path = string.IsNullOrEmpty(filename) ? null : filename
            };
        }
        lock (_infoLock)
        {
            _cachedInfo = CreateInfo(_cachedInfo.ApplicationVersion, Process.GetCurrentProcess().Id, descriptor);
        }
    }

    private ConnectorInfo CreateInfo(string version, int processId, DocumentDescriptor? document) =>
        new ConnectorInfo
        {
            InstanceId = _instanceId,
            Application = "autocad",
            ApplicationVersion = version,
            ProcessId = processId,
            ConnectorVersion = "1.1.0-rc.3",
            Document = document,
            Capabilities = new List<string>
            {
                "document.info", "selection.read", "code.read", "code.write", "transaction.rollback"
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

    private static ConnectorCompletion Failed(string message, string errorType) =>
        new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Failed,
            Message = message,
            ErrorType = errorType
        };
}
