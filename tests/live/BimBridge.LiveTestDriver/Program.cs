using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BimBridge.LiveTestDriver;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static async Task<int> Main(string[] args)
    {
        var options = DriverOptions.Parse(args);
        ValidatePathBoundary(options);
        Directory.CreateDirectory(options.RunDirectory);
        var reportPath = Path.Combine(options.RunDirectory, "report.json");
        var report = new LiveReport
        {
            RunId = options.RunId,
            RevitVersion = options.Version,
            RuntimeFamily = options.RuntimeFamily,
            StartedAtUtc = DateTime.UtcNow.ToString("o"),
            RunDirectory = options.RunDirectory,
            RevitExecutable = options.RevitExecutable,
            TemplatePath = options.TemplatePath,
            AdapterAssembly = options.AdapterAssembly,
            BootstrapAssembly = options.BootstrapAssembly
        };

        Process? revit = null;
        McpClient? mcp = null;
        try
        {
            ValidateInputs(options);
            AddCheck(report, "preflight", true, "All live-test inputs passed safety validation.");

            var requestPath = Path.Combine(options.RunDirectory, "request.json");
            var documentPath = Path.Combine(options.RunDirectory, $"BIM-Bridge-Live-{options.Version}-{options.RunId}.rvt");
            WriteJsonAtomic(requestPath, new
            {
                schemaVersion = 1,
                runId = options.RunId,
                token = options.Token,
                version = options.Version,
                certificationRoot = options.CertificationRoot,
                runDirectory = options.RunDirectory,
                templatePath = options.TemplatePath,
                documentPath
            });

            mcp = new McpClient(options.PythonExecutable, options.McpServer);
            await mcp.StartAsync(options.Timeout);
            var providers = await mcp.CallToolAsync("aec_list_providers", new { probe = true }, false, options.Timeout);
            AddCheck(report, "provider_probe", true, "Structured providers were probed before connector fallback.", providers);

            revit = StartRevit(options, requestPath);
            report.ProcessId = revit.Id;
            await WriteReportAsync(reportPath, report);

            var ready = await WaitForBootstrapAsync(options, revit);
            report.RevitBuild = ready.GetProperty("versionBuild").GetString();
            report.DocumentTitle = ready.GetProperty("documentTitle").GetString();
            report.DocumentPath = ready.GetProperty("documentPath").GetString();
            Require(ready.GetProperty("token").GetString() == options.Token, "Bootstrap token mismatch.");
            Require(ready.GetProperty("version").GetString() == options.Version, "Bootstrap version mismatch.");
            Require(ready.GetProperty("processId").GetInt32() == revit.Id, "Bootstrap process ID mismatch.");
            Require(PathsEqual(report.DocumentPath, documentPath), "Bootstrap activated an unexpected document.");
            AddCheck(report, "bootstrap", true, "Disposable project was created and activated by the exact Revit process.", ready);

            var instance = await WaitForInstanceAsync(mcp, options, revit.Id);
            var instanceId = instance.GetProperty("instanceId").GetString()
                ?? throw new InvalidOperationException("Connector instance ID is missing.");
            report.InstanceId = instanceId;
            AddCheck(report, "connector_discovery", true, "The test Revit connector was discovered through MCP.", instance);

            var target = new Dictionary<string, object?>
            {
                ["instanceId"] = instanceId,
                ["application"] = "revit",
                ["applicationVersion"] = options.Version,
                ["documentTitle"] = report.DocumentTitle
            };

            var info = await mcp.CallToolAsync("aec_get_document_info", target, false, options.Timeout);
            Require(info.GetProperty("application").GetString() == "revit", "Connector routed to the wrong application.");
            Require(info.GetProperty("applicationVersion").GetString() == options.Version, "Connector routed to the wrong Revit version.");
            Require(info.GetProperty("processId").GetInt32() == revit.Id, "Connector routed to the wrong process.");
            Require(PathsEqual(info.GetProperty("document").GetProperty("path").GetString(), documentPath), "Connector routed to the wrong document.");
            AddCheck(report, "exact_routing", true, "Application, version, process, and document routing all matched.", info);

            var selection = await mcp.CallToolAsync("aec_get_selection", target, false, options.Timeout);
            Require(selection.GetProperty("count").GetInt32() == 0, "New disposable project should have an empty selection.");
            AddCheck(report, "selection", true, "Selection endpoint returned the expected empty selection.", selection);

            var read = await ExecuteAsync(mcp, "aec_execute_read", target,
                "Read live test document identity",
                "return new { version = uiApp.Application.VersionNumber, title = doc.Title, path = doc.PathName, isModifiable = doc.IsModifiable };",
                false, options.Timeout);
            Require(read.GetProperty("status").GetString() == "succeeded", "Document read did not succeed.");
            var readResult = read.GetProperty("result");
            Require(readResult.GetProperty("version").GetString() == options.Version, "Read executed in the wrong Revit version.");
            Require(PathsEqual(readResult.GetProperty("path").GetString(), documentPath), "Read executed against the wrong document.");
            AddCheck(report, "read", true, "Fallback read executed in Revit's supported API context.", read);

            var captureSchema = await mcp.CallToolAsync(
                "aec_get_provider_tool_schema",
                new { provider = "revit.connector.v1", toolName = "capture_view" },
                false,
                options.Timeout);
            Require(captureSchema.GetProperty("access").GetString() == "read", "View capture was not classified read-only.");
            var capture = await mcp.CallToolAsync(
                "aec_call_provider_read",
                new
                {
                    provider = "revit.connector.v1",
                    toolName = "capture_view",
                    arguments = new
                    {
                        instanceId,
                        fileStem = "live-acceptance-" + options.Version,
                        pixelSize = 1200,
                        dpi = 150
                    }
                },
                false,
                options.Timeout);
            Require(capture.GetProperty("status").GetString() == "succeeded", "Structured view capture did not succeed.");
            var capturePath = capture.GetProperty("result").GetProperty("result").GetProperty("path").GetString();
            Require(!string.IsNullOrWhiteSpace(capturePath) && File.Exists(capturePath), "Structured view capture did not create a PNG.");
            Require(string.Equals(Path.GetExtension(capturePath), ".png", StringComparison.OrdinalIgnoreCase), "Structured view capture did not return PNG output.");
            AddCheck(report, "view_capture", true, "The built-in structured capture capability exported the active Revit view.", capture);

            await VerifyLayeredPdfAsync(mcp, target, report, options);

            var successMarker = "BIM_BRIDGE_LIVE_SUCCESS_" + options.RunId;
            var write = await ExecuteAsync(mcp, "aec_execute_write", target,
                "Create disposable certification marker",
                $"var element = DirectShape.CreateElement(doc, new ElementId(BuiltInCategory.OST_GenericModel)); element.ApplicationId = \"{successMarker}\"; element.ApplicationDataId = \"{successMarker}\"; return new {{ id = element.Id.Value, uniqueId = element.UniqueId, marker = element.ApplicationId }};",
                false, options.Timeout);
            Require(write.GetProperty("status").GetString() == "succeeded", "Representative write did not succeed.");
            Require(!write.GetProperty("rolledBack").GetBoolean(), "Successful write was unexpectedly rolled back.");
            AddCheck(report, "write", true, "Representative DirectShape write committed.", write);

            var readBack = await ExecuteAsync(mcp, "aec_execute_read", target,
                "Read back disposable certification marker",
                $"return new FilteredElementCollector(doc).OfClass(typeof(DirectShape)).Cast<DirectShape>().Where(e => e.ApplicationId == \"{successMarker}\").Select(e => new {{ id = e.Id.Value, uniqueId = e.UniqueId, marker = e.ApplicationId }}).ToList();",
                false, options.Timeout);
            Require(readBack.GetProperty("status").GetString() == "succeeded", "Write read-back did not succeed.");
            Require(readBack.GetProperty("result").GetArrayLength() == 1, "Committed marker was not found exactly once.");
            AddCheck(report, "write_readback", true, "Committed marker was found exactly once.", readBack);

            var rollbackMarker = "BIM_BRIDGE_LIVE_ROLLBACK_" + options.RunId;
            var rollback = await ExecuteAsync(mcp, "aec_execute_write", target,
                "Verify complete rollback after intentional failure",
                $"var element = DirectShape.CreateElement(doc, new ElementId(BuiltInCategory.OST_GenericModel)); element.ApplicationId = \"{rollbackMarker}\"; element.ApplicationDataId = \"{rollbackMarker}\"; throw new InvalidOperationException(\"BIM_BRIDGE_EXPECTED_ROLLBACK\");",
                true, options.Timeout);
            Require(rollback.GetProperty("status").GetString() == "failed", "Intentional write failure did not report failed status.");
            Require(rollback.GetProperty("rolledBack").GetBoolean(), "Intentional write failure did not report rollback.");
            AddCheck(report, "rollback_signal", true, "Intentional failure returned failed with rolledBack=true.", rollback);

            var rollbackReadBack = await ExecuteAsync(mcp, "aec_execute_read", target,
                "Verify intentional failure left no marker",
                $"return new {{ successCount = new FilteredElementCollector(doc).OfClass(typeof(DirectShape)).Cast<DirectShape>().Count(e => e.ApplicationId == \"{successMarker}\"), rollbackCount = new FilteredElementCollector(doc).OfClass(typeof(DirectShape)).Cast<DirectShape>().Count(e => e.ApplicationId == \"{rollbackMarker}\") }};",
                false, options.Timeout);
            var rollbackResult = rollbackReadBack.GetProperty("result");
            Require(rollbackResult.GetProperty("successCount").GetInt32() == 1, "Rollback damaged the previously committed marker.");
            Require(rollbackResult.GetProperty("rollbackCount").GetInt32() == 0, "Intentional failure left model changes behind.");
            AddCheck(report, "rollback_readback", true, "Failed write left no changes and preserved the earlier commit.", rollbackReadBack);

            var dependency = await ExecuteAsync(mcp, "aec_execute_read", target,
                "Inspect live adapter dependency locations",
                "return AppDomain.CurrentDomain.GetAssemblies().Where(a => a.GetName().Name.StartsWith(\"BimBridge\") || a.GetName().Name.StartsWith(\"Microsoft.CodeAnalysis\")).Select(a => new { name = a.GetName().Name, version = a.GetName().Version.ToString(), location = string.IsNullOrEmpty(a.Location) ? null : a.Location }).OrderBy(a => a.name).ToList();",
                false, options.Timeout);
            Require(dependency.GetProperty("status").GetString() == "succeeded", "Dependency inspection failed.");
            VerifyDependencies(dependency.GetProperty("result"), options);
            AddCheck(report, "dependency_isolation", true, "Adapter and compiler dependencies resolved from the expected test artifacts.", dependency);

            var cleanup = await ExecuteAsync(mcp, "aec_execute_write", target,
                "Delete disposable certification marker",
                $"var elements = new FilteredElementCollector(doc).OfClass(typeof(DirectShape)).Cast<DirectShape>().Where(e => e.ApplicationId == \"{successMarker}\").ToList(); foreach (var element in elements) doc.Delete(element.Id); return new {{ deleted = elements.Count }};",
                false, options.Timeout);
            Require(cleanup.GetProperty("status").GetString() == "succeeded", "Test marker cleanup failed.");
            Require(cleanup.GetProperty("result").GetProperty("deleted").GetInt32() == 1, "Cleanup did not delete exactly one marker.");
            AddCheck(report, "cleanup", true, "Disposable marker was deleted.", cleanup);

            WriteJsonAtomic(Path.Combine(options.RunDirectory, "finish.json"), new { token = options.Token });
            await WaitForExitAsync(revit, options.Timeout);
            Require(File.Exists(Path.Combine(options.RunDirectory, "stopped.json")), "Bootstrap shutdown evidence is missing.");
            AddCheck(report, "clean_shutdown", true, "Revit saved the disposable model and shut down cleanly.");

            var after = await mcp.CallToolAsync("aec_list_instances", new { application = "revit", applicationVersion = options.Version }, false, options.Timeout);
            var remains = after.GetProperty("instances").EnumerateArray().Any(item => item.GetProperty("instanceId").GetString() == instanceId);
            Require(!remains, "Connector descriptor remained after Revit shutdown.");
            AddCheck(report, "descriptor_cleanup", true, "Connector descriptor was removed during shutdown.", after);

            report.Status = "passed";
            return 0;
        }
        catch (Exception exception)
        {
            report.Status = "failed";
            report.FailureCode = ClassifyFailure(exception);
            report.FailureMessage = exception.Message;
            AddCheck(report, "failure", false, exception.Message);
            return 2;
        }
        finally
        {
            if (revit is { HasExited: false })
            {
                try
                {
                    WriteJsonAtomic(Path.Combine(options.RunDirectory, "finish.json"), new { token = options.Token });
                    await WaitForExitAsync(revit, TimeSpan.FromSeconds(30));
                }
                catch
                {
                    try { revit.Kill(true); report.ForcedProcessTermination = true; } catch { }
                }
            }
            if (mcp != null) await mcp.DisposeAsync();
            report.EndedAtUtc = DateTime.UtcNow.ToString("o");
            await WriteReportAsync(reportPath, report);
        }
    }

    private static Process StartRevit(DriverOptions options, string requestPath)
    {
        var start = new ProcessStartInfo(options.RevitExecutable)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(options.RevitExecutable)!,
            Arguments = "/nosplash"
        };
        start.Environment["BIM_BRIDGE_REVIT_LIVE_TEST_REQUEST"] = requestPath;
        return Process.Start(start) ?? throw new InvalidOperationException("Unable to start Revit.");
    }

    private static async Task<JsonElement> WaitForBootstrapAsync(DriverOptions options, Process revit)
    {
        var readyPath = Path.Combine(options.RunDirectory, "ready.json");
        var failedPath = Path.Combine(options.RunDirectory, "failed.json");
        var deadline = DateTime.UtcNow + options.Timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(failedPath))
                throw new InvalidOperationException("Revit bootstrap failed: " + await File.ReadAllTextAsync(failedPath));
            if (File.Exists(readyPath)) return JsonDocument.Parse(await File.ReadAllTextAsync(readyPath)).RootElement.Clone();
            if (revit.HasExited) throw new InvalidOperationException($"Revit exited before bootstrap readiness (exit code {revit.ExitCode}).");
            await Task.Delay(500);
        }
        throw new TimeoutException("Timed out waiting for Revit bootstrap readiness. Inspect the Revit journal to determine whether the manifest was discovered and the add-in started.");
    }

    private static async Task<JsonElement> WaitForInstanceAsync(McpClient mcp, DriverOptions options, int processId)
    {
        var deadline = DateTime.UtcNow + options.Timeout;
        while (DateTime.UtcNow < deadline)
        {
            var listed = await mcp.CallToolAsync("aec_list_instances", new { application = "revit", applicationVersion = options.Version }, false, options.Timeout);
            foreach (var instance in listed.GetProperty("instances").EnumerateArray())
                if (instance.GetProperty("processId").GetInt32() == processId) return instance.Clone();
            await Task.Delay(500);
        }
        throw new TimeoutException("Timed out waiting for the exact Revit connector instance.");
    }

    private static async Task VerifyLayeredPdfAsync(McpClient mcp, Dictionary<string, object?> target,
        LiveReport report, DriverOptions options)
    {
        var fixture = await ExecuteAsync(mcp, "aec_execute_write", target, "Create disposable layered PDF sheets",
            "var type = new FilteredElementCollector(doc).OfClass(typeof(ViewFamilyType)).Cast<ViewFamilyType>().First(v => v.ViewFamily == ViewFamily.Drafting); " +
            "var titleBlock = new FilteredElementCollector(doc).OfCategory(BuiltInCategory.OST_TitleBlocks).WhereElementIsElementType().FirstOrDefault(); " +
            "var sheets = new List<long>(); var views = new List<long>(); var viewports = new List<long>(); " +
            "for (int i=0; i<2; i++) { var view = ViewDrafting.Create(doc,type.Id); view.Name=\"BIM Bridge PDF test \"+i; view.Scale=1; " +
            "doc.Create.NewDetailCurve(view, Line.CreateBound(new XYZ(0,0,0),new XYZ(1,i==0?0:1,0))); " +
            "var sheet=ViewSheet.Create(doc,titleBlock==null?ElementId.InvalidElementId:titleBlock.Id); sheet.SheetNumber=\"BB-PDF-\"+i; " +
            "doc.Regenerate(); var o=sheet.Outline; var vp=Viewport.Create(doc,sheet.Id,view.Id,new XYZ((o.Min.U+o.Max.U)/2,(o.Min.V+o.Max.V)/2,0)); " +
            "sheets.Add(sheet.Id.Value); views.Add(view.Id.Value); viewports.Add(vp.Id.Value); } return new { sheets, views, viewports };",
            false, options.Timeout);
        Require(fixture.GetProperty("status").GetString()=="succeeded", "PDF fixture creation failed");
        var ids=fixture.GetProperty("result").GetProperty("sheets").EnumerateArray().Select(x=>x.GetInt64()).ToArray();
        var catalog = await mcp.CallToolAsync("aec_call_provider_read", new { provider="bimbridge.layered_pdf.v1",
            toolName="list_layered_pdf_sheets", arguments=new { instanceId=target["instanceId"], documentTitle=target["documentTitle"] } }, false, options.Timeout);
        Require(catalog.GetProperty("status").GetString()=="succeeded", "Layered PDF catalog failed");
        AddCheck(report,"layered_pdf_catalog",true,"Printable fixture sheets and PDF presets discovered through MCP.",catalog);
        var exportArgs=new { instanceId=target["instanceId"], documentTitle=target["documentTitle"], baseSheetId=ids[0], sheetIds=ids, fileStem="live-layered-pdf" };
        var preview=await mcp.CallToolAsync("aec_call_provider_write",new {provider="bimbridge.layered_pdf.v1",toolName="export_layered_pdf", arguments=exportArgs,dryRun=true,timeoutSeconds=300},false,options.Timeout);
        Require(preview.GetProperty("status").GetString()=="previewed","Layered PDF preview failed");
        var export=await mcp.CallToolAsync("aec_call_provider_write",new {provider="bimbridge.layered_pdf.v1",toolName="export_layered_pdf",arguments=exportArgs,dryRun=false,timeoutSeconds=300},false,options.Timeout);
        Require(export.GetProperty("status").GetString()=="succeeded","Layered PDF export failed: "+export);
        var output=export.GetProperty("result").GetProperty("result");
        Require(output.GetProperty("modelRestored").GetBoolean(),"Layered PDF did not restore model");
        Require(output.GetProperty("viewportLayerCount").GetInt32()==2 && output.GetProperty("pageCount").GetInt32()==1,"PDF output has wrong page/layer counts");
        var pdfPath=output.GetProperty("path").GetString()!;
        Require(File.Exists(pdfPath),"Layered PDF file is missing");
        File.Copy(pdfPath,Path.Combine(options.RunDirectory,"layered.pdf"));
        AddCheck(report,"layered_pdf_export",true,"Two native viewport exports composed into one PDF page with switchable layers.",export);
        var readback=await ExecuteAsync(mcp,"aec_execute_read",target,"Verify original PDF viewport placements",
            "return new long[]{"+string.Join(",",ids)+"}.Select(id=>{var s=(ViewSheet)doc.GetElement(new ElementId(id));return new {sheetId=id,viewports=s.GetAllViewports().Select(v=>v.Value).ToList()};}).ToList();",false,options.Timeout);
        var actual=readback.GetProperty("result").EnumerateArray().SelectMany(s=>s.GetProperty("viewports").EnumerateArray().Select(v=>v.GetInt64())).OrderBy(x=>x).ToArray();
        var expected=fixture.GetProperty("result").GetProperty("viewports").EnumerateArray().Select(v=>v.GetInt64()).OrderBy(x=>x).ToArray();
        Require(actual.SequenceEqual(expected),"Temporary viewport isolation changed placement IDs");
        AddCheck(report,"layered_pdf_rollback",true,"Exact original viewport IDs remained after every temporary isolation transaction.",readback);
        var deleteIds=ids.Concat(fixture.GetProperty("result").GetProperty("views").EnumerateArray().Select(v=>v.GetInt64())).ToArray();
        var cleanup=await ExecuteAsync(mcp,"aec_execute_write",target,"Remove disposable PDF fixture",
            "foreach(var id in new long[]{"+string.Join(",",deleteIds)+"}) {var element=doc.GetElement(new ElementId(id));if(element!=null)doc.Delete(element.Id);} return true;",false,options.Timeout);
        Require(cleanup.GetProperty("status").GetString()=="succeeded","PDF fixture cleanup failed");
    }

    private static async Task<JsonElement> ExecuteAsync(McpClient mcp, string tool, Dictionary<string, object?> target,
        string description, string code, bool allowToolError, TimeSpan timeout)
    {
        var arguments = new Dictionary<string, object?>(target)
        {
            ["description"] = description,
            ["code"] = code,
            ["timeoutSeconds"] = Math.Clamp((int)timeout.TotalSeconds, 30, 300)
        };
        return await mcp.CallToolAsync(tool, arguments, allowToolError, timeout);
    }

    private static void VerifyDependencies(JsonElement assemblies, DriverOptions options)
    {
        var adapterName = Path.GetFileNameWithoutExtension(options.AdapterAssembly);
        var adapter = assemblies.EnumerateArray().SingleOrDefault(item => item.GetProperty("name").GetString() == adapterName);
        Require(adapter.ValueKind != JsonValueKind.Undefined, "Loaded adapter assembly was not reported.");
        Require(PathsEqual(adapter.GetProperty("location").GetString(), options.AdapterAssembly), "Revit loaded the adapter from an unexpected location.");
        var roslyn = assemblies.EnumerateArray().Where(item => (item.GetProperty("name").GetString() ?? "").StartsWith("Microsoft.CodeAnalysis", StringComparison.Ordinal)).ToList();
        if (options.RuntimeFamily == "modern")
        {
            Require(roslyn.Count > 0, "Modern adapter did not load Roslyn dependencies.");
            var adapterDirectory = Path.GetDirectoryName(options.AdapterAssembly)! + Path.DirectorySeparatorChar;
            Require(roslyn.All(item => (item.GetProperty("location").GetString() ?? "").StartsWith(adapterDirectory, StringComparison.OrdinalIgnoreCase)),
                "A Roslyn dependency resolved outside the adapter artifact directory.");
        }
        else
        {
            Require(roslyn.Count == 0, ".NET Framework adapter unexpectedly loaded Roslyn.");
        }
    }

    private static void ValidateInputs(DriverOptions options)
    {
        ValidatePathBoundary(options);
        Require(File.Exists(options.RevitExecutable), "Revit executable does not exist.");
        Require(File.Exists(options.TemplatePath), "Revit project template does not exist.");
        Require(File.Exists(options.AdapterAssembly), "Adapter assembly does not exist.");
        Require(File.Exists(options.BootstrapAssembly), "Bootstrap assembly does not exist.");
        Require(File.Exists(options.McpServer), "MCP server does not exist.");
        Require(File.Exists(options.PythonExecutable), "Python runtime does not exist.");

        var sameVersionProcesses = Process.GetProcessesByName("Revit")
            .Where(process => process.Id != Environment.ProcessId)
            .Where(process => { try { return PathsEqual(process.MainModule?.FileName, options.RevitExecutable); } catch { return false; } })
            .ToList();
        Require(sameVersionProcesses.Count == 0, $"Revit {options.Version} is already running; refusing to mix a certification run with an existing session.");
    }

    private static void ValidatePathBoundary(DriverOptions options)
    {
        Require(options.Version.Length == 4 && options.Version.All(char.IsDigit), "Version must be a four-digit matrix release.");
        Require(options.RunId.Length >= 12 && options.RunId.All(char.IsLetterOrDigit), "Run ID is invalid.");
        Require(options.Token.Length >= 32, "Run token is too short.");
        var runDirectory = Path.GetFullPath(options.RunDirectory).TrimEnd(Path.DirectorySeparatorChar);
        var expectedVersionRoot = Path.Combine(Path.GetFullPath(options.CertificationRoot), options.Version).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Require(runDirectory.StartsWith(expectedVersionRoot, StringComparison.OrdinalIgnoreCase),
            "Run directory must remain under artifacts/certification/revit/<version>.");
    }

    private static async Task WaitForExitAsync(Process process, TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        await process.WaitForExitAsync(cancellation.Token);
    }

    private static string ClassifyFailure(Exception exception) => exception switch
    {
        TimeoutException when exception.Message.Contains("bootstrap readiness", StringComparison.OrdinalIgnoreCase) => "bootstrap_readiness_timeout",
        TimeoutException => "timeout",
        OperationCanceledException => "timeout",
        InvalidOperationException when exception.Message.Contains("already running", StringComparison.OrdinalIgnoreCase) => "existing_session",
        _ => "acceptance_failed"
    };

    private static void AddCheck(LiveReport report, string name, bool passed, string message, JsonElement? evidence = null) =>
        report.Checks.Add(new LiveCheck { Name = name, Passed = passed, Message = message, Evidence = evidence });

    private static bool PathsEqual(string? left, string? right) =>
        !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right) &&
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void WriteJsonAtomic(string path, object value)
    {
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, JsonOptions));
        File.Move(temp, path, true);
    }

    private static Task WriteReportAsync(string path, LiveReport report)
    {
        WriteJsonAtomic(path, report);
        return Task.CompletedTask;
    }
}

internal sealed class McpClient : IAsyncDisposable
{
    private readonly Process _process;
    private Task<string>? _stderr;
    private int _requestId;

    public McpClient(string pythonExecutable, string serverPath)
    {
        _process = new Process
        {
            StartInfo = new ProcessStartInfo(pythonExecutable)
            {
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                Arguments = "\"" + serverPath + "\""
            }
        };
    }

    public async Task StartAsync(TimeSpan timeout)
    {
        if (!_process.Start()) throw new InvalidOperationException("Unable to start BIM Bridge MCP server.");
        _stderr = _process.StandardError.ReadToEndAsync();
        var initialized = await RequestAsync("initialize", new
        {
            protocolVersion = "2025-11-25",
            capabilities = new { },
            clientInfo = new { name = "bim-bridge-live-test", version = "2.0" }
        }, timeout);
        if (!initialized.TryGetProperty("result", out _)) throw new InvalidOperationException("MCP initialization failed.");
        await SendNotificationAsync("notifications/initialized", new { });
    }

    public async Task<JsonElement> CallToolAsync(string name, object arguments, bool allowError, TimeSpan timeout)
    {
        var response = await RequestAsync("tools/call", new { name, arguments }, timeout);
        if (response.TryGetProperty("error", out var protocolError))
            throw new InvalidOperationException("MCP protocol error: " + protocolError);
        var result = response.GetProperty("result");
        var isError = result.TryGetProperty("isError", out var errorValue) && errorValue.GetBoolean();
        var structured = result.GetProperty("structuredContent").Clone();
        if (isError && !allowError)
            throw new InvalidOperationException($"MCP tool {name} failed: {structured}");
        return structured;
    }

    private async Task<JsonElement> RequestAsync(string method, object parameters, TimeSpan timeout)
    {
        var id = Interlocked.Increment(ref _requestId);
        await _process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters }));
        await _process.StandardInput.FlushAsync();
        using var cancellation = new CancellationTokenSource(timeout);
        var line = await _process.StandardOutput.ReadLineAsync(cancellation.Token);
        if (line == null)
        {
            var error = _stderr == null ? "" : await _stderr.WaitAsync(cancellation.Token);
            throw new InvalidOperationException("MCP server stopped unexpectedly: " + error);
        }
        var response = JsonDocument.Parse(line).RootElement.Clone();
        if (response.TryGetProperty("id", out var responseId) && responseId.GetInt32() != id)
            throw new InvalidOperationException("MCP response ID mismatch.");
        return response;
    }

    private async Task SendNotificationAsync(string method, object parameters)
    {
        await _process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", method, @params = parameters }));
        await _process.StandardInput.FlushAsync();
    }

    public async ValueTask DisposeAsync()
    {
        try { _process.StandardInput.Close(); } catch { }
        try
        {
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await _process.WaitForExitAsync(cancellation.Token);
        }
        catch { try { _process.Kill(true); } catch { } }
        _process.Dispose();
    }
}

internal sealed class DriverOptions
{
    public required string Version { get; init; }
    public required string RuntimeFamily { get; init; }
    public required string RevitExecutable { get; init; }
    public required string TemplatePath { get; init; }
    public required string AdapterAssembly { get; init; }
    public required string BootstrapAssembly { get; init; }
    public required string McpServer { get; init; }
    public required string PythonExecutable { get; init; }
    public required string RunDirectory { get; init; }
    public required string CertificationRoot { get; init; }
    public required string RunId { get; init; }
    public required string Token { get; init; }
    public required TimeSpan Timeout { get; init; }

    public static DriverOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i += 2)
        {
            if (i + 1 >= args.Length || !args[i].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException("Arguments must be --name value pairs.");
            values[args[i][2..]] = args[i + 1];
        }
        string Required(string name) => values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value : throw new ArgumentException("Missing --" + name);
        return new DriverOptions
        {
            Version = Required("version"),
            RuntimeFamily = Required("runtime-family"),
            RevitExecutable = Path.GetFullPath(Required("revit-exe")),
            TemplatePath = Path.GetFullPath(Required("template")),
            AdapterAssembly = Path.GetFullPath(Required("adapter-assembly")),
            BootstrapAssembly = Path.GetFullPath(Required("bootstrap-assembly")),
            McpServer = Path.GetFullPath(Required("mcp-server")),
            PythonExecutable = Path.GetFullPath(Required("python")),
            RunDirectory = Path.GetFullPath(Required("run-directory")),
            CertificationRoot = Path.GetFullPath(Required("certification-root")),
            RunId = Required("run-id"),
            Token = Required("token"),
            Timeout = TimeSpan.FromSeconds(int.Parse(Required("timeout-seconds")))
        };
    }
}

internal sealed class LiveReport
{
    public int SchemaVersion { get; set; } = 1;
    public string RunId { get; set; } = "";
    public string Status { get; set; } = "running";
    public string RevitVersion { get; set; } = "";
    public string RuntimeFamily { get; set; } = "";
    public string StartedAtUtc { get; set; } = "";
    public string? EndedAtUtc { get; set; }
    public string RunDirectory { get; set; } = "";
    public string RevitExecutable { get; set; } = "";
    public string TemplatePath { get; set; } = "";
    public string AdapterAssembly { get; set; } = "";
    public string BootstrapAssembly { get; set; } = "";
    public int? ProcessId { get; set; }
    public string? RevitBuild { get; set; }
    public string? InstanceId { get; set; }
    public string? DocumentTitle { get; set; }
    public string? DocumentPath { get; set; }
    public string? FailureCode { get; set; }
    public string? FailureMessage { get; set; }
    public bool ForcedProcessTermination { get; set; }
    public List<LiveCheck> Checks { get; set; } = [];
}

internal sealed class LiveCheck
{
    public string Name { get; set; } = "";
    public bool Passed { get; set; }
    public string Message { get; set; } = "";
    public JsonElement? Evidence { get; set; }
}
