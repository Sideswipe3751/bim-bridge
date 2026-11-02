using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Security.Cryptography;

namespace BimBridge.Host;

/// <summary>Instance-local, transport-independent exclusive task ownership.</summary>
/// <remarks>One coordinator belongs to one connector server. Tokens are capabilities,
/// not agent identities. A lease expiry never proves an admitted native operation stopped.</remarks>
public sealed class TaskCoordinator
{
    private sealed class Entry
    {
        public string Id = "";
        public string Token = "";
        public string Name = "";
        public string Owner = "";
        public string State = "queued";
        public string? DrainOutcome;
        public int LeaseSeconds;
        public double Deadline;
        public ConnectorRequest? InFlight;
    }

    private readonly object _gate = new object();
    private readonly Func<double> _now;
    private readonly int _capacity;
    private readonly Dictionary<string, Entry> _entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
    private readonly List<Entry> _queue = new List<Entry>();
    private readonly Queue<string> _history = new Queue<string>();
    private Entry? _active;
    private ConnectorRequest? _legacy;
    private const int HistoryLimit = 128;

    public TaskCoordinator(Func<double>? monotonicSeconds = null, int capacity = 128)
    {
        if (capacity < 1 || capacity > 128) throw new ArgumentOutOfRangeException(nameof(capacity));
        _capacity = capacity;
        _now = monotonicSeconds ?? (() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency);
    }

    public TaskSubmission Submit(string name, string owner, int leaseSeconds = 120)
    {
        ValidateLease(leaseSeconds);
        if (string.IsNullOrWhiteSpace(name) || name.Length > 200) throw new ArgumentException("task_name_invalid");
        if (string.IsNullOrWhiteSpace(owner) || owner.Length > 200) throw new ArgumentException("task_owner_invalid");
        lock (_gate)
        {
            Sweep();
            if (_queue.Count + (_active == null ? 0 : 1) >= _capacity)
                throw new InvalidOperationException("task_queue_full");
            var entry = new Entry { Id = Guid.NewGuid().ToString("N"), Token = NewToken(), Name = name,
                Owner = owner, LeaseSeconds = leaseSeconds, Deadline = _now() + leaseSeconds };
            _entries.Add(entry.Id, entry);
            _queue.Add(entry);
            Sweep();
            return new TaskSubmission { Task = Snapshot(entry), Token = entry.Token };
        }
    }

    public TaskSnapshot Poll(string taskId, string token)
    {
        lock (_gate) { Sweep(); return Snapshot(Authenticate(taskId, token)); }
    }

    public TaskSnapshot Renew(string taskId, string token, int leaseSeconds = 120)
    {
        ValidateLease(leaseSeconds);
        lock (_gate)
        {
            Sweep();
            var entry = Authenticate(taskId, token);
            if (entry.State != "queued" && entry.State != "active") throw new InvalidOperationException("task_not_renewable");
            entry.LeaseSeconds = leaseSeconds;
            entry.Deadline = _now() + leaseSeconds;
            return Snapshot(entry);
        }
    }

    public TaskSnapshot Release(string taskId, string token)
    {
        lock (_gate)
        {
            Sweep();
            var entry = Authenticate(taskId, token);
            if (entry.State == "completed") return Snapshot(entry);
            if (entry.State != "active") throw new InvalidOperationException("task_not_active");
            if (entry.InFlight != null) throw new InvalidOperationException("task_request_in_flight");
            Finish(entry, "completed");
            Sweep();
            return Snapshot(entry);
        }
    }

    public TaskSnapshot Cancel(string taskId, string token)
    {
        lock (_gate)
        {
            Sweep();
            var entry = Authenticate(taskId, token);
            if (entry.State == "queued") { _queue.Remove(entry); Finish(entry, "cancelled"); }
            else if (entry.State == "active") Drain(entry, "cancelled");
            Sweep();
            return Snapshot(entry);
        }
    }

    // Public snapshots deliberately omit capability tokens.
    public TaskSnapshot[] Status()
    {
        lock (_gate) { Sweep(); return _entries.Values.Select(Snapshot).ToArray(); }
    }

    public bool TryAdmit(ConnectorRequest request, string? taskId, string? token, out string? error)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        lock (_gate)
        {
            Sweep();
            error = null;
            if (request.IsTerminal) { error = "request_already_terminal"; return false; }
            if (!string.IsNullOrEmpty(taskId) || !string.IsNullOrEmpty(token))
            {
                if (string.IsNullOrEmpty(taskId) || string.IsNullOrEmpty(token) ||
                    !_entries.TryGetValue(taskId!, out var entry) || !TokenEquals(entry.Token, token!))
                { error = "task_token_invalid"; return false; }
                if (entry != _active || entry.State != "active") { error = "task_not_active"; return false; }
                if (entry.InFlight != null) { error = "task_request_in_flight"; return false; }
                entry.InFlight = request;
                return true;
            }
            if (_active != null || _queue.Count > 0) { error = "instance_reserved"; return false; }
            if (_legacy != null) { error = "instance_request_in_flight"; return false; }
            _legacy = request;
            return true;
        }
    }

    private void Sweep()
    {
        double now = _now();
        if (_legacy != null && _legacy.IsTerminal) _legacy = null;
        foreach (var queued in _queue.ToArray())
            if (now >= queued.Deadline) { _queue.Remove(queued); Finish(queued, "expired"); }
        if (_active != null)
        {
            var current = _active;
            if (current.InFlight != null && current.InFlight.IsTerminal) current.InFlight = null;
            if (current.State == "active" && now >= current.Deadline) Drain(current, "expired");
            if (current.State == "draining" && current.InFlight == null)
                Finish(current, current.DrainOutcome ?? "expired");
        }
        if (_active == null && _legacy == null && _queue.Count > 0)
        {
            _active = _queue[0]; _queue.RemoveAt(0);
            _active.State = "active";
            _active.Deadline = now + _active.LeaseSeconds;
        }
    }

    private void Drain(Entry entry, string outcome)
    {
        entry.State = "draining"; entry.DrainOutcome = outcome;
        // TryStart/TryCancel share the request lock. A not-yet-started step
        // must not execute after its ownership is cancelled or expires.
        // If native execution already won, preserve draining until terminal.
        if (entry.InFlight != null)
        {
            entry.InFlight.TryCancel("Task ownership " + outcome + " before native execution");
            if (entry.InFlight.IsTerminal) entry.InFlight = null;
        }
        if (entry.InFlight == null) Finish(entry, outcome);
    }

    private void Finish(Entry entry, string outcome)
    {
        entry.State = outcome;
        if (_active == entry) _active = null;
        _history.Enqueue(entry.Id);
        while (_history.Count > HistoryLimit) _entries.Remove(_history.Dequeue());
    }

    private Entry Authenticate(string taskId, string token)
    {
        if (string.IsNullOrEmpty(taskId) || string.IsNullOrEmpty(token) ||
            !_entries.TryGetValue(taskId, out var entry) || !TokenEquals(entry.Token, token))
            throw new InvalidOperationException("task_token_invalid");
        return entry;
    }

    private TaskSnapshot Snapshot(Entry entry) => new TaskSnapshot
    {
        TaskId = entry.Id, Name = entry.Name, Owner = entry.Owner, Status = entry.State,
        QueuePosition = entry.State == "queued" ? _queue.IndexOf(entry) + 1 : 0,
        LeaseRemainingSeconds = entry.State == "queued" || entry.State == "active"
            ? Math.Max(0, entry.Deadline - _now()) : 0,
        InFlightRequestId = entry.InFlight?.RequestId
    };

    private static void ValidateLease(int seconds)
    {
        if (seconds < 10 || seconds > 300) throw new ArgumentOutOfRangeException(nameof(seconds), "task_lease_out_of_range");
    }

    private static string NewToken()
    {
        var bytes = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        return Convert.ToBase64String(bytes);
    }

    private static bool TokenEquals(string expected, string actual)
    {
        if (expected.Length != actual.Length) return false;
        int difference = 0;
        for (int i = 0; i < expected.Length; i++) difference |= expected[i] ^ actual[i];
        return difference == 0;
    }
}
