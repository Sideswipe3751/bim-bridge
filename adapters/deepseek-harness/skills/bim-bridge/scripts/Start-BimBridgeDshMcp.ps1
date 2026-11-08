[CmdletBinding()]
param(
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-Sha256([string]$Path) {
    # SHA-256 is computed through .NET rather than Get-FileHash.
    #
    # DeepSeek Harness spawns MCP stdio servers with a scrubbed environment whose
    # PSModulePath is PowerShell 7 oriented. Under Windows PowerShell 5.1 that can
    # leave Microsoft.PowerShell.Utility partially loaded: ConvertFrom-Json (PS 3.0)
    # resolves while Get-FileHash (PS 4.0) does not. Depending on Get-FileHash would
    # make this wrapper fail in the exact environment it exists to serve. Verified on
    # the real spawn: Get-FileHash=False while ConvertFrom-Json=True.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '')
}

function Write-McpError([string]$Message) {
    [Console]::Error.WriteLine('BIM Bridge DeepSeek Harness adapter: ' + $Message)
}

# The recorded Host root check above is lexical: it compares path strings. A
# launcher whose recorded path is inside the Host root can still reach bytes
# outside it through the file system's own aliasing, and neither GetFullPath nor
# the installation hash notices, because the hash matches the bytes that the
# alias delivers. Two aliases reach outside the root and both are refused:
#
#   * a reparse point (directory junction or symlink) nested anywhere between the
#     root and the launcher, which redirects the lookup to a directory elsewhere;
#   * a hard link, which has no canonical "real" path at all - the recorded path
#     is a full alias of data that may have been created outside the root.
#
# Both are detected through Win32 rather than through Get-FileHash-class cmdlets,
# for the same reason Get-Sha256 uses .NET: the DeepSeek Harness spawn environment
# can leave Microsoft.PowerShell.Utility partially loaded.
if (-not ('BimBridgeDshLinkGuard.Win32' -as [type])) {
    Add-Type -Namespace BimBridgeDshLinkGuard -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct NativeFileTime { public uint Low; public uint High; }

[StructLayout(LayoutKind.Sequential)]
public struct ByHandleFileInformation {
    public uint FileAttributes;
    public NativeFileTime CreationTime;
    public NativeFileTime LastAccessTime;
    public NativeFileTime LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
}

[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
    uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetFileInformationByHandle(
    Microsoft.Win32.SafeHandles.SafeFileHandle hFile, out ByHandleFileInformation lpFileInformation);

[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandleW(
    Microsoft.Win32.SafeHandles.SafeFileHandle hFile, System.Text.StringBuilder lpszFilePath,
    uint cchFilePath, uint dwFlags);
'@
}

function Get-LauncherPathShape([string]$Path) {
    # Returns @{ Ok; RealPath; IsReparsePoint; NumberOfLinks } for an existing file.
    # $Path must already exist; the caller reports a missing launcher separately.
    $openExisting = 3
    $flagOpenReparsePoint = 0x00200000
    $flagBackupSemantics = 0x02000000
    $openReparse = $flagOpenReparsePoint -bor $flagBackupSemantics
    $result = @{ Ok = $false; RealPath = $null; IsReparsePoint = $false; NumberOfLinks = 0 }

    # 1. Does the path name a reparse point itself?
    $reparseHandle = [BimBridgeDshLinkGuard.Win32]::CreateFileW(
        $Path, 0, 7, [IntPtr]::Zero, $openExisting, $openReparse, [IntPtr]::Zero)
    if ($reparseHandle.IsInvalid) {
        return $result
    }
    try {
        $reparseInfo = New-Object BimBridgeDshLinkGuard.Win32+ByHandleFileInformation
        if ([BimBridgeDshLinkGuard.Win32]::GetFileInformationByHandle($reparseHandle, [ref]$reparseInfo)) {
            $result.IsReparsePoint = (($reparseInfo.FileAttributes -band 0x400) -eq 0x400)
        }
    } finally {
        $reparseHandle.Dispose()
    }

    # 2. Follow every reparse point and report where the file really lives
    #    (\\?\ volume prefix stripped), plus its hard-link count.
    $handle = [BimBridgeDshLinkGuard.Win32]::CreateFileW($Path, 0, 7, [IntPtr]::Zero, $openExisting, $flagBackupSemantics, [IntPtr]::Zero)
    if ($handle.IsInvalid) {
        return $result
    }
    try {
        $buffer = New-Object System.Text.StringBuilder 32768
        $written = [BimBridgeDshLinkGuard.Win32]::GetFinalPathNameByHandleW($handle, $buffer, 32768, 0)
        if ($written -gt 0) {
            $realPath = $buffer.ToString()
            $result.RealPath = $realPath -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\\\\?\\', ''
            $result.Ok = $true
        }
        $information = New-Object BimBridgeDshLinkGuard.Win32+ByHandleFileInformation
        if ([BimBridgeDshLinkGuard.Win32]::GetFileInformationByHandle($handle, [ref]$information)) {
            $result.NumberOfLinks = $information.NumberOfLinks
        }
    } finally {
        $handle.Dispose()
    }
    return $result
}

function Get-RecordedHash($State, [string]$Path) {
    foreach ($file in @($State.files)) {
        if ($file.path -and [IO.Path]::GetFullPath([string]$file.path) -eq $Path) {
            return [string]$file.sha256
        }
    }
    return $null
}

function Resolve-DeepSeekHarnessNode {
    # The delegated Host and anything it spawns must not depend on node.exe being
    # on PATH. DeepSeek Harness does not have to be globally installed: its
    # runtime interpreter ships inside the per-user DSH installation directory,
    # and the local `dsh` shim itself falls back to a bare `node` on PATH, which
    # is exactly what is absent in a scrubbed spawn environment.
    #
    # This resolves that interpreter and nothing else. It never edits PATH -
    # neither the process PATH nor the persisted user PATH - and it never writes.
    # The caller prepends the directory to the child's environment only, so the
    # change is scoped to the delegated process.
    #
    # A resolution failure is never fatal: the wrapper's job is Host containment,
    # and a missing interpreter must not change its exit semantics.
    if ($env:BIM_BRIDGE_DSH_NODE) {
        $override = [IO.Path]::GetFullPath([string]$env:BIM_BRIDGE_DSH_NODE)
        if (Test-Path -LiteralPath $override -PathType Leaf) { return $override }
        return $null
    }

    $command = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $onPath = if ($command.Path) { [string]$command.Path } else { [string]$command.Source }
        if ($onPath -and (Test-Path -LiteralPath $onPath -PathType Leaf)) { return [IO.Path]::GetFullPath($onPath) }
    }

    $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\DeepSeekHarness'
    $bundled = @(Get-ChildItem -LiteralPath $installRoot -Directory -Filter 'node-*-win-*' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending)
    foreach ($directory in $bundled) {
        $candidate = Join-Path $directory.FullName 'node.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

try {
    if (-not $StateRoot) {
        $StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
    }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $statePath = Join-Path $StateRoot 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "BIM Bridge Host state is missing: $statePath"
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -ne 4) { throw 'Unsupported BIM Bridge install-state schema.' }
    $launcher = [IO.Path]::GetFullPath([string]$state.launcher)
    $hostRoot = [IO.Path]::GetFullPath((Join-Path $StateRoot 'host'))
    $hostPrefix = $hostRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $launcher.StartsWith($hostPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recorded Host launcher is outside the BIM Bridge Host root: $launcher"
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Recorded Host launcher is missing: $launcher"
    }

    # The lexical check above is not sufficient on its own: aliases can deliver
    # bytes from outside the Host root through an in-root path.
    $launcherShape = Get-LauncherPathShape $launcher
    if (-not $launcherShape.Ok -or [string]::IsNullOrWhiteSpace($launcherShape.RealPath)) {
        throw "Recorded Host launcher could not be resolved to a real path: $launcher"
    }
    $realLauncher = [IO.Path]::GetFullPath($launcherShape.RealPath)
    $realHostRoot = [IO.Path]::GetFullPath($hostRoot)
    $realHostPrefix = $realHostRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($launcherShape.IsReparsePoint) {
        throw "Recorded Host launcher is a reparse point: $launcher"
    }
    if ($realLauncher -ne $realHostRoot -and -not $realLauncher.StartsWith($realHostPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recorded Host launcher resolves outside the BIM Bridge Host root: $launcher -> $realLauncher"
    }
    if ($launcherShape.NumberOfLinks -gt 1) {
        throw "Recorded Host launcher has multiple hard links and is not contained by the BIM Bridge Host root: $launcher"
    }

    $expectedHash = Get-RecordedHash $state $launcher
    if ([string]::IsNullOrWhiteSpace($expectedHash) -or $expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Recorded Host launcher does not have a valid installation hash.'
    }
    $actualHash = Get-Sha256 $launcher
    if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
        throw "Recorded Host launcher hash mismatch: $launcher"
    }

    # stdout belongs exclusively to the MCP protocol; this marker travels to the
    # neutral Host through the environment, never through stdout.
    $env:BIM_BRIDGE_AGENT_ADAPTER = 'deepseek-harness'

    # Make the resolved DeepSeek Harness interpreter reachable for the delegated
    # process and its own children without requiring a global installation. Only
    # the child's environment copy is touched; the persisted user PATH is not.
    $dshNode = Resolve-DeepSeekHarnessNode
    if ($dshNode) {
        $nodeDirectory = Split-Path -Parent $dshNode
        $pathEntries = @($env:PATH -split ';' | Where-Object { $_.Trim().Length -gt 0 })
        if (-not ($pathEntries | Where-Object { $_.TrimEnd('\') -ieq $nodeDirectory.TrimEnd('\') })) {
            $env:PATH = $nodeDirectory + ';' + $env:PATH
        }
    }

    & $launcher
    $processExitCode = 0
    $lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($lastExitCodeVariable) { $processExitCode = [int]$lastExitCodeVariable.Value }
    exit $processExitCode
} catch {
    Write-McpError $_.Exception.Message
    exit 1
}
