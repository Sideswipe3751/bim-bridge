using System;
using System.Diagnostics;
using System.IO;

namespace BimBridge.Revit.LayeredPdf;

public static class ComposerProcessRunner
{
    public static string ExecutablePath => Path.Combine(
        Path.GetDirectoryName(typeof(ComposerProcessRunner).Assembly.Location)!,
        "Composer", "BimBridge.LayeredPdf.Composer.exe");

    public static void Run(string jobPath, DateTime deadlineUtc)
    {
        if (!File.Exists(ExecutablePath)) throw new FileNotFoundException("BIM Bridge PDF composer is unavailable", ExecutablePath);
        var remaining = (int)Math.Min(300000, Math.Max(0, (deadlineUtc - DateTime.UtcNow).TotalMilliseconds));
        if (remaining < 1) throw new TimeoutException("PDF composition deadline reached");
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = ExecutablePath, Arguments = "\"" + jobPath + "\"", CreateNoWindow = true,
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
        }) ?? throw new InvalidOperationException("Could not start PDF composer");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(remaining))
        {
            process.Kill();
            process.WaitForExit();
            throw new TimeoutException("PDF composer timed out; Revit changes were already restored");
        }
        if (process.ExitCode != 0)
        {
            var message = stderr.GetAwaiter().GetResult() + stdout.GetAwaiter().GetResult();
            throw new InvalidOperationException("PDF composer failed: " + message.Substring(0, Math.Min(message.Length, 4096)));
        }
    }
}
