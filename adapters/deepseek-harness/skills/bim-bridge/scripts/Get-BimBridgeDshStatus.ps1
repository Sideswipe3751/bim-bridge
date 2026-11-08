[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$DshVersionOverride,
    [string]$DshCommandOverride,
    [string]$DshHomeOverride
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-Sha256([string]$Path) {
    # .NET instead of Get-FileHash: DeepSeek Harness's MCP spawn environment can
    # leave Microsoft.PowerShell.Utility partially loaded so that Get-FileHash is
    # unavailable while ConvertFrom-Json still resolves. See the launcher wrapper.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '')
}

function Get-RecordedHash($State, [string]$Path) {
    foreach ($file in @($State.files)) {
        if ($file.path -and [IO.Path]::GetFullPath([string]$file.path) -eq $Path) {
            return [string]$file.sha256
        }
    }
    return $null
}

# DeepSeek Harness does not have to be on PATH for this adapter to work. The
# per-user DSH installation exposes a `dsh` entry point at a fixed, derivable
# location, and it ships the runtime interpreter (node.exe) that the local
# checkout's shim needs. Discovery is therefore ordered, and honest about where a
# candidate came from:
#
#   * BIM_BRIDGE_DSH_COMMAND / BIM_BRIDGE_DSH_NODE - an explicit operator
#     override, used as-is and terminal: a missing override fails discovery
#     instead of being silently replaced by a discovered installation;
#   * the process PATH;
#   * the per-user DSH installation directory
#     (%LOCALAPPDATA%\Programs\DeepSeekHarness).
#
# A discovered candidate is only accepted when it exists on disk, so a stale
# directory never turns into a phantom "installed" result. Discovery never writes,
# and it never edits PATH - neither the process PATH nor the persisted user PATH.
function Add-DshCandidatePath($List, $Seen, $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $full = [IO.Path]::GetFullPath([string]$Path)
    if ($Seen.ContainsKey($full)) { return }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $Seen[$full] = $true
    [void]$List.Add([ordered]@{ path = $full; source = $null })
}

function Get-DshNodeCandidates {
    # node.exe candidates, in resolution order. The DSH shim script itself falls
    # back to a bare `node` on PATH, which is exactly what fails in a PATH-less
    # spawn; resolving the bundled interpreter is what removes that dependency.
    #
    # As with the `dsh` override, BIM_BRIDGE_DSH_NODE is terminal rather than a
    # hint: it is the only candidate when it is set, so a broken override is
    # reported as an unresolved interpreter instead of being masked by a
    # discovered one.
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}

    if ($env:BIM_BRIDGE_DSH_NODE) {
        Add-DshCandidatePath $candidates $seen $env:BIM_BRIDGE_DSH_NODE
        if ($candidates.Count -gt 0) { $candidates[0].source = 'BIM_BRIDGE_DSH_NODE' }
        return @($candidates)
    }

    $command = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $before = $candidates.Count
        Add-DshCandidatePath $candidates $seen $(if ($command.Path) { $command.Path } else { $command.Source })
        if ($candidates.Count -gt $before) { $candidates[$candidates.Count - 1].source = 'PATH' }
    }

    $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\DeepSeekHarness'
    $bundled = @(Get-ChildItem -LiteralPath $installRoot -Directory -Filter 'node-*-win-*' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending)
    foreach ($directory in $bundled) {
        $candidate = Join-Path $directory.FullName 'node.exe'
        $before = $candidates.Count
        Add-DshCandidatePath $candidates $seen $candidate
        if ($candidates.Count -gt $before) { $candidates[$candidates.Count - 1].source = 'bundled_node' }
    }

    return @($candidates)
}

function Get-DshCommandCandidates([string]$DshHomePath) {
    # The fallback `dsh` entry points, in resolution order:
    #
    #   1. the process PATH;
    #   2. the per-user DSH launcher, %LOCALAPPDATA%\Programs\DeepSeekHarness\bin\dsh.cmd.
    #      This is the installation's own entry point: it already prepends the
    #      bundled Node directory before delegating to the local checkout's
    #      node_modules\.bin\dsh.cmd, so resolving it is what makes the adapter
    #      work with no dsh and no node on PATH and no global installation;
    #   3. the DSH home's own node_modules\.bin\dsh.cmd, for a checkout that keeps
    #      its dependencies under the DSH home instead.
    #
    # The explicit BIM_BRIDGE_DSH_COMMAND override is handled by the caller and is
    # deliberately absent here: an override is terminal, never a hint.
    #
    # No directory is ever scanned to find these: every candidate is a fixed,
    # documented path. Discovery never writes and never edits PATH.
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}

    $command = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $before = $candidates.Count
        Add-DshCandidatePath $candidates $seen $(if ($command.Path) { $command.Path } else { $command.Source })
        if ($candidates.Count -gt $before) { $candidates[$candidates.Count - 1].source = 'PATH' }
    }

    $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\DeepSeekHarness'
    foreach ($fixed in @(
        [ordered]@{ path = (Join-Path $installRoot 'bin\dsh.cmd'); source = 'dsh_install' }
        [ordered]@{ path = (Join-Path $DshHomePath 'node_modules\.bin\dsh.cmd'); source = 'dsh_home' }
    )) {
        $before = $candidates.Count
        Add-DshCandidatePath $candidates $seen $fixed.path
        if ($candidates.Count -gt $before) { $candidates[$candidates.Count - 1].source = $fixed.source }
    }

    return @($candidates)
}

function Find-DeepSeekHarness([string]$DshHomePath) {
    if ($DshVersionOverride) {
        return [ordered]@{
            command = if ($DshCommandOverride) { $DshCommandOverride } else { 'dsh' }
            commandSource = 'override'
            version = $DshVersionOverride
        }
    }

    # An explicit override is terminal, not a hint: when the operator names a
    # `dsh` entry point, that is the one this adapter uses, and a missing one is
    # reported as missing rather than being silently replaced by a discovered
    # installation. Silently falling back would let a status check claim success
    # against a different installation than the one it was pointed at.
    $source = 'parameter'
    $commandPath = $null
    if ($DshCommandOverride) {
        $commandPath = [IO.Path]::GetFullPath([string]$DshCommandOverride)
        if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) { return $null }
    } elseif ($env:BIM_BRIDGE_DSH_COMMAND) {
        $source = 'BIM_BRIDGE_DSH_COMMAND'
        $commandPath = [IO.Path]::GetFullPath([string]$env:BIM_BRIDGE_DSH_COMMAND)
        if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) { return $null }
    } else {
        $resolved = @(Get-DshCommandCandidates $DshHomePath | Select-Object -First 1)
        if ($resolved.Count -eq 0) { return $null }
        $commandPath = [string]$resolved[0].path
        $source = [string]$resolved[0].source
    }

    $version = $null
    try {
        $version = [string]@(& $commandPath --version 2>$null)[0]
    } catch {
        $version = $null
    }
    return [ordered]@{ command = $commandPath; commandSource = $source; version = $version }
}

# Read-only: enumerate the profiles that exist so the operator can see where an
# MCP row would have to be registered. This never reads or writes credentials,
# and it never edits a profile.
function Get-ProfileNames([string]$DshHomePath) {
    $profilesRoot = Join-Path $DshHomePath 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) { return @() }
    $names = New-Object System.Collections.ArrayList
    foreach ($directory in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'package.json') -PathType Leaf) {
            [void]$names.Add($directory.Name)
        }
    }
    return @($names)
}

if (-not $StateRoot) {
    $StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
}
if (-not $DshHomeOverride) {
    $DshHomeOverride = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.dsh' }
}

$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$DshHomeOverride = [IO.Path]::GetFullPath($DshHomeOverride)
$statePath = Join-Path $StateRoot 'install-state.json'
$dsh = Find-DeepSeekHarness $DshHomeOverride
$dshNode = @(Get-DshNodeCandidates | Select-Object -First 1)
$dshNodeRecord = if ($dshNode.Count -gt 0) { $dshNode[0] } else { $null }
$state = $null
$stateError = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { $stateError = $_.Exception.Message }
}
if ($state -and $state.schemaVersion -ne 4) { $stateError = 'Unsupported BIM Bridge install-state schema.' }

$missingFiles = New-Object System.Collections.ArrayList
$changedFiles = New-Object System.Collections.ArrayList
$criticalFiles = @()
if ($state -and -not $stateError) {
    foreach ($property in @('launcher', 'python', 'localMcpServer', 'files')) {
        $value = $state.PSObject.Properties[$property]
        if (-not $value -or $null -eq $value.Value -or
            ($property -ne 'files' -and [string]::IsNullOrWhiteSpace([string]$value.Value))) {
            $stateError = "BIM Bridge install state is missing '$property'."
            break
        }
        if ($property -eq 'files') { continue }
        $criticalFiles += [IO.Path]::GetFullPath([string]$value.Value)
    }
}

if (-not $stateError) {
    foreach ($path in $criticalFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missingFiles.Add($path)
            continue
        }
        $expectedHash = Get-RecordedHash $state $path
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or $expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            [void]$changedFiles.Add($path)
            continue
        }
        if ((Get-Sha256 $path) -ne $expectedHash.ToUpperInvariant()) {
            [void]$changedFiles.Add($path)
        }
    }
}

$runningAutodesk = @()
foreach ($process in @(Get-Process -Name Revit, acad -ErrorAction SilentlyContinue)) {
    $runningAutodesk += [ordered]@{
        name = $process.ProcessName
        processId = $process.Id
        title = $process.MainWindowTitle
    }
}

# Connector deployment is reported exactly as the shared Host recorded it. The
# adapter deliberately does not re-derive Autodesk compatibility: the single
# version matrix lives in eng/Autodesk.Versions.props and the Runtime.
$recordedProducts = @()
if ($state -and -not $stateError -and $state.PSObject.Properties['products']) {
    foreach ($product in @('revit', 'autocad')) {
        $entries = $state.products.PSObject.Properties[$product]
        if (-not $entries) { continue }
        foreach ($entry in @($entries.Value)) {
            $recordedProducts += [ordered]@{
                product = $product
                version = [string]$entry.version
                targetFramework = [string]$entry.targetFramework
                runtimeFamily = [string]$entry.runtimeFamily
            }
        }
    }
}

$status = 'healthy'
$recommendedAction = 'none'
if (-not $dsh) {
    $status = 'deepseek_harness_not_found'
    $recommendedAction = 'install_deepseek_harness'
} elseif (-not $state) {
    $status = if ($stateError) { 'needs_repair' } else { 'not_installed' }
    $recommendedAction = if ($stateError) { 'repair_host' } else { 'install_host' }
} elseif ($stateError -or $missingFiles.Count -gt 0 -or $changedFiles.Count -gt 0) {
    $status = 'needs_repair'
    $recommendedAction = 'repair_host'
}

[ordered]@{
    schemaVersion = 1
    adapter = 'deepseek-harness'
    status = $status
    recommendedAction = $recommendedAction
    deepSeekHarness = [ordered]@{
        installed = [bool]$dsh
        command = if ($dsh) { [string]$dsh.command } else { $null }
        commandSource = if ($dsh) { [string]$dsh.commandSource } else { $null }
        version = if ($dsh) { [string]$dsh.version } else { $null }
        node = if ($dshNodeRecord) { [string]$dshNodeRecord.path } else { $null }
        nodeSource = if ($dshNodeRecord) { [string]$dshNodeRecord.source } else { $null }
        home = $DshHomeOverride
        profiles = @(Get-ProfileNames $DshHomeOverride)
        mcpConfiguration = 'profile_cordis_config'
        mcpClientPackage = '@deepseek-ai/dsh-mcp-client'
        toolNamePrefix = 'mcp__bim-bridge__'
    }
    host = [ordered]@{
        statePath = $statePath
        installedVersion = if ($state) { [string]$state.version } else { $null }
        stateSchemaVersion = if ($state) { $state.schemaVersion } else { $null }
        stateError = $stateError
        launcher = if ($state) { [string]$state.launcher } else { $null }
        missingFiles = @($missingFiles)
        changedFiles = @($changedFiles)
        recordedProducts = $recordedProducts
    }
    runningAutodesk = $runningAutodesk
} | ConvertTo-Json -Depth 8
