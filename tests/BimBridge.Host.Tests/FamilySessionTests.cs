using BimBridge.Host;
using System.Diagnostics;

public static class FamilySessionTests
{
    public static Task Run()
    {
        foreach (var name in new[] { "..", "../escape", "a/b", "a\\b", "CON", "COM1", "family.", "family ", "a:b", "has.dot", "has space", "中文", "_leading", new string('a', 81) })
        {
            bool refused = false;
            try { FamilySessionPaths.ValidateName(name); } catch (ArgumentException) { refused = true; }
            if (!refused) throw new Exception("Unsafe family filename accepted: " + name);
        }
        var scratch = Path.Combine(Path.GetTempPath(), "bim-bridge-family-paths-" + Guid.NewGuid().ToString("N"));
        var root = Path.Combine(scratch, "workspace");
        var outside = Path.Combine(scratch, "outside");
        Directory.CreateDirectory(root); Directory.CreateDirectory(outside);
        var witness = Path.Combine(outside, "witness.txt");
        File.WriteAllText(witness, "unchanged");
        var junction = Path.Combine(root, "link");
        try
        {
            var path = FamilySessionPaths.Resolve(root, "job-1", "Furniture");
            if (path != Path.Combine(root, "job-1", "Furniture.rfa")) throw new Exception("Incorrect family destination");
            using (var process = Process.Start(new ProcessStartInfo("cmd.exe", "/c mklink /J \"" + junction + "\" \"" + outside + "\"")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
            {
                process!.WaitForExit();
                if (process.ExitCode != 0) throw new Exception("Could not create junction fixture: " + process.StandardError.ReadToEnd());
            }
            bool refused = false;
            try { FamilySessionPaths.Resolve(root, "link", "Furniture"); } catch (IOException) { refused = true; }
            if (!refused) throw new Exception("Family output escaped through junction");
            refused = false;
            try { FamilySessionPaths.Resolve(junction, "job", "Furniture"); } catch (IOException) { refused = true; }
            if (!refused) throw new Exception("Workspace anchor junction was accepted");
            if (File.ReadAllText(witness) != "unchanged") throw new Exception("External witness changed");
        }
        finally
        {
            if (Directory.Exists(junction)) Directory.Delete(junction); // unlink only, never recurse through it
            Directory.Delete(scratch, true);
        }
        using var request = new ConnectorRequest(ConnectorRequestKind.Execute, "write", "family save", "", 60,
            operation: "family.session", familySession: new ConnectorFamilySessionOptions { Action = "save_close" }, taskId: "owner");
        if (!request.TryStart()) throw new Exception("Could not start lifecycle request");
        request.MarkSaveStarted(); request.MarkSaveCompleted();
        request.Complete(new ConnectorCompletion { Status = ConnectorRequestStatus.Succeeded });
        var snapshot = request.Snapshot();
        if (snapshot.SaveStartedAtUtc == null || snapshot.SaveCompletedAtUtc == null || snapshot.CompletedAtUtc == null || snapshot.StartedAtUtc == null)
            throw new Exception("Lifecycle timestamp evidence missing");
        if (DateTime.Parse(snapshot.SaveStartedAtUtc) > DateTime.Parse(snapshot.SaveCompletedAtUtc) ||
            DateTime.Parse(snapshot.SaveCompletedAtUtc) > DateTime.Parse(snapshot.CompletedAtUtc)) throw new Exception("Save timestamps out of order");
        return Task.CompletedTask;
    }
}
