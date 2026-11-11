using BimBridge.Host;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

public static class TaskCoordinatorTests
{
    private sealed class TaskExecutor : IConnectorExecutor
    {
        public string? Title = "DisposableTaskTest";
        public bool Delay;
        public ConnectorRequest? Pending;
        public ConnectorRequestKind LastKind;
        public ConnectorRequest? LastRequest;
        public ConnectorInfo GetCachedInfo() => new ConnectorInfo
        {
            InstanceId = "task-http-test", Application = "revit", ApplicationVersion = "2024",
            ProcessId = Process.GetCurrentProcess().Id,
            Document = Title == null ? null : new DocumentDescriptor
                { Id = "task-doc", Title = Title, Path = "C:/private/model.rvt" },
            Capabilities = new List<string> { "code.read", "code.write", "selection.read", "family.session" }
        };
        public void Submit(ConnectorRequest request)
        {
            LastKind = request.Kind;
            LastRequest = request;
            string? mismatch = ConnectorTargetGuard.Validate(request.ExpectedTarget, GetCachedInfo());
            if (mismatch != null)
            {
                request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Rejected, ErrorType = mismatch });
                return;
            }
            request.SetStatus(ConnectorRequestStatus.Running);
            if (Delay) { Pending = request; return; }
            Done(request);
        }
    }

    public static async Task RunHttp()
    {
        var directory = Path.Combine(Path.GetTempPath(), "bim-bridge-task-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start(); int port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        try
        {
            var executor = new TaskExecutor();
            using var server = new ConnectorServer(executor, new ConnectorOptions { Port = port, InstanceDirectory = directory });
            server.Start();
            using var descriptor = JsonDocument.Parse(File.ReadAllText(Directory.GetFiles(directory, "*.json").Single()));
            using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + server.Port) };
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", descriptor.RootElement.GetProperty("token").GetString());
            var target = new { application = "revit", release = "2024", apiVariant = "2024", instanceId = "task-http-test",
                processId = Process.GetCurrentProcess().Id, document = new { id = "task-doc", title = "DisposableTaskTest" } };
            async Task<(int Code, JsonElement Body)> Post(object payload)
            {
                using var content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
                using var response = await client.PostAsync("/v1/execute", content);
                using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                return ((int)response.StatusCode, body.RootElement.Clone());
            }
            async Task<(int Code, JsonElement Body)> Control(string action, string? id = null, string? token = null,
                object? requestTarget = null, string owner = "test-agent")
                => await Post(new { mode = action == "status" ? "read" : "write", operation = "task.control", target = requestTarget ?? target,
                    taskControl = new { action, taskId = id, token, name = "HTTP family task", owner, leaseSeconds = 120 } });
            var submitted = await Control("submit");
            Check(submitted.Code == 200, "HTTP submit failed");
            string id = submitted.Body.GetProperty("task").GetProperty("taskId").GetString()!;
            string token = submitted.Body.GetProperty("token").GetString()!;
            Check((await Control("poll", id, token)).Body.GetProperty("status").GetString() == "active", "HTTP poll failed");
            Check((await Control("renew", id, token)).Code == 200, "HTTP renew failed");
            var familyOptions = new { action = "begin", jobId = "cab01", documentName = "Family", templatePath = "C:/test.rft" };
            Check((await Post(new { mode = "write", operation = "family.session", target, familySession = familyOptions })).Code == 400,
                "family lifecycle accepted missing ownership");
            Check((await Post(new { mode = "read", operation = "family.session", target, taskId = id, taskToken = token, familySession = familyOptions })).Code == 400,
                "family lifecycle accepted read intent");
            Check((await Post(new { mode = "write", operation = "family.session", target, taskId = id, taskToken = "bad", familySession = familyOptions })).Code == 429,
                "family lifecycle accepted wrong ownership");
            var family = await Post(new { mode = "write", operation = "family.session", target, taskId = id, taskToken = token, familySession = familyOptions });
            Check(family.Code == 202 && executor.LastRequest?.Operation == "family.session" && executor.LastRequest?.TaskId == id &&
                executor.LastRequest?.FamilySession?.JobId == "cab01" && executor.LastRequest?.Code == "", "family options/task ownership not forwarded");
            var timing = executor.LastRequest!.Snapshot();
            Check(timing.StartedAtUtc != null && timing.CompletedAtUtc != null && timing.QueueMilliseconds >= 0 && timing.NativeMilliseconds >= 0,
                "request timing boundaries missing");
            var status = await Control("status");
            Check(status.Code == 200 && !status.Body.GetRawText().Contains(token), "status leaked task secret");
            Check((await Control("poll", id, "wrong")).Code == 409, "poll accepted wrong token");
            var denied = await Post(new { mode = "write", description = "legacy", code = "return 1;", target });
            Check(denied.Code == 429, "tokenless execute bypassed task");
            using (var selection = await client.GetAsync("/v1/selection"))
                Check((int)selection.StatusCode == 429, "tokenless selection bypassed task");
            var accepted = await Post(new { mode = "write", description = "owner step", code = "return 1;", target, taskId = id, taskToken = token });
            Check(accepted.Code == 202, "owner execute refused");
            string requestId = accepted.Body.GetProperty("requestId").GetString()!;
            using (var result = JsonDocument.Parse(await client.GetStringAsync("/v1/requests/" + requestId)))
                Check(result.RootElement.GetProperty("status").GetString() == "succeeded", "owner request did not complete");
            var ownedSelection = await Post(new { mode = "read", operation = "selection.read", target, taskId = id, taskToken = token });
            Check(ownedSelection.Code == 202 && executor.LastKind == ConnectorRequestKind.Selection, "owned structured selection refused or dispatched as code");
            Check((await Post(new { mode = "write", operation = "selection.read", target, taskId = id, taskToken = token })).Code == 400,
                "structured selection accepted write intent");
            executor.Title = "DifferentDocument";
            Check((await Control("renew", id, token)).Code == 409, "task control missed document drift");
            var drift = await Post(new { mode = "write", description = "drift", code = "return 1;", target, taskId = id, taskToken = token });
            Check(drift.Code == 202, "drift request not queued for UI-thread validation");
            using (var result = JsonDocument.Parse(await client.GetStringAsync("/v1/requests/" + drift.Body.GetProperty("requestId").GetString())))
                Check(result.RootElement.GetProperty("status").GetString() == "rejected", "host did not reject document drift");
            executor.Title = "DisposableTaskTest";
            executor.Delay = true;
            var slow = await Post(new { mode = "write", description = "slow", code = "return 1;", timeoutSeconds = 1, target, taskId = id, taskToken = token });
            Check(slow.Code == 202, "slow request refused");
            await Task.Delay(1200);
            Check((await Control("release", id, token)).Code == 409, "timeout released running native operation");
            using (var cancel = await client.PostAsync("/v1/requests/" + slow.Body.GetProperty("requestId").GetString() + "/cancel", new StringContent("")))
                Check((int)cancel.StatusCode == 409, "running request incorrectly cancelled");
            Check((await Control("cancel", id, token)).Body.GetProperty("status").GetString() == "draining", "HTTP cancel did not drain");
            executor.Title = "OtherModel";
            var next = await Control("submit", requestTarget: new { target.application, target.release, target.apiVariant,
                target.instanceId, target.processId, document = new { id = "task-doc", title = "OtherModel" } }, owner: "other-agent");
            string nextId = next.Body.GetProperty("task").GetProperty("taskId").GetString()!;
            string nextToken = next.Body.GetProperty("token").GetString()!;
            Check(next.Body.GetProperty("task").GetProperty("status").GetString() == "queued", "HTTP handed off running operation");
            executor.Title = null;
            var instanceOnly = new { target.application, target.release, target.apiVariant, target.instanceId, target.processId };
            var board = await Control("status", requestTarget: instanceOnly);
            Check(board.Code == 200 && board.Body.GetProperty("currentTaskId").GetString() == id, "board lost draining holder with no document open");
            var rows = board.Body.GetProperty("tasks").EnumerateArray().ToDictionary(row => row.GetProperty("taskId").GetString()!);
            Check(rows[id].GetProperty("documentTitle").GetString() == "DisposableTaskTest", "board replaced the submission model title");
            Check(rows[nextId].GetProperty("documentTitle").GetString() == "OtherModel" &&
                rows[nextId].GetProperty("owner").GetString() == "other-agent" &&
                rows[nextId].GetProperty("queuePosition").GetInt32() == 1, "board missed the queued applicant, model or position");
            string boardJson = board.Body.GetRawText();
            Check(!boardJson.Contains(token) && !boardJson.Contains(nextToken) && !boardJson.Contains("C:/private"), "board exposed credentials or model path");
            Check((await Control("submit", requestTarget: instanceOnly)).Code == 409, "document-free board relaxed submission targeting");
            executor.Title = "DisposableTaskTest";
            Done(executor.Pending!);
            Check((await Control("status", requestTarget: instanceOnly)).Body.GetProperty("currentTaskId").GetString() == nextId,
                "board missed ownership handoff");
            Check((await Control("poll", nextId, nextToken)).Body.GetProperty("status").GetString() == "active", "HTTP drain never completed");
            Check((await Post(new { mode = "write", description = "stale", code = "return 1;", target, taskId = id, taskToken = token })).Code == 429,
                "stale token accepted after ownership transfer");
            Check((await Control("release", nextId, nextToken)).Code == 200, "HTTP release failed");
            Check((await Control("status", requestTarget: instanceOnly)).Body.GetProperty("currentTaskId").ValueKind == JsonValueKind.Null,
                "board reported a holder after the queue drained");
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static ConnectorRequest Request() => new ConnectorRequest(ConnectorRequestKind.Execute, "write", "test", "", 60);
    private static void Done(ConnectorRequest request) => request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Succeeded });

    public static Task Run()
    {
        // Start/cancel must be one atomic decision: cancelled code never runs.
        for (int trial = 0; trial < 1000; trial++)
        {
            using var race = Request();
            bool started = false, raceCancelled = false;
            Parallel.Invoke(() => started = race.TryStart(), () => raceCancelled = race.TryCancel("race"));
            Check(started != raceCancelled, "TryStart/TryCancel race did not choose exactly one winner");
            if (started)
            {
                Check(!race.TryCancel("running"), "running request cancelled");
                Done(race);
            }
            else Check(race.Snapshot().Status == "cancelled", "cancelled winner was overwritten");
            Check(!race.TryStart(), "terminal request restarted");
        }
        double now = 0;
        var coordinator = new TaskCoordinator(() => now);
        var tasks = Enumerable.Range(0, 15).Select(i => coordinator.Submit("family" + i, "agent" + i, 120)).ToArray();
        Check(tasks[0].Task.Status == "active", "first task not active");
        for (int i = 0; i < tasks.Length; i++)
        {
            var task = tasks[i];
            Check(coordinator.Poll(task.Task.TaskId, task.Token).Status == "active", "FIFO order violated");
            using var first = Request(); using var second = Request();
            Check(!coordinator.TryAdmit(first, null, null, out _), "legacy bypassed active task");
            Check(!coordinator.TryAdmit(first, task.Task.TaskId, "incorrect", out _), "invalid token accepted");
            Check(coordinator.TryAdmit(first, task.Task.TaskId, task.Token, out _), "owner step refused");
            Check(!coordinator.TryAdmit(second, task.Task.TaskId, task.Token, out _), "same owner interleaved requests");
            bool refused = false;
            try { coordinator.Release(task.Task.TaskId, task.Token); } catch (InvalidOperationException) { refused = true; }
            Check(refused, "released an in-flight request");
            Done(first);
            Check(coordinator.TryAdmit(second, task.Task.TaskId, task.Token, out _), "second sequential step refused");
            Done(second);
            Check(coordinator.Release(task.Task.TaskId, task.Token).Status == "completed", "release failed");
        }

        var active = coordinator.Submit("slow", "agent", 10);
        var waiting = coordinator.Submit("next", "agent", 120);
        using var slow = Request();
        Check(coordinator.TryAdmit(slow, active.Task.TaskId, active.Token, out _), "slow request refused");
        Check(slow.TryStart(), "slow request did not start");
        now = 11;
        Check(coordinator.Poll(active.Task.TaskId, active.Token).Status == "draining", "expiry did not drain");
        Check(coordinator.Poll(waiting.Task.TaskId, waiting.Token).Status == "queued", "handed off possibly running mutation");
        using var blocked = Request();
        Check(!coordinator.TryAdmit(blocked, active.Task.TaskId, active.Token, out _), "expired owner admitted new step");
        bool renewRefused = false;
        try { coordinator.Renew(active.Task.TaskId, active.Token); } catch (InvalidOperationException) { renewRefused = true; }
        Check(renewRefused, "draining task resurrected");
        Done(slow);
        Check(coordinator.Poll(waiting.Task.TaskId, waiting.Token).Status == "active", "did not hand off completed expired request");
        Check(coordinator.Poll(active.Task.TaskId, active.Token).Status == "expired", "expiry outcome lost");
        Check(!coordinator.TryAdmit(blocked, active.Task.TaskId, active.Token, out _), "expired token admitted after handoff");
        coordinator.Cancel(waiting.Task.TaskId, waiting.Token);

        using var legacy = Request();
        Check(coordinator.TryAdmit(legacy, null, null, out _), "idle legacy request refused");
        var afterLegacy = coordinator.Submit("afterLegacy", "agent", 120);
        Check(afterLegacy.Task.Status == "queued", "task overlapped legacy request");
        Done(legacy);
        Check(coordinator.Poll(afterLegacy.Task.TaskId, afterLegacy.Token).Status == "active", "legacy completion did not unblock task");
        using var running = Request();
        Check(coordinator.TryAdmit(running, afterLegacy.Task.TaskId, afterLegacy.Token, out _), "cancellation test admission failed");
        Check(running.TryStart(), "cancellation test request did not start");
        var successor = coordinator.Submit("successor", "agent", 120);
        Check(coordinator.Cancel(afterLegacy.Task.TaskId, afterLegacy.Token).Status == "draining", "cancel skipped drain");
        Check(coordinator.Poll(successor.Task.TaskId, successor.Token).Status == "queued", "cancel handed off running request");
        Done(running);
        Check(coordinator.Poll(successor.Task.TaskId, successor.Token).Status == "active", "cancel completion did not unblock");
        coordinator.Release(successor.Task.TaskId, successor.Token);

        foreach (bool expiry in new[] { false, true })
        {
            double pendingNow = 0;
            var pendingCoordinator = new TaskCoordinator(() => pendingNow);
            var pendingHolder = pendingCoordinator.Submit("waiting-native", "agent", 10);
            var pendingSuccessor = pendingCoordinator.Submit("successor", "agent", 120);
            using var pendingNative = Request();
            Check(pendingCoordinator.TryAdmit(pendingNative, pendingHolder.Task.TaskId, pendingHolder.Token, out _), "waiting-native request refused");
            pendingNative.SetStatus(ConnectorRequestStatus.WaitingForApplication);
            if (expiry) pendingNow = 11;
            else Check(pendingCoordinator.Cancel(pendingHolder.Task.TaskId, pendingHolder.Token).Status == "cancelled", "waiting-native cancellation did not finish");
            Check(pendingCoordinator.Poll(pendingSuccessor.Task.TaskId, pendingSuccessor.Token).Status == "active", "waiting-native cancellation/expiry blocked successor");
            Check(pendingNative.Snapshot().Status == "cancelled", "waiting-native step was not cancelled");
            Check(!pendingNative.TryStart(), "cancelled waiting-native step executed after handoff");
        }

        var independent = new TaskCoordinator(() => now);
        var independentTask = independent.Submit("independent", "agent", 120);
        Check(independentTask.Task.Status == "active", "independent instance blocked");
        var capacity = new TaskCoordinator(() => now, 2);
        capacity.Submit("one", "agent"); capacity.Submit("two", "agent");
        bool full = false;
        try { capacity.Submit("three", "agent"); } catch (InvalidOperationException) { full = true; }
        Check(full, "queue capacity bypassed");

        var queuedCancel = capacity.Status().Single(t => t.Status == "queued");
        var cancellation = new TaskCoordinator(() => now);
        var head = cancellation.Submit("head", "agent", 120);
        var cancelled = cancellation.Submit("cancel", "agent", 120);
        var tail = cancellation.Submit("tail", "agent", 120);
        Check(cancellation.Cancel(cancelled.Task.TaskId, cancelled.Token).Status == "cancelled", "queued cancellation failed");
        cancellation.Release(head.Task.TaskId, head.Token);
        Check(cancellation.Poll(tail.Task.TaskId, tail.Token).Status == "active", "cancelled queue entry blocked successor");
        cancellation.Renew(tail.Task.TaskId, tail.Token, 20);
        now += 19;
        Check(cancellation.Poll(tail.Task.TaskId, tail.Token).Status == "active", "lease renew did not extend");
        now += 2;
        Check(cancellation.Poll(tail.Task.TaskId, tail.Token).Status == "expired", "idle expired task hung");

        // Simultaneous callers must never own the same instance.
        var concurrent = new TaskCoordinator();
        var submissions = new System.Collections.Concurrent.ConcurrentBag<TaskSubmission>();
        Parallel.For(0, 15, i => submissions.Add(concurrent.Submit("concurrent" + i, "agent" + i)));
        Check(concurrent.Status().Count(t => t.Status == "active") == 1, "concurrent acquisition granted multiple owners");
        Check(concurrent.Status().Count(t => t.Status == "queued") == 14, "concurrent submission lost tasks");
        var holder = submissions.Single(s => s.Task.Status == "active");
        int admitted = 0;
        var requests = Enumerable.Range(0, 15).Select(_ => Request()).ToArray();
        Parallel.ForEach(requests, request =>
        {
            if (concurrent.TryAdmit(request, holder.Task.TaskId, holder.Token, out _))
                Interlocked.Increment(ref admitted);
        });
        Check(admitted == 1, "simultaneous steps admitted more than one request");
        foreach (var request in requests) { Done(request); request.Dispose(); }

        // Retained terminal states are bounded, including under repeated expiry.
        var bounded = new TaskCoordinator(() => now);
        for (int i = 0; i < 150; i++)
        {
            var item = bounded.Submit("history", "agent");
            bounded.Release(item.Task.TaskId, item.Token);
        }
        Check(bounded.Status().Length == 128, "terminal history grew without bound");
        return Task.CompletedTask;
    }
}
