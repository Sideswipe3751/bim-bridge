[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$KimiVersionOverride,
    [string]$KimiCommandOverride
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-RecordedHash($State, [string]$Path) {
    foreach ($file in @($State.files)) {
        if ($file.path -and [IO.Path]::GetFullPath([string]$file.path) -eq $Path) {
            return [string]$file.sha256
        }
    }
    return $null
}

function Find-KimiCode {
    if ($KimiVersionOverride) {
        return [ordered]@{
            command = if ($KimiCommandOverride) { $KimiCommandOverride } else { 'kimi.exe' }
            version = $KimiVersionOverride
        }
    }

    $command = Get-Command kimi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }
    $commandPath = if ($command.Path) { [string]$command.Path } else { [string]$command.Source }
    # Windows PowerShell 5.1 resolves an npm-installed `kimi` to the kimi.ps1
    # shim (ExternalScript ranks ahead of Application), and the shim's nested
    # native call does not surface --version output to the caller. Probe the
    # sibling .cmd shim first when the resolved command is a .ps1 script.
    $probePath = $commandPath
    if ([IO.Path]::GetExtension($commandPath) -ieq '.ps1') {
        $cmdShim = [IO.Path]::ChangeExtension($commandPath, '.cmd')
        if (Test-Path -LiteralPath $cmdShim -PathType Leaf) { $probePath = $cmdShim }
    }
    $version = $null
    try {
        $version = [string]@(& $probePath --version 2>$null)[0]
    } catch {
        $version = $null
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        # Last-resort read-only fallback for npm layouts: the bundled package.json.
        $pkgJson = Join-Path (Split-Path -Parent $commandPath) 'node_modules\@moonshot-ai\kimi-code\package.json'
        if (Test-Path -LiteralPath $pkgJson -PathType Leaf) {
            try {
                $version = [string](Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json).version
            } catch {
                $version = $null
            }
        }
    }
    return [ordered]@{ command = $commandPath; version = $version }
}

if (-not $StateRoot) {
    $StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
}
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$statePath = Join-Path $StateRoot 'install-state.json'
$kimiCode = Find-KimiCode
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
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash.ToUpperInvariant()) {
            [void]$changedFiles.Add($path)
        }
    }
}

$runningAutodesk = @()
foreach ($process in @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)) {
    $runningAutodesk += [ordered]@{
        name = $process.ProcessName
        processId = $process.Id
        title = $process.MainWindowTitle
    }
}

$status = 'healthy'
$recommendedAction = 'none'
if (-not $kimiCode) {
    $status = 'kimi_code_not_found'
    $recommendedAction = 'install_kimi_code'
} elseif (-not $state) {
    $status = if ($stateError) { 'needs_repair' } else { 'not_installed' }
    $recommendedAction = if ($stateError) { 'repair_host' } else { 'install_host' }
} elseif ($stateError -or $missingFiles.Count -gt 0 -or $changedFiles.Count -gt 0) {
    $status = 'needs_repair'
    $recommendedAction = 'repair_host'
}

[ordered]@{
    schemaVersion = 1
    adapter = 'kimi'
    status = $status
    recommendedAction = $recommendedAction
    kimiCode = [ordered]@{
        installed = [bool]$kimiCode
        command = if ($kimiCode) { [string]$kimiCode.command } else { $null }
        version = if ($kimiCode) { [string]$kimiCode.version } else { $null }
        mcpConfiguration = 'plugin_or_project_file'
    }
    host = [ordered]@{
        statePath = $statePath
        installedVersion = if ($state) { [string]$state.version } else { $null }
        stateSchemaVersion = if ($state) { $state.schemaVersion } else { $null }
        stateError = $stateError
        launcher = if ($state) { [string]$state.launcher } else { $null }
        missingFiles = @($missingFiles)
        changedFiles = @($changedFiles)
    }
    runningAutodesk = $runningAutodesk
} | ConvertTo-Json -Depth 8
