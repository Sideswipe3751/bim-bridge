using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using BimBridge.Host;

var tests = new List<(string Name, Func<Task> Run)>
{
    ("family path containment and lifecycle timing", FamilySessionTests.Run),
    ("exclusive task coordinator FIFO, expiry and races", TaskCoordinatorTests.Run),
    ("task control HTTP enforcement", TaskCoordinatorTests.RunHttp),
    ("authenticated bridge and descriptor lifecycle", TestBridge),
    ("descriptor refresh tolerates a locked reader", TestDescriptorRefreshWhileLocked),
    ("request status is terminal once completed", TestTerminalStatus),
    ("execution target guard rejects document drift", TestTargetGuard),
    ("non-loopback bind is rejected", TestLoopbackOnly)
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        await test.Run();
        Console.WriteLine("PASS " + test.Name);
    }
    catch (Exception ex)
    {
        failures.Add(test.Name + ": " + ex.Message);
        Console.WriteLine("FAIL " + test.Name + ": " + ex);
    }
}

static Task TestDescriptorRefreshWhileLocked()
{
    var directory = Path.Combine(Path.GetTempPath(), "bim-bridge-host-tests", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    try
    {
        var executor = new FakeExecutor();
        using var server = new ConnectorServer(executor, new ConnectorOptions
        {
            Port = GetFreePort(),
            PortFallbackCount = 2,
            InstanceDirectory = directory
        });
        server.Start();
        var descriptorPath = Directory.GetFiles(directory, "*.json").Single();

        executor.DocumentTitle = "Updated while locked";
        using (var reader = new FileStream(descriptorPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            server.RefreshDescriptor();
        }

        server.RefreshDescriptor();
        using var descriptor = JsonDocument.Parse(File.ReadAllText(descriptorPath));
        Assert(
            descriptor.RootElement.GetProperty("document").GetProperty("title").GetString() == executor.DocumentTitle,
            "descriptor did not recover after the reader released its lock");
    }
    finally
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }
    return Task.CompletedTask;
}
if (failures.Count > 0) throw new Exception(string.Join(Environment.NewLine, failures));

static async Task TestBridge()
{
    var directory = Path.Combine(Path.GetTempPath(), "bim-bridge-host-tests", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    try
    {
        var executor = new FakeExecutor();
        using var server = new ConnectorServer(executor, new ConnectorOptions
        {
            Port = GetFreePort(),
            PortFallbackCount = 2,
            InstanceDirectory = directory
        });
        server.Start();
        var descriptorPath = Directory.GetFiles(directory, "*.json").Single();
        using var descriptor = JsonDocument.Parse(File.ReadAllText(descriptorPath));
        var token = descriptor.RootElement.GetProperty("token").GetString()!;
        Assert(descriptor.RootElement.GetProperty("url").GetString() == $"http://127.0.0.1:{server.Port}", "descriptor URL mismatch");

        using var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{server.Port}") };
        var denied = await client.GetAsync("/v1/info");
        Assert(denied.StatusCode == HttpStatusCode.Unauthorized, "missing token was accepted");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var info = await client.GetStringAsync("/v1/info");
        Assert(info.Contains("revit"), "info did not identify Revit");
        var selection = await client.GetStringAsync("/v1/selection");
        Assert(selection.Contains("42"), "selection result missing");

        var body = new StringContent(
            "{\"mode\":\"read\",\"description\":\"Read title\",\"code\":\"return doc.Title;\",\"timeoutSeconds\":5}",
            Encoding.UTF8,
            "application/json");
        var createdResponse = await client.PostAsync("/v1/execute", body);
        Assert(createdResponse.StatusCode == HttpStatusCode.Accepted, "execute was not accepted");
        using var created = JsonDocument.Parse(await createdResponse.Content.ReadAsStringAsync());
        var id = created.RootElement.GetProperty("requestId").GetString();
        var result = await client.GetStringAsync("/v1/requests/" + id);
        Assert(result.Contains("succeeded"), "request did not succeed");

        var captureBody = new StringContent(
            "{\"mode\":\"read\",\"operation\":\"view.capture\",\"description\":\"Capture view\",\"viewCapture\":{\"viewName\":\"{3D}\",\"pixelSize\":1200,\"dpi\":150},\"timeoutSeconds\":5}",
            Encoding.UTF8,
            "application/json");
        var captureResponse = await client.PostAsync("/v1/execute", captureBody);
        Assert(captureResponse.StatusCode == HttpStatusCode.Accepted, "view.capture was not accepted");
        Assert(executor.LastOperation == "view.capture", "view.capture operation was not preserved");
        Assert(executor.LastViewCapture?.ViewName == "{3D}", "view selector was not preserved");
        Assert(executor.LastViewCapture?.PixelSize == 1200, "capture pixel size was not preserved");
        server.Dispose();
        Assert(!File.Exists(descriptorPath), "descriptor survived clean shutdown");
    }
    finally
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }
}

static Task TestTerminalStatus()
{
    using var request = new ConnectorRequest(ConnectorRequestKind.Execute, "read", "test", "return 1;", 5);
    request.SetStatus(ConnectorRequestStatus.Running);
    request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Succeeded, Result = 1 });
    request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Failed, Message = "late" });
    Assert(request.Snapshot().Status == "succeeded", "terminal result changed");
    return Task.CompletedTask;
}

static Task TestTargetGuard()
{
    var actual = new ConnectorInfo
    {
        InstanceId = "revit-2027-1234",
        Application = "revit",
        ApplicationVersion = "2027",
        ProcessId = 1234,
        Document = new DocumentDescriptor { Id = "doc-1", Title = "Model A" }
    };
    var expected = new ConnectorExecutionTarget
    {
        InstanceId = actual.InstanceId,
        Application = actual.Application,
        Release = actual.ApplicationVersion,
        ProcessId = actual.ProcessId,
        Document = new DocumentDescriptor { Id = "doc-1", Title = "Model A" }
    };
    Assert(ConnectorTargetGuard.Validate(expected, actual) == null, "exact target was rejected");
    actual.Document = new DocumentDescriptor { Id = "doc-2", Title = "Model B" };
    Assert(ConnectorTargetGuard.Validate(expected, actual) == "document_changed", "document drift was accepted");
    return Task.CompletedTask;
}

static Task TestLoopbackOnly()
{
    using var server = new ConnectorServer(new FakeExecutor(), new ConnectorOptions { BindHost = "0.0.0.0" });
    try
    {
        server.Start();
        throw new Exception("non-loopback server started");
    }
    catch (InvalidOperationException)
    {
        return Task.CompletedTask;
    }
}

static int GetFreePort()
{
    var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    listener.Stop();
    return port;
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

sealed class FakeExecutor : IConnectorExecutor
{
    public string DocumentTitle { get; set; } = "Test";
    public string? LastOperation { get; private set; }
    public ConnectorViewCaptureOptions? LastViewCapture { get; private set; }

    public ConnectorInfo GetCachedInfo() => new ConnectorInfo
    {
        InstanceId = "revit-2024-" + Process.GetCurrentProcess().Id,
        Application = "revit",
        ApplicationVersion = "2024",
        ProcessId = Process.GetCurrentProcess().Id,
        Document = new DocumentDescriptor { Id = "doc-1", Title = DocumentTitle },
        Capabilities = new List<string> { "document.info", "selection.read", "view.capture", "code.read", "code.write" }
    };

    public void Submit(ConnectorRequest request)
    {
        LastOperation = request.Operation;
        LastViewCapture = request.ViewCapture;
        request.SetStatus(ConnectorRequestStatus.Running);
        request.Complete(new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Succeeded,
            Result = request.Kind == ConnectorRequestKind.Selection ? new { ids = new[] { 42 } } : new { ok = true }
        });
    }
}
