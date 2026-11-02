using System;
using System.Collections.Generic;
using System.Threading;

namespace BimBridge.Host;

public enum ConnectorRequestKind
{
    Selection = 0,
    Execute = 1
}

public enum ConnectorRequestStatus
{
    Queued = 0,
    WaitingForApplication = 1,
    Running = 2,
    Succeeded = 3,
    Failed = 4,
    Rejected = 5,
    Expired = 6,
    Cancelled = 7
}

public sealed class DocumentDescriptor
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Path { get; set; }
}

public sealed class ConnectorInfo
{
    public int ProtocolVersion { get; set; } = 1;
    public string InstanceId { get; set; } = "";
    public string Application { get; set; } = "";
    public string ApplicationVersion { get; set; } = "";
    public int ProcessId { get; set; }
    public string ConnectorVersion { get; set; } = "1.1.0-rc.3";
    public DocumentDescriptor? Document { get; set; }
    public List<string> Capabilities { get; set; } = new List<string>();
}

public sealed class ConnectorExecutionTarget
{
    public string Application { get; set; } = "";
    public string Release { get; set; } = "";
    public string ApiVariant { get; set; } = "";
    public string InstanceId { get; set; } = "";
    public int ProcessId { get; set; }
    public DocumentDescriptor? Document { get; set; }
}

public static class ConnectorTargetGuard
{
    public static string? Validate(ConnectorExecutionTarget? expected, ConnectorInfo actual)
    {
        if (expected == null) return null;
        if (!string.Equals(expected.Application, actual.Application, StringComparison.OrdinalIgnoreCase))
            return "application_changed";
        if (!string.Equals(expected.Release, actual.ApplicationVersion, StringComparison.Ordinal))
            return "release_changed";
        if (!string.IsNullOrEmpty(expected.ApiVariant) &&
            !string.Equals(expected.ApiVariant, actual.ApplicationVersion, StringComparison.Ordinal))
            return "api_variant_changed";
        if (!string.Equals(expected.InstanceId, actual.InstanceId, StringComparison.Ordinal))
            return "instance_changed";
        if (expected.ProcessId != actual.ProcessId)
            return "process_changed";
        if (expected.Document == null || actual.Document == null)
            return "document_missing";
        if (!string.Equals(expected.Document.Id, actual.Document.Id, StringComparison.OrdinalIgnoreCase))
            return "document_changed";
        if (!string.Equals(expected.Document.Title, actual.Document.Title, StringComparison.Ordinal))
            return "document_title_changed";
        return null;
    }
}

public sealed class ConnectorInstanceDescriptor
{
    public int ProtocolVersion { get; set; } = 1;
    public string InstanceId { get; set; } = "";
    public string Application { get; set; } = "";
    public string ApplicationVersion { get; set; } = "";
    public int ProcessId { get; set; }
    public string Url { get; set; } = "";
    public string Token { get; set; } = "";
    public string StartedAtUtc { get; set; } = "";
    public DocumentDescriptor? Document { get; set; }
    public List<string> Capabilities { get; set; } = new List<string>();
}

public sealed class ConnectorCompletion
{
    public ConnectorRequestStatus Status { get; set; }
    public object? Result { get; set; }
    public string? Message { get; set; }
    public string? ErrorType { get; set; }
    public bool RolledBack { get; set; }
    public List<string> Warnings { get; set; } = new List<string>();
}

public sealed class ConnectorViewCaptureOptions
{
    public long? ViewId { get; set; }
    public string? ViewUniqueId { get; set; }
    public string? ViewName { get; set; }
    public string? FileStem { get; set; }
    public int PixelSize { get; set; } = 1600;
    public int Dpi { get; set; } = 150;
    public string FitDirection { get; set; } = "horizontal";
}

public sealed class ConnectorFamilySessionOptions
{
    public string Action { get; set; } = "";
    public string JobId { get; set; } = "";
    public string DocumentName { get; set; } = "";
    public string? TemplatePath { get; set; }
}

public sealed class TaskControlPayload
{
    public string Action { get; set; } = "";
    public string? TaskId { get; set; }
    public string? Token { get; set; }
    public string? Name { get; set; }
    public string? Owner { get; set; }
    public int LeaseSeconds { get; set; } = 120;
}

public sealed class TaskSnapshot
{
    public string TaskId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Owner { get; set; } = "";
    public string Status { get; set; } = "";
    public int QueuePosition { get; set; }
    public double LeaseRemainingSeconds { get; set; }
    public string? InFlightRequestId { get; set; }
}

public sealed class TaskSubmission
{
    public TaskSnapshot Task { get; set; } = new TaskSnapshot();
    public string Token { get; set; } = "";
}

public sealed class ConnectorRequestSnapshot
{
    public string RequestId { get; set; } = "";
    public string Status { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Mode { get; set; } = "";
    public string Description { get; set; } = "";
    public object? Result { get; set; }
    public string? Message { get; set; }
    public string? ErrorType { get; set; }
    public bool RolledBack { get; set; }
    public List<string> Warnings { get; set; } = new List<string>();
    public long ElapsedMilliseconds { get; set; }
    public string CreatedAtUtc { get; set; } = "";
    public string DeadlineUtc { get; set; } = "";
    public string? StartedAtUtc { get; set; }
    public string? CompletedAtUtc { get; set; }
    public string? SaveStartedAtUtc { get; set; }
    public string? SaveCompletedAtUtc { get; set; }
    public double QueueMilliseconds { get; set; }
    public double NativeMilliseconds { get; set; }
}

public sealed class ConnectorRequest : IDisposable
{
    private readonly object _sync = new object();
    private readonly ManualResetEvent _completed = new ManualResetEvent(false);
    private ConnectorRequestStatus _status = ConnectorRequestStatus.Queued;
    private DateTime? _startedAtUtc;
    private DateTime? _completedAtUtc;
    private ConnectorCompletion? _completion;
    private DateTime? _saveStartedAtUtc;
    private DateTime? _saveCompletedAtUtc;
    private readonly System.Diagnostics.Stopwatch _lifetime = System.Diagnostics.Stopwatch.StartNew();
    private double? _startedMilliseconds;
    private double? _completedMilliseconds;

    public ConnectorRequest(
        ConnectorRequestKind kind,
        string mode,
        string description,
        string code,
        int timeoutSeconds,
        ConnectorExecutionTarget? expectedTarget = null,
        string operation = "code",
        ConnectorViewCaptureOptions? viewCapture = null,
        ConnectorFamilySessionOptions? familySession = null,
        string? taskId = null)
    {
        RequestId = Guid.NewGuid().ToString("N");
        Kind = kind;
        Mode = mode;
        Description = description ?? "";
        Code = code ?? "";
        TimeoutSeconds = timeoutSeconds;
        ExpectedTarget = expectedTarget;
        Operation = string.IsNullOrWhiteSpace(operation) ? "code" : operation;
        ViewCapture = viewCapture;
        FamilySession = familySession;
        TaskId = taskId;
        CreatedAtUtc = DateTime.UtcNow;
        DeadlineUtc = CreatedAtUtc.AddSeconds(timeoutSeconds);
    }

    public string RequestId { get; }
    public ConnectorRequestKind Kind { get; }
    public string Mode { get; }
    public string Description { get; }
    public string Code { get; }
    public int TimeoutSeconds { get; }
    public ConnectorExecutionTarget? ExpectedTarget { get; }
    public string Operation { get; }
    public ConnectorViewCaptureOptions? ViewCapture { get; }
    public ConnectorFamilySessionOptions? FamilySession { get; }
    public string? TaskId { get; }
    public DateTime CreatedAtUtc { get; }
    public DateTime DeadlineUtc { get; }

    public bool IsTerminal
    {
        get { lock (_sync) return IsTerminalStatus(_status); }
    }

    // Atomically exclude cancellation before entering the native operation.
    // A terminal request must never execute after the task gate has drained it.
    public bool TryStart()
    {
        lock (_sync)
        {
            if (IsTerminalStatus(_status) || _status == ConnectorRequestStatus.Running) return false;
            _status = ConnectorRequestStatus.Running;
            _startedAtUtc = DateTime.UtcNow;
            _startedMilliseconds = _lifetime.Elapsed.TotalMilliseconds;
            return true;
        }
    }

    public void SetStatus(ConnectorRequestStatus status, string? message = null)
    {
        lock (_sync)
        {
            if (IsTerminalStatus(_status)) return;
            _status = status;
            if (status == ConnectorRequestStatus.Running && !_startedAtUtc.HasValue)
            {
                _startedAtUtc = DateTime.UtcNow;
                _startedMilliseconds = _lifetime.Elapsed.TotalMilliseconds;
            }
            if (message != null)
            {
                _completion ??= new ConnectorCompletion();
                _completion.Message = message;
            }
        }
    }

    public void Complete(ConnectorCompletion completion)
    {
        if (completion == null) throw new ArgumentNullException(nameof(completion));
        lock (_sync)
        {
            if (IsTerminalStatus(_status)) return;
            _completion = completion;
            _status = completion.Status;
            _completedAtUtc = DateTime.UtcNow;
            _completedMilliseconds = _lifetime.Elapsed.TotalMilliseconds;
            _completed.Set();
        }
    }

    public bool TryCancel(string message)
    {
        lock (_sync)
        {
            if (IsTerminalStatus(_status) || _status == ConnectorRequestStatus.Running)
                return false;
            _completion = new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Cancelled,
                Message = message
            };
            _status = ConnectorRequestStatus.Cancelled;
            _completedAtUtc = DateTime.UtcNow;
            _completedMilliseconds = _lifetime.Elapsed.TotalMilliseconds;
            _completed.Set();
            return true;
        }
    }

    public bool Wait(int millisecondsTimeout) => _completed.WaitOne(millisecondsTimeout);

    public void MarkSaveStarted() { lock (_sync) _saveStartedAtUtc = DateTime.UtcNow; }
    public void MarkSaveCompleted() { lock (_sync) _saveCompletedAtUtc = DateTime.UtcNow; }

    public ConnectorRequestSnapshot Snapshot()
    {
        lock (_sync)
        {
            var completed = _completedAtUtc ?? DateTime.UtcNow;
            var started = _startedAtUtc ?? CreatedAtUtc;
            return new ConnectorRequestSnapshot
            {
                RequestId = RequestId,
                Status = StatusName(_status),
                Kind = Kind == ConnectorRequestKind.Selection ? "selection" : "execute",
                Mode = Mode,
                Description = Description,
                Result = NormalizeJson(_completion?.Result),
                Message = _completion?.Message,
                ErrorType = _completion?.ErrorType,
                RolledBack = _completion?.RolledBack ?? false,
                Warnings = new List<string>(_completion?.Warnings ?? new List<string>()),
                ElapsedMilliseconds = (long)(completed - started).TotalMilliseconds,
                CreatedAtUtc = CreatedAtUtc.ToString("o"),
                DeadlineUtc = DeadlineUtc.ToString("o"),
                StartedAtUtc = _startedAtUtc?.ToString("o"),
                CompletedAtUtc = _completedAtUtc?.ToString("o"),
                SaveStartedAtUtc = _saveStartedAtUtc?.ToString("o"),
                SaveCompletedAtUtc = _saveCompletedAtUtc?.ToString("o"),
                QueueMilliseconds = _startedMilliseconds ?? (_completedMilliseconds ?? _lifetime.Elapsed.TotalMilliseconds),
                NativeMilliseconds = _startedMilliseconds.HasValue
                    ? Math.Max(0, (_completedMilliseconds ?? _lifetime.Elapsed.TotalMilliseconds) - _startedMilliseconds.Value) : 0
            };
        }
    }

    public static string StatusName(ConnectorRequestStatus status)
    {
        switch (status)
        {
            case ConnectorRequestStatus.Queued: return "queued";
            case ConnectorRequestStatus.WaitingForApplication: return "waiting_for_application";
            case ConnectorRequestStatus.Running: return "running";
            case ConnectorRequestStatus.Succeeded: return "succeeded";
            case ConnectorRequestStatus.Failed: return "failed";
            case ConnectorRequestStatus.Rejected: return "rejected";
            case ConnectorRequestStatus.Expired: return "expired";
            case ConnectorRequestStatus.Cancelled: return "cancelled";
            default: return "unknown";
        }
    }

    private static bool IsTerminalStatus(ConnectorRequestStatus status) =>
        status == ConnectorRequestStatus.Succeeded ||
        status == ConnectorRequestStatus.Failed ||
        status == ConnectorRequestStatus.Rejected ||
        status == ConnectorRequestStatus.Expired ||
        status == ConnectorRequestStatus.Cancelled;

    private static object? NormalizeJson(object? value)
    {
        return JsonCodec.Normalize(value);
    }

    public void Dispose() => _completed.Dispose();
}

public interface IConnectorExecutor
{
    ConnectorInfo GetCachedInfo();
    void Submit(ConnectorRequest request);
}
