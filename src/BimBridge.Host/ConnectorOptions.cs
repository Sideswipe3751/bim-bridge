using System;
using System.IO;

namespace BimBridge.Host;

public sealed class ConnectorOptions
{
    public string BindHost { get; set; } = "127.0.0.1";
    public int Port { get; set; } = 4821;
    public int PortFallbackCount { get; set; } = 20;
    public int MaxQueuedRequests { get; set; } = 50;
    public int DefaultTimeoutSeconds { get; set; } = 30;
    public int MaxTimeoutSeconds { get; set; } = 300;
    public int MaxBodyBytes { get; set; } = 1024 * 1024;
    public string InstanceDirectory { get; set; } = DefaultInstanceDirectory();

    public static string DefaultInstanceDirectory()
    {
        var configured = Environment.GetEnvironmentVariable("BIM_BRIDGE_INSTANCE_DIR");
        if (string.IsNullOrWhiteSpace(configured))
            configured = Environment.GetEnvironmentVariable("AEC_CODEX_INSTANCE_DIR");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "BIM Bridge", "instances");
    }
}
