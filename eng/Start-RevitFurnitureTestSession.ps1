[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [ValidateRange(10, 180)][int]$TimeoutSeconds = 180,
    [string]$BootstrapAssembly,
    [string]$AdapterDirectory,
    [string]$FamilyWorkspace
)

# Development-only launcher. Never installs or replaces installed Host binaries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1')

function Assert-NoRedirectingLink([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            # LinkType identifies junction/symlink targets without rejecting
            # OneDrive's non-link cloud placeholder reparse attribute.
            if (($item.PSObject.Properties['LinkType'] -and $item.LinkType) -or
                ($item.PSObject.Properties['Target'] -and @($item.Target | Where-Object { $_ }).Count -gt 0)) {
                throw "Redirecting link is not allowed: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-InRoot([string]$Path, [string]$Root) {
    if (($Path -split '[\\/]') -contains '..') { throw "Traversal is not allowed: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the allowed root: $full"
    }
    Assert-NoRedirectingLink $full
    return $full
}

$outputRoot = Join-Path $repositoryRoot 'output\multi-agent-2024'
$requestFile = Assert-InRoot $RequestPath $outputRoot
if (-not (Test-Path -LiteralPath $requestFile -PathType Leaf)) { throw 'Existing request JSON is required.' }
$request = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
if ($request.schemaVersion -ne 1 -or $request.version -ne '2024' -or
    $request.runId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{5,79}$' -or
    $request.sessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,60}$' -or
    $request.token -notmatch '^[a-fA-F0-9]{64}$' -or
    $request.mode -notin @('family', 'project', 'resident')) { throw 'Invalid furniture request identity/schema.' }
$runDirectory = Assert-InRoot (Join-Path $outputRoot $request.runId) $outputRoot
if (-not [string]::Equals((Split-Path -Parent $requestFile), $runDirectory, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($requestFile) -ne ($request.sessionId + '.request.json')) {
    throw 'Request must be exactly <output-root>/<runId>/<sessionId>.request.json.'
}
if ($request.documentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{1,120}$' -or
    $request.documentName.Contains('..') -or
    ($request.mode -eq 'family' -and [IO.Path]::GetExtension($request.documentName) -ne '.rfa') -or
    ($request.mode -in @('project', 'resident') -and [IO.Path]::GetExtension($request.documentName) -ne '.rvt')) {
    throw 'Invalid disposable document name.'
}
$documentPath = Assert-InRoot (Join-Path $runDirectory $request.documentName) $runDirectory
if (Test-Path -LiteralPath $documentPath) { throw "Refusing to reuse an existing disposable document: $documentPath" }
if ($request.mode -eq 'project') {
    if (-not $request.PSObject.Properties['families'] -or @($request.families).Count -lt 1) { throw 'Project assembly requires prepared families.' }
    foreach ($placement in @($request.families)) {
        if ($placement.fileName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{1,120}$' -or
            $placement.fileName.Contains('..') -or [IO.Path]::GetExtension($placement.fileName) -ne '.rfa') { throw 'Invalid input family name.' }
        $familyPath = Assert-InRoot (Join-Path $runDirectory $placement.fileName) $runDirectory
        if (-not (Test-Path -LiteralPath $familyPath -PathType Leaf)) { throw "Prepared family is missing: $familyPath" }
    }
}
$templatePath = [IO.Path]::GetFullPath([string]$request.templatePath)
Assert-NoRedirectingLink $templatePath
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'Exact installed template is missing.' }
$readyPath = Assert-InRoot (Join-Path $runDirectory ($request.sessionId + '.ready.json')) $runDirectory
$failedPath = Assert-InRoot (Join-Path $runDirectory ($request.sessionId + '.failed.json')) $runDirectory
foreach ($marker in @($readyPath, $failedPath)) {
    if (Test-Path -LiteralPath $marker) { throw "Refusing stale session evidence: $marker" }
}
$instancesPath = Assert-InRoot (Join-Path $runDirectory 'instances') $runDirectory
if ($request.mode -eq 'resident') {
    if (-not $FamilyWorkspace) { $FamilyWorkspace = Join-Path $runDirectory 'resident-families' }
    $FamilyWorkspace = Assert-InRoot $FamilyWorkspace $runDirectory
} elseif ($FamilyWorkspace) { throw 'FamilyWorkspace is only valid for resident mode.' }

$entries = @(Get-RevitMatrixEntries (Join-Path $PSScriptRoot 'Autodesk.Versions.props') | Where-Object { $_.Include -eq $request.version })
if ($entries.Count -ne 1) { throw 'Requested Revit version is not unique in the existing version matrix.' }
$release = Resolve-RevitMatrixEntry $entries[0]
if (-not (Test-Path -LiteralPath $release.RevitExecutable -PathType Leaf)) { throw 'Resolved Revit executable is missing.' }
if (-not $AdapterDirectory) { $AdapterDirectory = Join-Path $repositoryRoot ('src\BimBridge.Revit\bin\Release\' + $release.Include + '\' + $release.TargetFramework) }
$adapterDirectory = Assert-InRoot $AdapterDirectory $repositoryRoot
$adapterDll = Assert-InRoot (Join-Path $adapterDirectory ($release.AssemblyName + '.dll')) $repositoryRoot
$hostDll = Assert-InRoot (Join-Path $adapterDirectory 'BimBridge.Host.dll') $repositoryRoot
$bootstrapDirectory = Join-Path $repositoryRoot ('tests\revit\BimBridge.Revit.FurnitureBootstrap\bin\Release\' + $release.TargetFramework)
if (-not $BootstrapAssembly) { $BootstrapAssembly = Join-Path $bootstrapDirectory ('BimBridge.Revit.FurnitureBootstrap' + $release.Include + '.dll') }
$bootstrapDll = Assert-InRoot $BootstrapAssembly $repositoryRoot
foreach ($dll in @($adapterDll, $hostDll, $bootstrapDll)) {
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "Prebuilt Release artifact is missing: $dll" }
}
$developmentTrust = Join-Path $env:LOCALAPPDATA 'BIM Bridge\development-trust\revit-live-test-signing.json'
$signatureEvidence = @()
foreach ($dll in @($adapterDll, $hostDll, $bootstrapDll)) {
    $signature = Get-AuthenticodeSignature -LiteralPath $dll
    if ($signature.Status -ne 'Valid' -and (Test-Path -LiteralPath $developmentTrust -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'Sign-RevitLiveTestArtifacts.ps1') -Path @($dll) | Out-Null
        $signature = Get-AuthenticodeSignature -LiteralPath $dll
    }
    if ($signature.Status -ne 'Valid') { throw "Untrusted test artifact: $dll ($($signature.Status))" }
    $signatureEvidence += [ordered]@{ path = $dll; status = [string]$signature.Status; thumbprint = $signature.SignerCertificate.Thumbprint }
}

$addinDirectory = Join-Path $env:APPDATA ('Autodesk\Revit\Addins\' + $release.Include)
Assert-NoRedirectingLink $addinDirectory
if (-not (Test-Path -LiteralPath $addinDirectory -PathType Container)) { throw 'Expected current-user add-in directory is missing.' }
$connectorManifest = Join-Path $addinDirectory 'BimBridge.FurnitureTest.Connector.addin'
$bootstrapManifest = Join-Path $addinDirectory 'BimBridge.FurnitureTest.Bootstrap.addin'
$connectorContent = @"
<?xml version="1.0" encoding="utf-8"?>
<RevitAddIns><AddIn Type="Application"><Name>BIM Bridge Furniture Test Connector</Name><Assembly>$([Security.SecurityElement]::Escape($adapterDll))</Assembly><AddInId>$(Get-RevitAddInId)</AddInId><FullClassName>BimBridge.Revit.BimBridgeApplication</FullClassName><VendorId>BMBR</VendorId><VendorDescription>Disposable development test connector</VendorDescription></AddIn></RevitAddIns>
"@
$bootstrapTemplate = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.FurnitureBootstrap\BimBridge.Revit.FurnitureBootstrap.addin.template'
$bootstrapContent = (Get-Content -LiteralPath $bootstrapTemplate -Raw).Replace('{{ASSEMBLY_PATH}}', [Security.SecurityElement]::Escape($bootstrapDll))
$moved = New-Object System.Collections.ArrayList
$deployed = New-Object System.Collections.ArrayList
$child = $null
$ready = $false
$result = $null
$cleanupErrors = New-Object System.Collections.ArrayList
$launchId = [Guid]::NewGuid().ToString('N')
$stdoutLog = Assert-InRoot (Join-Path $runDirectory ($request.sessionId + '.launch.stdout.log')) $runDirectory
$stderrLog = Assert-InRoot (Join-Path $runDirectory ($request.sessionId + '.launch.stderr.log')) $runDirectory
foreach ($log in @($stdoutLog, $stderrLog)) {
    if (Test-Path -LiteralPath $log) { throw "Refusing to overwrite launch log: $log" }
}
try {
    if (@(Get-Process -Name Revit -ErrorAction SilentlyContinue).Count -gt 1) { throw 'Close one Revit instance first: test launch may not exceed two Revit processes.' }
    foreach ($manifest in @(Get-ChildItem -LiteralPath $addinDirectory -Filter '*.addin' -File)) {
        Assert-NoRedirectingLink $manifest.FullName
        $backup = $manifest.FullName + '.disabled.furniture.' + $launchId
        if (Test-Path -LiteralPath $backup) { throw 'Unexpected manifest backup collision.' }
        Move-Item -LiteralPath $manifest.FullName -Destination $backup
        [void]$moved.Add([pscustomobject]@{ original = $manifest.FullName; backup = $backup })
    }
    foreach ($deployment in @(@{ path = $connectorManifest; content = $connectorContent }, @{ path = $bootstrapManifest; content = $bootstrapContent })) {
        if (Test-Path -LiteralPath $deployment.path) { throw "Refusing manifest overwrite: $($deployment.path)" }
        [IO.File]::WriteAllText($deployment.path, $deployment.content, [Text.UTF8Encoding]::new($false))
        [void]$deployed.Add([pscustomobject]@{ path = $deployment.path; content = $deployment.content })
    }
    Assert-NoRedirectingLink $instancesPath
    [IO.Directory]::CreateDirectory($instancesPath) | Out-Null
    if (@(Get-Process -Name Revit -ErrorAction SilentlyContinue).Count -gt 1) { throw 'Revit process budget changed before launch.' }
    # Scope overrides to this launcher's process, restore immediately after spawn;
    # never write persistent user/machine environment or alter unrelated values.
    $previousRequest = [Environment]::GetEnvironmentVariable('BIM_BRIDGE_REVIT_FURNITURE_REQUEST', 'Process')
    $previousInstances = [Environment]::GetEnvironmentVariable('BIM_BRIDGE_INSTANCE_DIR', 'Process')
    $previousWorkspace = [Environment]::GetEnvironmentVariable('BIM_BRIDGE_FAMILY_WORKSPACE', 'Process')
    try {
        $env:BIM_BRIDGE_REVIT_FURNITURE_REQUEST = $requestFile
        $env:BIM_BRIDGE_INSTANCE_DIR = $instancesPath
        # Child-only disposable family lifecycle scope; no installed state changes.
        [Environment]::SetEnvironmentVariable('BIM_BRIDGE_FAMILY_WORKSPACE', $FamilyWorkspace, 'Process')
        $child = Start-Process -FilePath $release.RevitExecutable -WorkingDirectory $runDirectory -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    }
    finally {
        [Environment]::SetEnvironmentVariable('BIM_BRIDGE_REVIT_FURNITURE_REQUEST', $previousRequest, 'Process')
        [Environment]::SetEnvironmentVariable('BIM_BRIDGE_INSTANCE_DIR', $previousInstances, 'Process')
        [Environment]::SetEnvironmentVariable('BIM_BRIDGE_FAMILY_WORKSPACE', $previousWorkspace, 'Process')
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($child.HasExited) { throw "Disposable Revit exited before readiness with code $($child.ExitCode)." }
        Assert-NoRedirectingLink $readyPath
        Assert-NoRedirectingLink $failedPath
        if (Test-Path -LiteralPath $failedPath -PathType Leaf) {
            $failure = Get-Content -LiteralPath $failedPath -Raw | ConvertFrom-Json
            throw "Furniture bootstrap failed: $($failure.message)"
        }
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            $evidence = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
            if ($evidence.processId -ne $child.Id -or $evidence.runId -ne $request.runId -or
                $evidence.sessionId -ne $request.sessionId -or $evidence.version -ne $request.version -or
                -not [string]::Equals([IO.Path]::GetFullPath($evidence.documentPath), $documentPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Readiness report does not match this exact child/session/document.'
            }
            $ready = $true
            $result = [ordered]@{ status = 'ready'; processId = $child.Id; requestPath = $requestFile; readyPath = $readyPath;
                runDirectory = $runDirectory; instanceDirectory = $instancesPath; documentPath = $documentPath;
                revitExecutable = $release.RevitExecutable; signatures = $signatureEvidence;
                stdoutLog = $stdoutLog; stderrLog = $stderrLog }
            break
        }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ready) { throw "Disposable Revit readiness timed out after $TimeoutSeconds seconds." }
}
finally {
    if (-not $ready -and $child -and -not $child.HasExited) {
        try { [void]$child.CloseMainWindow(); if (-not $child.WaitForExit(5000)) { $child.Kill(); [void]$child.WaitForExit(5000) } }
        catch { [void]$cleanupErrors.Add("Could not stop own failed child: $($_.Exception.Message)") }
    }
    foreach ($deployment in $deployed) {
        try {
            Assert-NoRedirectingLink $deployment.path
            if (Test-Path -LiteralPath $deployment.path) {
                if ([IO.File]::ReadAllText($deployment.path) -cne $deployment.content) { throw "Test manifest changed externally; preserving: $($deployment.path)" }
                Remove-Item -LiteralPath $deployment.path
            }
        } catch { [void]$cleanupErrors.Add($_.Exception.Message) }
    }
    foreach ($item in $moved) {
        try {
            Assert-NoRedirectingLink $item.backup
            Assert-NoRedirectingLink $item.original
            if (Test-Path -LiteralPath $item.original) { throw "Refusing restoration overwrite; original preserved at $($item.backup)" }
            Move-Item -LiteralPath $item.backup -Destination $item.original
        } catch { [void]$cleanupErrors.Add($_.Exception.Message) }
    }
    if ($cleanupErrors.Count -gt 0) { throw ('Furniture test cleanup requires attention: ' + ($cleanupErrors -join '; ')) }
}
$result | ConvertTo-Json -Depth 8
