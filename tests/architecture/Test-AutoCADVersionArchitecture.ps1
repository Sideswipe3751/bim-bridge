[CmdletBinding()]
param([switch]$WithoutAutodesk)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$matrixPath = Join-Path $repositoryRoot 'eng\Autodesk.Versions.props'
$matrixHelperPath = Join-Path $repositoryRoot 'eng\AutodeskVersionMatrix.ps1'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.csproj'
$adapterPropertiesPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.Adapter.props'
$buildScriptPath = Join-Path $repositoryRoot 'eng\Build-AutoCADAdapters.ps1'
$liveScriptPath = Join-Path $repositoryRoot 'eng\Run-AutoCADLiveAcceptance.ps1'
$installerPath = Join-Path $repositoryRoot 'installer\Install-BimBridge.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$script:PassedChecks = 0
function Assert-Pass([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:PassedChecks++
}

function Assert-Rejected([string]$Label, [scriptblock]$Action) {
    $message = $null
    try { $null = & $Action } catch { $message = [string]$_.Exception.Message }
    Assert-Pass (-not [string]::IsNullOrWhiteSpace($message)) "Deletion containment accepted '$Label' instead of failing closed."
    $message
}

function Get-PropertyValue([object]$Instance, [string]$Name) {
    # Strict mode turns a missing property read into a terminating error, so
    # optional properties are probed before they are read.
    if ($null -eq $Instance) { return $null }
    $property = $Instance.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    $property.Value
}

function Test-LinkReparsePoint([string]$Path) {
    # The test's own classifier, used by every fixture and cleanup step that runs
    # before the builder guard functions are extracted: it mirrors the classifier
    # in eng/Build-AutoCADAdapters.ps1 (only the junction tag 0xA0000003 and the
    # symbolic-link tag 0xA000000C are escapes; OneDrive placeholders such as
    # 0x9000e01a are benign) and fails closed when the tag cannot be read. The
    # builder guard functions are extracted into this scope further below, so the
    # two implementations are only ever compared by the assertions that name both.
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $output = @(& (Join-Path $env:SystemRoot 'System32\fsutil.exe') reparsepoint query $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { return $true }
    $tagLine = @($output | Where-Object { [string]$_ -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]+)' })[0]
    if (-not $tagLine) { return $true }
    $null = [string]$tagLine -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]+)'
    $tagText = [string]$Matches[1]
    $isLink = $tagText.Equals('a0000003', [StringComparison]::OrdinalIgnoreCase) -or $tagText.Equals('a000000c', [StringComparison]::OrdinalIgnoreCase)
    return [bool]$isLink
}

. $matrixHelperPath
$entries = @(Get-AutoCADMatrixEntries $matrixPath)
$years = @($entries | ForEach-Object { $_.Include })
Assert-True (($years -join ',') -eq '2024,2025,2026,2027') "Unexpected AutoCAD matrix releases: $($years -join ',')"

foreach ($entry in $entries) {
    $year = [string]$entry.Include
    Assert-True ([string]$entry.AssemblyName -eq "BimBridge.AutoCAD$year") "AutoCAD $year has an invalid assembly identity."
    Assert-True (@('netfx','modern') -contains [string]$entry.RuntimeFamily) "AutoCAD $year has an invalid runtime family."
    Assert-True (@('fixed','installed-api-runtime') -contains [string]$entry.RuntimeResolution) "AutoCAD $year has an invalid runtime-resolution policy."
    Assert-True (@('codedom','roslyn') -contains [string]$entry.DynamicCompiler) "AutoCAD $year has an invalid dynamic compiler."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.SupportedTargetFrameworks)) "AutoCAD $year has no supported target frameworks."
    Assert-True ([string]$entry.Series -match '^R\d+\.\d+$') "AutoCAD $year has an invalid bundle series."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.InstallSubdirectory)) "AutoCAD $year has no install subdirectory."
}

$entryByYear = @{}
foreach ($entry in $entries) { $entryByYear[[string]$entry.Include] = $entry }
Assert-True ($entryByYear['2024'].RuntimeFamily -eq 'netfx' -and $entryByYear['2024'].DynamicCompiler -eq 'codedom') 'AutoCAD 2024 must preserve the certified .NET Framework/CodeDOM baseline.'
foreach ($year in @('2025','2026','2027')) {
    Assert-True ($entryByYear[$year].RuntimeFamily -eq 'modern' -and $entryByYear[$year].DynamicCompiler -eq 'roslyn') "AutoCAD $year must use the modern Roslyn runtime family."
    Assert-True ($entryByYear[$year].SupportStatus -eq 'implemented') "AutoCAD $year must be implemented after live certification."
}
Assert-True (@($entries | Where-Object { $_.CertificationStatus -eq 'certified' }).Count -eq 4) 'All four AutoCAD matrix variants must remain certified.'

$project = Get-Content -LiteralPath $projectPath -Raw
$adapterProperties = Get-Content -LiteralPath $adapterPropertiesPath -Raw
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
$liveScript = Get-Content -LiteralPath $liveScriptPath -Raw
$installer = Get-Content -LiteralPath $installerPath -Raw
Assert-True ($project.Contains('BimBridge.AutoCAD.Adapter.props')) 'The shared AutoCAD project must import its adapter properties.'
Assert-True ($adapterProperties.Contains('Autodesk.Versions.props')) 'The AutoCAD adapter must import the single Autodesk matrix.'
Assert-True ($adapterProperties.Contains('Runtime\NetFramework\RuntimeCodeCompiler.cs')) 'The AutoCAD .NET Framework compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Runtime\Modern\RuntimeCodeCompiler.cs')) 'The AutoCAD modern compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Microsoft.CodeAnalysis.CSharp.dll')) 'Modern AutoCAD builds must bind to the exact host-shipped Roslyn compiler.'
Assert-True ($buildScript.Contains('AutodeskVersionMatrix.ps1')) 'The AutoCAD build must use the shared matrix resolver.'
Assert-True ($liveScript.Contains('AutodeskVersionMatrix.ps1')) 'AutoCAD live acceptance must use the shared matrix resolver.'
Assert-True (-not $liveScript.Contains("Version -ne '2024'")) 'AutoCAD live acceptance still hard-codes the 2024 baseline.'
Assert-True ($installer.Contains('Build-AutoCADAdapters.ps1')) 'The installer does not consume the shared AutoCAD build entry point.'
Assert-True ($installer.Contains('New-AutoCADPackageContents')) 'The installer does not generate matrix-scoped AutoCAD bundle components.'

$yearSpecificSources = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Directory |
    Where-Object { $_.Name -match '^BimBridge\.AutoCAD\d{4}$' } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.cs' -Recurse } |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
Assert-True ($yearSpecificSources.Count -eq 0) 'Year-specific AutoCAD business source files are not allowed.'

# The rendered bundle must keep the package identity the shared template owns and
# must declare exactly one component per matrix release. Nothing else asserts
# these two properties, so a template or module-path regression would otherwise
# ship silently.
$templatePath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml'
[xml]$template = Get-Content -LiteralPath $templatePath -Raw
$templateProductCode = [string]$template.ApplicationPackage.ProductCode
Assert-True (-not [string]::IsNullOrWhiteSpace($templateProductCode)) 'The AutoCAD package template has no ApplicationPackage ProductCode.'

$resolvedEntries = @($entries | ForEach-Object { Resolve-AutoCADMatrixEntry $_ })
$rendered = New-AutoCADPackageContents $resolvedEntries '2.0.0' $templatePath 'Contents\Windows'
[xml]$renderedPackage = $rendered
Assert-True ([string]$renderedPackage.ApplicationPackage.ProductCode -eq $templateProductCode) 'The rendered AutoCAD package lost the template ProductCode.'
$renderedComponents = @($renderedPackage.ApplicationPackage.Components)
Assert-True ($renderedComponents.Count -eq $resolvedEntries.Count) "The rendered AutoCAD package declares $($renderedComponents.Count) components for $($resolvedEntries.Count) matrix releases."
foreach ($resolved in $resolvedEntries) {
    $year = [string]$resolved.Include
    $component = @($renderedComponents | Where-Object { [string]$_.Description -eq "AutoCAD $year" })
    Assert-True ($component.Count -eq 1) "The rendered AutoCAD package has no single component for AutoCAD $year."
    Assert-True ([string]$component[0].RuntimeRequirements.SeriesMin -eq [string]$resolved.Series -and
                 [string]$component[0].RuntimeRequirements.SeriesMax -eq [string]$resolved.Series) "AutoCAD $year does not render the matrix bundle series."
    $expectedModule = "./Contents/Windows/$year/$($resolved.AssemblyName).dll"
    Assert-True ([string]$component[0].ComponentEntry.ModuleName -eq $expectedModule) "AutoCAD $year renders '$([string]$component[0].ComponentEntry.ModuleName)' instead of '$expectedModule'."
}

# ---------------------------------------------------------------------------
# Fail-closed deletion containment (eng/Build-AutoCADAdapters.ps1).
#
# Deletion-capable fixtures live under the one containment namespace the builder
# allows: `<repo>\artifacts\staging`, in a run-scoped scratch subdirectory this
# test owns and removes. No candidate below ever names a real drive root, a real
# user profile, the real Autodesk installation directory, or the repository as a
# *deletion* target: those are only handed to the pure guard function, which
# deletes nothing, or to the real builder's validation stage, which refuses
# before any removal. The repository-external tree below only ever holds sentinel
# files that must survive, and is never passed to a removal path.
# ---------------------------------------------------------------------------
# Run-scoped scratch. Every fixture below lives in a directory this run owns
# exclusively (`b-<guid><pid>`), carries an ownership marker, and is validated
# against that marker, its absolute parent and its reparse classification before
# anything is removed. The shared `artifacts\staging` namespace itself is never a
# removal target.
# ---------------------------------------------------------------------------
$stagingNamespace = Join-Path $repositoryRoot 'artifacts\staging'
$scratchGuid = ([guid]::NewGuid()).ToString('N')
$scratchName = "b-$scratchGuid$PID"
$scratchRoot = Join-Path $stagingNamespace $scratchName
$scratchMarkerName = '.ownership.json'
$actorName = if ($env:USERNAME) { [string]$env:USERNAME } else { 'unknown' }

# The workspace is never reset by deleting a fixed path: a stale run's scratch is
# abandoned, not removed (and never removed through a link).
$staleFixedScratch = Join-Path $stagingNamespace 'b-autocad-guard'
Assert-Pass (-not (Test-Path -LiteralPath $staleFixedScratch)) "A fixed-name AutoCAD scratch directory is present at $staleFixedScratch; this test must use a run-scoped scratch instead."

New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $scratchRoot $scratchMarkerName),
    ([ordered]@{
        member = 'B'
        guid = $scratchGuid
        pid = $PID
        actor = $actorName
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        absolutePath = [IO.Path]::GetFullPath($scratchRoot)
    } | ConvertTo-Json -Depth 3),
    [Text.UTF8Encoding]::new($false))

function Get-LegacyScratchReport {
    # Read-only discovery. This function enumerates the scratch directories left in
    # the shared staging namespace by *other* runs, or by a run that was killed, and
    # reports them so an operator can decide. It MUST NOT delete anything and MUST
    # NOT read an ownership marker to authorise a removal: this run cannot make a
    # scan-then-delete sequence for another process's tree race-free, so no
    # cross-run scratch is ever removed here. Only this run's own scratch - a random
    # GUID plus this process id, asserted by its own marker - is removed, by the
    # teardown at the end of this file.
    $legacy = @()
    foreach ($candidate in @(Get-ChildItem -LiteralPath $stagingNamespace -Force -Directory -ErrorAction SilentlyContinue)) {
        if ($candidate.Name -eq $scratchName) { continue }
        if ($candidate.Name -notmatch '^b-[0-9a-f]{32}\d+$') { continue }
        $legacy += [string]$candidate.Name
    }
    [pscustomobject]@{ Legacy = @($legacy) }
}

function Assert-ScratchOwnership([string]$Path) {
    # Fail closed unless this directory is provably this run's own scratch: the
    # name pattern, the exact staging parent, the non-reparse classification of
    # the directory and of every existing parent, and the ownership marker whose
    # member, guid, pid and absolute path match this run.
    Assert-Pass ([IO.Path]::GetFileName($Path) -match '^b-[0-9a-f]{32}\d+$') "Refusing to use a scratch directory whose name is not a run-scoped b-<guid><pid> name: $Path"
    Assert-Pass ((Split-Path -Parent $Path) -eq $stagingNamespace) "Refusing to use a scratch directory outside $stagingNamespace."
    Assert-Pass (-not (Test-LinkReparsePoint $Path)) "Refusing to use the link reparse point at $Path."
    $existingParent = Split-Path -Parent $Path
    while ($existingParent -and (Test-Path -LiteralPath $existingParent)) {
        Assert-Pass (-not (Test-LinkReparsePoint $existingParent)) "Refusing to use the link reparse point at $existingParent."
        $next = Split-Path -Parent $existingParent
        if ([string]::IsNullOrEmpty($next) -or $next -eq $existingParent) { break }
        $existingParent = $next
    }
    # Read-only discovery of other runs' scratch. These are reported and left
    # untouched: no cross-run directory is ever removed by this suite.
    $legacyScratchReport = Get-LegacyScratchReport
    if (@($legacyScratchReport.Legacy).Count -gt 0) {
        Write-Host "NOTE found $(@($legacyScratchReport.Legacy).Count) legacy AutoCAD scratch director$(if (@($legacyScratchReport.Legacy).Count -eq 1) { 'y' } else { 'ies' }) from other runs; reported and left untouched: $(@($legacyScratchReport.Legacy) -join ', ')"
    }
    $markerPath = Join-Path $Path $scratchMarkerName
    Assert-Pass (Test-Path -LiteralPath $markerPath -PathType Leaf) "The ownership marker is missing from the scratch directory $Path."
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    foreach ($pair in @(@('member', 'B'), @('guid', $scratchGuid), @('pid', $PID), @('absolutePath', [IO.Path]::GetFullPath($Path)))) {
        $property = $marker.PSObject.Properties[[string]$pair[0]]
        Assert-Pass ($null -ne $property -and [string]$property.Value -eq [string]$pair[1]) "The ownership marker of $Path does not record $($pair[0]) = $($pair[1])."
    }
}

# Repository-external tree, used only for sentinel fixtures that are never passed
# to a removal path. It is run-scoped as well, so concurrent runs cannot collide
# and no fixed name is ever removed.
$tempRoot = ([IO.Path]::GetTempPath()).TrimEnd('\')
$externalSentinelRoot = Join-Path $tempRoot "bim-bridge-autocad-containment-external-$scratchGuid"
if (Test-Path -LiteralPath $externalSentinelRoot) {
    Assert-Pass (-not (Test-LinkReparsePoint $externalSentinelRoot)) "Refusing to reset the link reparse point at $externalSentinelRoot."
    Remove-Item -LiteralPath $externalSentinelRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $externalSentinelRoot | Out-Null

function Invoke-AutoCADBuilder([string[]]$BuilderArguments) {
    # Same host as the CI architecture step, so the exit-code contract under test
    # is the one CI observes.
    $executable = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScriptPath) + $BuilderArguments
    try {
        $output = & $executable @arguments 2>&1
        $code = $LASTEXITCODE
    } catch {
        # $ErrorActionPreference = 'Stop' turns a redirected terminating error
        # record into an exception; the message is still the real refusal.
        $output = @([string]$_.Exception.Message)
        $code = 1
    }
    [pscustomobject]@{
        text = @($output | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [string]$_.Exception.Message } else { [string]$_ }
        }) -join "`n"
        exitCode = $code
    }
}

# Static guard shape: no Remove-Item may be reachable on a bundle root that the
# guard did not produce, and the separator-terminated prefix form is mandatory.
Assert-Pass ($buildScript -match 'Assert-ContainedStagingDirectory') 'The AutoCAD build has no fail-closed deletion containment guard.'
Assert-Pass ($buildScript -match 'OrdinalIgnoreCase') 'The deletion containment comparison is not ordinal case-insensitive.'
Assert-Pass (-not ($buildScript -match 'StartsWith\(\s*\$prefix\s*\)')) 'A bare StartsWith(prefix) comparison is still present in the AutoCAD build.'
$removeItemLines = @([regex]::Matches($buildScript, '(?m)^\s*Remove(-|\s)Item.*$') | ForEach-Object { $_.Value.Trim() })
Assert-Pass ($removeItemLines.Count -eq 1) "The AutoCAD build must have exactly one uncommented Remove-Item site, found $($removeItemLines.Count)."
Assert-Pass ($removeItemLines[0] -match 'Remove-Item -LiteralPath \$bundleRoot -Recurse -Force') 'The remaining Remove-Item is not the guarded bundle-root deletion.'
$guardIndex = $buildScript.IndexOf('Assert-ContainedStagingDirectory $BundleDirectory')
$removeIndex = $buildScript.IndexOf('Remove-Item -LiteralPath $bundleRoot -Recurse -Force')
Assert-Pass ($guardIndex -ge 0 -and $removeIndex -gt $guardIndex) 'Containment is not verified before the recursive removal.'
$buildInvocationIndex = $buildScript.IndexOf("& dotnet @arguments")
Assert-Pass ($buildInvocationIndex -gt $guardIndex) 'The bundle containment guard runs after the first dotnet build, so an unsafe bundle directory is only rejected after compiling.'

# The vulnerability audit must be opt-in for offline re-verification and must
# never be disabled unconditionally by the builder or by hosted CI.
Assert-Pass ($buildScript -match '(?m)^\s*\[switch\]\$Offline\s*,?\s*$') 'The AutoCAD build has no explicit -Offline switch'
Assert-Pass ($buildScript -match '(?m)^\s*if \(\$Offline\) \{') 'The NuGet audit switch is not conditional on -Offline.'
$offlineConditionalIndex = $buildScript.IndexOf('if ($Offline) {')
Assert-Pass ($offlineConditionalIndex -gt 0) 'The NuGet audit switch is not conditional on -Offline.'
$auditArgumentIndex = $buildScript.IndexOf("'-p:NuGetAudit=false'")
Assert-Pass ($auditArgumentIndex -gt $offlineConditionalIndex) 'The NuGet audit switch is applied outside the -Offline branch.'
$ciPath = Join-Path $repositoryRoot '.github\workflows\ci.yml'
$ciWorkflow = Get-Content -LiteralPath $ciPath -Raw
Assert-Pass (-not ($ciWorkflow -match 'NuGetAudit')) 'Hosted CI still disables the NuGet vulnerability audit.'
Assert-Pass ($ciWorkflow -match '(?m)^\s*dotnet build tests/BimBridge\.Host\.Tests -c Release -f net10\.0 -m:1 -nodeReuse:false\s*$') 'The CI shared-bridge build step lost its serial build switches.'
Assert-Pass ($ciWorkflow -match '(?m)^\s*dotnet run --project tests/BimBridge\.Host\.Tests -c Release -f net10\.0 --no-build\s*$') 'The CI shared-bridge test step lost build-then-run ordering.'
Assert-Pass ($ciWorkflow.IndexOf('dotnet build tests/BimBridge.Host.Tests') -lt $ciWorkflow.IndexOf('dotnet run --project tests/BimBridge.Host.Tests')) 'Hosted CI no longer builds before it runs.'

# Pure-guard scratch tree (never a deletion target).
$guardRoot = Join-Path $scratchRoot 'guard\staging\autocad-bundles'
$guardOutside = Join-Path $scratchRoot 'guard\outside'
if (Test-Path -LiteralPath $guardRoot) {
    $existing = Get-Item -LiteralPath $guardRoot -Force
    Assert-Pass (-not (Test-LinkReparsePoint $guardRoot)) "Stale guard fixture at $guardRoot is a link reparse point; inspect it manually."
    Remove-Item -LiteralPath $guardRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $guardRoot | Out-Null
New-Item -ItemType Directory -Force -Path $guardOutside | Out-Null

# Guard functions are loaded by AST extraction, never by dot-sourcing the whole
# builder: dot-sourcing eng/Build-AutoCADAdapters.ps1 would run its main body
# (a real adapter build plus staging) and leak its param() defaults into this
# test's scope. Only the pure guard definitions below are extracted, together
# with the helper they call, which is the same shape the Revit architecture test
# uses.
$guardFunctionNames = @(
    'Get-DirectorySegment',
    'Test-LinkReparseTag',
    'Get-LinkReparsePointTag',
    'Test-LinkReparsePoint',
    'Get-ExistingAncestorPath',
    'Resolve-CanonicalContainmentRoot',
    'Assert-InContainmentNamespace',
    'Get-SafeStagingRoot',
    'Assert-ContainedStagingDirectory'
)
$buildScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($buildScriptPath, [ref]$null, [ref]$null)
$guardDefinitions = @($buildScriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $guardFunctionNames -contains $node.Name
}, $true) | ForEach-Object { $_.Extent.Text })
Assert-Pass ($guardDefinitions.Count -eq $guardFunctionNames.Count) "Expected $($guardFunctionNames.Count) guard functions in the AutoCAD build script, extracted $($guardDefinitions.Count)."
foreach ($guardFunctionName in $guardFunctionNames) {
    Assert-Pass (@($guardDefinitions | Where-Object { $_ -match "(?m)^function\s+$([regex]::Escape($guardFunctionName))\s*\(" }).Count -eq 1) "The guard function $guardFunctionName could not be extracted from the AutoCAD build script."
}
Invoke-Expression ($guardDefinitions -join "`n")

$allowedPrefix = $guardRoot + '\'
$containedProbe = Join-Path $guardRoot 'bundle'
New-Item -ItemType Directory -Force -Path $containedProbe | Out-Null
Assert-Pass (([string](Assert-ContainedStagingDirectory $containedProbe $guardRoot $repositoryRoot)) -eq $containedProbe) 'A direct child of the staging root must be accepted.'
$mixedCaseProbe = $containedProbe.ToUpperInvariant()
Assert-Pass (([string](Assert-ContainedStagingDirectory $mixedCaseProbe $guardRoot $repositoryRoot)) -eq $containedProbe) 'Casing differences must not defeat containment.'
Assert-Pass ((Get-ExistingAncestorPath $containedProbe) -eq $containedProbe) 'The canonical resolver does not return an existing path unchanged.'

$rejectionLabels = New-Object System.Collections.ArrayList
[void]$rejectionLabels.Add('drive root')
$driveRootMessage = Assert-Rejected 'drive root' { Assert-ContainedStagingDirectory ([IO.Path]::GetPathRoot($guardRoot)) $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('repository root')
$repoRootMessage = Assert-Rejected 'repository root' { Assert-ContainedStagingDirectory $repositoryRoot $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('repository parent')
$parentMessage = Assert-Rejected 'repository parent' { Assert-ContainedStagingDirectory (Split-Path -Parent $repositoryRoot) $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('real user profile')
$profileMessage = Assert-Rejected 'real user profile' { Assert-ContainedStagingDirectory ([Environment]::GetFolderPath('UserProfile')) $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('real AutoCAD installation directory')
$installMessage = Assert-Rejected 'real AutoCAD installation directory' { Assert-ContainedStagingDirectory (Join-Path ${env:ProgramFiles} 'Autodesk\AutoCAD 2024') $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('sibling directory sharing the staging prefix')
$siblingMessage = Assert-Rejected 'sibling prefix' { Assert-ContainedStagingDirectory (Join-Path $scratchRoot 'guard\staging\autocad-bundles-evil') $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('staging root itself')
$rootItselfMessage = Assert-Rejected 'staging root itself' { Assert-ContainedStagingDirectory $guardRoot $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('relative traversal')
$traversalMessage = Assert-Rejected 'relative traversal' { Assert-ContainedStagingDirectory (Join-Path $guardRoot '..\..\..') $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('absolute traversal')
$absoluteTraversalMessage = Assert-Rejected 'absolute traversal' { Assert-ContainedStagingDirectory "$guardRoot\a\..\.." $guardRoot $repositoryRoot }
[void]$rejectionLabels.Add('relative path')
$relativeMessage = Assert-Rejected 'relative path' { Assert-ContainedStagingDirectory 'artifacts\staging\autocad-bundles\x' $guardRoot $repositoryRoot }
# A candidate that does not exist yet is a legitimate first-time staging target:
# nothing is removed, and the returned path is still the contained canonical one.
$missingCandidate = Join-Path $guardRoot 'never-created'
$missingResolved = [string](Assert-ContainedStagingDirectory $missingCandidate $guardRoot $repositoryRoot)
Assert-Pass ($missingResolved -eq $missingCandidate) 'A not-yet-created staging target was not returned unchanged.'
Assert-Pass (-not (Test-Path -LiteralPath $missingCandidate)) 'A not-yet-created staging target was created by the guard.'
foreach ($pair in @(@('drive root', $driveRootMessage), @('repository root', $repoRootMessage), @('repository parent', $parentMessage), @('user profile', $profileMessage), @('installation directory', $installMessage))) {
    Assert-Pass ($pair[1] -match 'outside the repository artifacts staging area' -or $pair[1] -match 'outside the staging root') "Rejection reason for $($pair[0]) is not a containment refusal: $($pair[1])"
}
Assert-Pass ($siblingMessage -match 'outside the staging root') "The separator-terminated prefix comparison did not reject the sibling directory: $siblingMessage"
Assert-Pass ($rootItselfMessage -match 'never removed') "Removing the staging root itself was not refused: $rootItselfMessage"
Assert-Pass ($traversalMessage -match 'traversal') "A relative traversal path was not refused as a traversal: $traversalMessage"
Assert-Pass ($absoluteTraversalMessage -match 'traversal|outside the staging root') "An absolute traversal path was not refused as a traversal or a containment escape: $absoluteTraversalMessage"
Assert-Pass ($relativeMessage -match 'absolute path') "A relative candidate was not refused: $relativeMessage"

# Regression 1 (A1): a *raw* `..` segment is refused before any canonicalisation,
# so `foo\..\bar` can no longer be folded into an accepted path. The refusal is
# matched on its prefix, not with a `-notmatch 'outside the'` probe: this
# repository's own path contains that phrase.
$traversalRefusalPrefix = 'Deletion containment: traversal is never accepted for a deletion target: '
$outsideStagingRefusalPattern = 'is outside the (repository artifacts staging area|staging root)'
$rawTraversalCandidate = "$guardRoot\foo\..\bar"
$rawTraversalMessage = Assert-Rejected 'raw foo\..\bar segment' { Assert-ContainedStagingDirectory $rawTraversalCandidate $guardRoot $repositoryRoot }
Assert-Pass ($rawTraversalMessage.StartsWith($traversalRefusalPrefix, [StringComparison]::Ordinal)) "A raw foo..bar segment was not refused by the pre-canonicalisation traversal check: $rawTraversalMessage"
Assert-Pass (-not ($rawTraversalMessage -match $outsideStagingRefusalPattern)) "A raw foo..bar segment was refused as an out-of-namespace path instead of a traversal: $rawTraversalMessage"

# Regression 2 (A1): a traversal that still *collapses* inside the staging root
# must also be refused, and refused as a traversal rather than as "outside
# staging": `...\x\..\<staging-root-name>` folds back onto the staging root.
# The message prefix also proves it is not the plain "staging root itself" rule.
$collapsingName = [IO.Path]::GetFileName($guardRoot)
$collapsingTraversalCandidate = "$guardRoot\x\..\$collapsingName"
$collapsingTraversalMessage = Assert-Rejected 'traversal collapsing inside the staging root' { Assert-ContainedStagingDirectory $collapsingTraversalCandidate $guardRoot $repositoryRoot }
Assert-Pass ($collapsingTraversalMessage.StartsWith($traversalRefusalPrefix, [StringComparison]::Ordinal)) "A traversal that collapses inside the staging root was not refused by the pre-canonicalisation traversal check: $collapsingTraversalMessage"
Assert-Pass (-not ($collapsingTraversalMessage -match $outsideStagingRefusalPattern)) "A traversal that collapses inside the staging root was refused as an out-of-namespace path instead of a traversal: $collapsingTraversalMessage"
# The prefix is identical for both candidates, which proves that the collapsing
# case never reaches the containment-prefix comparison that would report it as
# merely outside the staging root. The suffix legitimately names the candidate.
Assert-Pass ($collapsingTraversalMessage.Substring($traversalRefusalPrefix.Length) -ceq $collapsingTraversalCandidate) "The collapsing traversal refusal does not name its own candidate: $collapsingTraversalMessage"
Assert-Pass ($rawTraversalMessage.Substring($traversalRefusalPrefix.Length) -ceq $rawTraversalCandidate) "The raw traversal refusal does not name its own candidate: $rawTraversalMessage"

# A reparse point may only be used when the host actually permits creating one.
$junctionPath = Join-Path $guardOutside 'junction-to-staging'
$hasJunction = $false
$junctionMessage = $null
try {
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$junctionPath" "$guardRoot" 2>&1 | Out-Null
    $hasJunction = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $junctionPath)
} catch { $hasJunction = $false }
if ($hasJunction) {
    $junctionMessage = Assert-Rejected 'junction escape' { Assert-ContainedStagingDirectory (Join-Path $junctionPath 'bundle') $guardRoot $repositoryRoot }
    Assert-Pass ($junctionMessage -match 'outside the staging root') "A junction escape was not refused with a containment reason: $junctionMessage"
    $junctionTargetMessage = Assert-Rejected 'junction as the deletion target itself' { Assert-ContainedStagingDirectory $junctionPath $guardRoot $repositoryRoot }
    Assert-Pass ($junctionTargetMessage -match 'outside|reparse point') "A junction deletion target was not refused: $junctionTargetMessage"
    # A junction that *is* lexically inside the staging root must still be refused
    # because it redirects the recursive delete out of that root.
    $containedJunction = Join-Path $guardRoot 'contained-junction'
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$containedJunction" "$guardOutside" 2>&1 | Out-Null
    Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $containedJunction)) 'The host refused to create the contained junction fixture.'
    Assert-Pass ($containedJunction -notlike "$junctionPath*") 'The contained junction fixture does not live inside the staging root.'
    $containedJunctionMessage = Assert-Rejected 'junction inside the staging root' { Assert-ContainedStagingDirectory $containedJunction $guardRoot $repositoryRoot }
    Assert-Pass ($containedJunctionMessage -match 'reparse point') "A junction inside the staging root was not refused as a reparse point: $containedJunctionMessage"
    Assert-Pass (Test-Path -LiteralPath $containedJunction) 'The contained junction fixture disappeared during the pure guard checks.'
    Assert-Pass (Test-Path -LiteralPath $junctionPath) 'The junction escape fixture disappeared during the pure guard checks.'
} else {
    throw 'The host refused to create the junction fixture, so the reparse escape case cannot be proven. See the handoff notes; this is not skipped silently.'
}
Assert-Pass ((Get-DirectorySegment $guardRoot).Count -gt 1) 'Internal segment helper regression.'

# ---------------------------------------------------------------------------
# Execution-shape tests: positive cleanup inside staging, and "no deletion ever
# happens before validation" proven with sentinel files that must survive.
# ---------------------------------------------------------------------------
$sentinelDirectory = Join-Path $scratchRoot 'sentinel'
if (Test-Path -LiteralPath $sentinelDirectory) { Remove-Item -LiteralPath $sentinelDirectory -Recurse -Force }
New-Item -ItemType Directory -Force -Path $sentinelDirectory | Out-Null

$stagingSentinel = Join-Path $scratchRoot 'staging\sentinel-sibling.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stagingSentinel) | Out-Null
Set-Content -LiteralPath $stagingSentinel -Value 'sibling sentinel must survive' -Encoding ASCII
$stagingSentinelHash = (Get-FileHash -LiteralPath $stagingSentinel -Algorithm SHA256).Hash

$containedTarget = Join-Path $scratchRoot 'staging\contained-bundle'
if (Test-Path -LiteralPath $containedTarget) { Remove-Item -LiteralPath $containedTarget -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $containedTarget 'Contents\Windows\2024') | Out-Null
Set-Content -LiteralPath (Join-Path $containedTarget 'Contents\Windows\2024\stale.dll') -Value 'stale product' -Encoding ASCII
$containedCanonical = Assert-ContainedStagingDirectory $containedTarget (Join-Path $scratchRoot 'staging') $repositoryRoot
Assert-Pass ($containedCanonical -eq $containedTarget) 'A contained staging directory was not accepted for cleanup.'
Remove-Item -LiteralPath $containedCanonical -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $containedTarget)) 'Positive case: the staging directory still holds its own stale product after cleanup.'
Assert-Pass (Test-Path -LiteralPath $stagingSentinel) 'Positive case: the sibling sentinel next to the staging directory was removed.'
Assert-Pass ((Get-FileHash -LiteralPath $stagingSentinel -Algorithm SHA256).Hash -eq $stagingSentinelHash) 'Positive case: the sibling sentinel content changed.'
Assert-Pass (Test-Path -LiteralPath $guardRoot) 'Positive case: cleanup escaped its own staging directory.'

$escapeJunction = Join-Path $sentinelDirectory 'junction-escape'
$escapedContent = Join-Path $sentinelDirectory 'escaped-content'
New-Item -ItemType Directory -Force -Path $escapedContent | Out-Null
Set-Content -LiteralPath (Join-Path $escapedContent 'escape-witness.txt') -Value 'must not be removed' -Encoding ASCII
$escapeJunctionReady = $false
try {
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$escapeJunction" "$escapedContent" 2>&1 | Out-Null
    $escapeJunctionReady = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $escapeJunction)
} catch { $escapeJunctionReady = $false }
Assert-Pass $escapeJunctionReady 'The host refused to create the reparse-point escape fixture.'

# This is the exact production sequence: validate, and only then remove. The
# staging root is a parameter because each fixture below owns its own root.
function Invoke-GuardedBundleRemoval([string]$Candidate, [string]$RemovalStagingRoot = (Join-Path $scratchRoot 'staging')) {
    $canonical = Assert-ContainedStagingDirectory $Candidate $RemovalStagingRoot $repositoryRoot
    if (Test-Path -LiteralPath $canonical) { Remove-Item -LiteralPath $canonical -Recurse -Force }
    $canonical
}

$outsideControlledSentinel = Join-Path $externalSentinelRoot 'outside-controlled\outside-sentinel.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outsideControlledSentinel) | Out-Null
Set-Content -LiteralPath $outsideControlledSentinel -Value 'outside controlled sentinel' -Encoding ASCII
Assert-Pass (-not $outsideControlledSentinel.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The repository-external sentinel is not actually outside the repository.'

$escapeCases = @(
    @{ label = 'outside-controlled repository-external directory'; candidate = (Join-Path $sentinelDirectory 'outside-controlled'); sentinel = $outsideControlledSentinel },
    @{ label = 'repository root'; candidate = $repositoryRoot; sentinel = $outsideControlledSentinel },
    @{ label = 'repository parent'; candidate = (Split-Path -Parent $repositoryRoot); sentinel = $outsideControlledSentinel },
    @{ label = 'traversal path'; candidate = (Join-Path $scratchRoot 'staging\..\..\..'); sentinel = $outsideControlledSentinel },
    @{ label = 'reparse point escape'; candidate = (Join-Path $escapeJunction 'Contents'); sentinel = (Join-Path $escapedContent 'escape-witness.txt') }
)
foreach ($case in $escapeCases) {
    $message = $null
    try { $null = Invoke-GuardedBundleRemoval $case.candidate } catch { $message = [string]$_.Exception.Message }
    Assert-Pass (-not [string]::IsNullOrWhiteSpace($message)) "Guarded removal accepted the $($case.label) instead of refusing it."
    Assert-Pass (Test-Path -LiteralPath $case.sentinel) "The sentinel for the $($case.label) was deleted, so a removal ran before validation."
    Assert-Pass (-not [string]::IsNullOrWhiteSpace((Get-FileHash -LiteralPath $case.sentinel -Algorithm SHA256).Hash)) "The sentinel for the $($case.label) is unreadable."
}
Assert-Pass (Test-Path -LiteralPath $outsideControlledSentinel) 'The repository-external controlled sentinel was removed.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $escapedContent 'escape-witness.txt')) 'The reparse-point target witness was removed.'
Assert-Pass (Test-Path -LiteralPath $escapeJunction) 'The reparse-point fixture was removed.'

# ---------------------------------------------------------------------------
# Intermediate-segment junction (A2), execution shape: the junction sits between
# the repository artifacts staging namespace and the staging root, so classifying
# only the final staging-root item is not enough. The junction points at a
# controlled directory inside the system temp root, which holds a witness that
# must still exist after the refusal, and the removal path is the exact
# production sequence (validate, and only then remove).
# ---------------------------------------------------------------------------
$intermediateJunctionParent = Join-Path $scratchRoot 'intermediate-junction'
$intermediateJunctionTarget = Join-Path $tempRoot "bim-bridge-autocad-junction-target-$scratchGuid"
$intermediateJunctionName = "junction-$scratchGuid"
$intermediateJunctionPath = Join-Path $intermediateJunctionParent $intermediateJunctionName
$intermediateJunctionStagingRoot = Join-Path $intermediateJunctionPath 'autocad-bundles'
$intermediateJunctionBundle = Join-Path $intermediateJunctionStagingRoot 'bundle'
$intermediateWitness = Join-Path $intermediateJunctionTarget 'junction-target-witness.txt'
New-Item -ItemType Directory -Force -Path $intermediateJunctionParent | Out-Null
New-Item -ItemType Directory -Force -Path $intermediateJunctionTarget | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $intermediateJunctionTarget 'autocad-bundles\bundle') | Out-Null
Set-Content -LiteralPath $intermediateWitness -Value 'must not be removed' -Encoding ASCII
$intermediateJunctionWitnessHash = (Get-FileHash -LiteralPath $intermediateWitness -Algorithm SHA256).Hash
Assert-Pass (-not $intermediateJunctionTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The intermediate-junction target is not actually outside the repository.'
$intermediateJunctionReady = $false
try {
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$intermediateJunctionPath" "$intermediateJunctionTarget" 2>&1 | Out-Null
    $intermediateJunctionReady = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $intermediateJunctionPath)
} catch { $intermediateJunctionReady = $false }
Assert-Pass $intermediateJunctionReady "The host refused to create the intermediate junction fixture at $intermediateJunctionPath."
Assert-Pass ($intermediateJunctionStagingRoot.StartsWith($repositoryRoot + '\artifacts\staging\', [StringComparison]::OrdinalIgnoreCase)) 'The intermediate-junction staging root is not lexically inside the repository artifacts staging namespace.'
$intermediateJunctionMessage = $null
try { $null = Invoke-GuardedBundleRemoval $intermediateJunctionBundle $intermediateJunctionStagingRoot } catch { $intermediateJunctionMessage = [string]$_.Exception.Message }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($intermediateJunctionMessage)) 'A staging root behind an intermediate junction was accepted instead of failing closed.'
Assert-Pass ($intermediateJunctionMessage -match 'reparse point') "The intermediate junction was not refused as a reparse point: $intermediateJunctionMessage"
# The exact phrase below only exists on the intermediate-segment walk, so this
# proves the junction was caught between the containment root and the staging
# root rather than as the final staging-root item.
Assert-Pass ($intermediateJunctionMessage.Contains('is a reparse point (junction or symbolic link) between the repository artifacts staging area and the staging root')) "The intermediate junction was refused by something other than the intermediate-segment walk: $intermediateJunctionMessage"
Assert-Pass ($intermediateJunctionMessage.Contains($intermediateJunctionPath)) "The intermediate-junction refusal does not name the offending junction '$intermediateJunctionPath': $intermediateJunctionMessage"
Assert-Pass (Test-Path -LiteralPath $intermediateJunctionPath) 'The intermediate junction fixture disappeared during the refusal.'
Assert-Pass (Test-Path -LiteralPath $intermediateWitness) 'The intermediate-junction target witness was removed by the guard.'
Assert-Pass ((Get-FileHash -LiteralPath $intermediateWitness -Algorithm SHA256).Hash -eq $intermediateJunctionWitnessHash) 'The intermediate-junction target witness content changed.'
Assert-Pass (Test-Path -LiteralPath $outsideControlledSentinel) 'The intermediate-junction refusal reached the repository-external sentinel.'
Assert-Pass (Test-Path -LiteralPath $stagingSentinel) 'The intermediate-junction refusal reached the staging sibling sentinel.'

# ---------------------------------------------------------------------------
# P0-A execution: the containment chain from the repository root to the
# containment root (and the containment root itself) must be link-free. This
# repository lives inside an OneDrive-synced tree, where the repository root and
# `artifacts` carry the *cloud* reparse tag 0x9000e01a and a host may even report
# the reparse attribute where fsutil answers "not a reparse point". Both are
# benign and must keep working, so the live chain is measured before it is
# asserted: a host that refuses the tag read fails its own `Test-LinkReparsePoint`
# first, which means the guard never had to trust an unreadable tag.
# ---------------------------------------------------------------------------
$chainReparseFindings = New-Object System.Collections.ArrayList
$cloudProbePath = [IO.Path]::GetFullPath($repositoryRoot)
while ($cloudProbePath -and (Test-Path -LiteralPath $cloudProbePath)) {
    $probeItem = Get-Item -LiteralPath $cloudProbePath -Force -ErrorAction SilentlyContinue
    if ($probeItem -and ($probeItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        [void]$chainReparseFindings.Add([pscustomobject]@{
            path = $cloudProbePath
            link = Test-LinkReparsePoint $cloudProbePath
        })
    }
    $nextProbe = [IO.Path]::GetDirectoryName($cloudProbePath)
    if ([string]::IsNullOrEmpty($nextProbe) -or $nextProbe -eq $cloudProbePath) { break }
    $cloudProbePath = $nextProbe
}
$cloudTaggedPaths = @($chainReparseFindings | Where-Object { Test-LinkReparsePoint $_.path })
Assert-Pass ($cloudTaggedPaths.Count -eq 0) "The repository chain contains a link reparse point, so it is not a clean tree: $(($cloudTaggedPaths | ForEach-Object { $_.path }) -join '; ')"
# Both entry points must still accept the real repository chain before anything
# else runs, which is the primary cloud-tag false-positive guard.
$liveContainmentRoot = Join-Path $repositoryRoot 'artifacts\staging'
$liveStagingRoot = Join-Path $liveContainmentRoot 'autocad-bundles'
Assert-Pass (([string](Get-SafeStagingRoot $liveStagingRoot $liveContainmentRoot)) -eq $liveStagingRoot) 'A benign cloud reparse point on the repository chain made the staging root unusable.'
$liveChainMessage = $null
try { $null = Assert-ContainedStagingDirectory (Join-Path $liveStagingRoot 'bundle-chain-acceptance') $liveStagingRoot $repositoryRoot } catch { $liveChainMessage = [string]$_.Exception.Message }
Assert-Pass ([string]::IsNullOrWhiteSpace($liveChainMessage)) "The new containment-chain walk refused a clean repository chain: $liveChainMessage"

# The tag classifier is exercised directly with a controlled tag matrix, because
# cloud placeholders cannot be created on demand. Only the two link tags are
# escapes; longer, shorter, missing and unrelated tags all fail closed.
$cloudTagProbe = @{
    name = 'cloud placeholder tag'
    tag = '9000e01a'
    action = { [bool](Test-LinkReparseTag $cloudTagProbe.tag) }
}
$cloudTagMessage = $null
try { $null = & $cloudTagProbe.action } catch { $cloudTagMessage = [string]$_.Exception.Message }
Assert-Pass ([string]::IsNullOrWhiteSpace($cloudTagMessage)) "The cloud placeholder tag 0x9000e01a was refused or misclassified: $cloudTagMessage"
Assert-Pass ((& $cloudTagProbe.action) -eq $false) 'The cloud placeholder tag 0x9000e01a was classified as a link escape.'
foreach ($pair in @(@('junction tag 0xa0000003', 'a0000003', $true), @('mount point tag 0xa0000003 (upper case)', 'A0000003', $true), @('symbolic link tag 0xa000000c', 'a000000c', $true), @('cloud placeholder tag 0x9000e01a', '9000e01a', $false), @('cloud placeholder tag 0x9000e01b', '9000e01b', $false), @('unrelated tag 0x80000017', '80000017', $false))) {
    Assert-Pass ((Test-LinkReparseTag $pair[1]) -eq [bool]$pair[2]) "The reparse tag classifier misclassified '$($pair[0])'."
}
foreach ($pair in @(@('empty tag', ''), @('whitespace tag', '   '), @('too short tag', 'a000000'), @('too long tag', 'a00000031'), @('non-hexadecimal tag', 'zzzzzzzz'))) {
    $tagRefusal = Assert-Rejected $pair[0] { Test-LinkReparseTag $pair[1] }
    Assert-Pass ($tagRefusal -match 'Deletion containment') "The $($pair[0]) was refused without a containment reason: $tagRefusal"
}

# ---------------------------------------------------------------------------
# P0-B execution: after the preflight accepted a real bundle directory, replacing
# it with a controlled junction must make the re-check refuse before any removal
# and leave the external witness, its SHA256 and the pointed-at tree untouched.
# The re-check below is the exact production call the builder runs immediately
# before Remove-Item, driven from a controlled TEMP/GUID scratch only.
# ---------------------------------------------------------------------------
$bundleSwapRoot = Join-Path $scratchRoot 'bundle-swap-root'
$bundleSwapTarget = Join-Path $tempRoot "bim-bridge-autocad-bundle-swap-$scratchGuid"
$swapBundle = Join-Path $bundleSwapRoot 'bundle'
$swapWitness = Join-Path $bundleSwapTarget 'bundle-witness.txt'
New-Item -ItemType Directory -Force -Path (Join-Path $swapBundle 'Contents\Windows\2024') | Out-Null
Set-Content -LiteralPath (Join-Path $swapBundle 'Contents\Windows\2024\stale.dll') -Value 'stale product' -Encoding ASCII
New-Item -ItemType Directory -Force -Path (Join-Path $bundleSwapTarget 'bundle\Contents\Windows\2024') | Out-Null
Set-Content -LiteralPath $swapWitness -Value 'bundle swap witness must survive' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $bundleSwapTarget 'bundle\Contents\Windows\2024\must-not-be-removed.dll') -Value 'external target content' -Encoding ASCII
$swapTargetFileCount = @(Get-ChildItem -LiteralPath $bundleSwapTarget -Recurse -File -Force).Count
$swapWitnessHashBefore = (Get-FileHash -LiteralPath $swapWitness -Algorithm SHA256).Hash
Assert-Pass (-not $bundleSwapTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The bundle-swap witness target is not actually outside the repository.'
$preflightCanonical = [string](Assert-ContainedStagingDirectory $swapBundle $bundleSwapRoot $repositoryRoot)
Assert-Pass ($preflightCanonical -eq $swapBundle) 'The bundle-swap fixture was not accepted by the preflight before it was replaced.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $swapBundle 'Contents\Windows\2024\stale.dll')) 'The bundle-swap fixture has no stale product to replace.'
Assert-Pass ($bundleSwapTarget -notlike "$scratchRoot*") 'The bundle-swap junction target must live outside the run scratch.'
Assert-Pass (Test-Path -LiteralPath $bundleSwapRoot) 'The bundle-swap staging root fixture is missing before the swap.'
Assert-Pass (-not (Test-LinkReparsePoint $bundleSwapRoot)) 'The bundle-swap staging root fixture is already a link reparse point.'
Remove-Item -LiteralPath $swapBundle -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $swapBundle)) 'The bundle-swap fixture directory survived its own controlled replacement.'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$swapBundle" "$bundleSwapTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $swapBundle)) "The host refused to create the bundle-swap junction fixture at $swapBundle."
# This is the exact production statement, invoked with the values the build would
# carry into the removal: the guard runs first and its result is the only path the
# removal is allowed to use. The two variables deliberately carry the production
# names so the statement below is a literal copy of the builder's removal gate.
$swapRecheckCanonical = $null
$swapRecheckMessage = $null
$StagingRoot = $bundleSwapRoot
$bundleRoot = $swapBundle
try { $swapRecheckCanonical = Assert-ContainedStagingDirectory $bundleRoot $StagingRoot $repositoryRoot } catch { $swapRecheckMessage = [string]$_.Exception.Message }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($swapRecheckMessage)) 'The pre-removal re-check accepted a bundle directory that was replaced by a junction after the preflight.'
Assert-Pass ($swapRecheckMessage -match 'reparse point|outside the staging root|resolves outside') "The swapped bundle directory was refused without a containment reason: $swapRecheckMessage"
Assert-Pass ($null -eq $swapRecheckCanonical) 'The pre-removal re-check returned a canonical path for a rejected bundle directory.'
Assert-Pass (Test-Path -LiteralPath $swapWitness) 'The swapped bundle directory re-check removed the external witness file.'
Assert-Pass ((Get-FileHash -LiteralPath $swapWitness -Algorithm SHA256).Hash -eq $swapWitnessHashBefore) 'The swapped bundle directory re-check changed the external witness content.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleSwapTarget 'bundle\Contents\Windows\2024\must-not-be-removed.dll')) 'The swapped bundle directory re-check deleted content through the junction.'
Assert-Pass (@(Get-ChildItem -LiteralPath $bundleSwapTarget -Recurse -File -Force).Count -eq $swapTargetFileCount) 'The swapped bundle directory re-check changed the external target file count.'
Assert-Pass (Test-LinkReparsePoint $swapBundle) 'The bundle-swap junction itself disappeared during the re-check, so the refusal cannot be attributed to it.'
$swapJunctionMessage = Assert-Rejected 'bundle directory replaced by a junction before removal' { Assert-ContainedStagingDirectory $bundleRoot $StagingRoot $repositoryRoot }
Assert-Pass ($swapJunctionMessage.Contains($swapBundle)) "The swapped bundle directory refusal does not name the junction '$swapBundle': $swapJunctionMessage"

# ---------------------------------------------------------------------------
# P0-A execution: controlled repository shapes. The gap being closed is the chain
# *above* the staging root, so the fixtures isolate the two segments the previous
# walk never classified: `artifacts` and the containment root (`artifacts\staging`).
# The containment root is derived as `<repository root>\artifacts\staging`, so each
# fake repository is placed directly under the run's own TEMP umbrella and is
# therefore anchored exactly like the real one; a fixture nested inside the real
# `artifacts\staging` would not be a valid repository root for this guard at all.
# Both the fake repositories and the junction targets live in that one umbrella, so
# a failed run leaves a single run-scoped directory behind instead of several
# fixed-prefix ones. Each shape is separate, so the fixture that plants the
# `artifacts` junction is never the same path this test then has to reset. Both
# must be refused by the containment-chain walk, with the external witness intact
# and unmodified. No real user or installation directory is ever a deletion target.
# ---------------------------------------------------------------------------
$chainUmbrella = Join-Path $tempRoot "bim-bridge-autocad-chain-$scratchGuid"
$chainArtifactsRepository = Join-Path $chainUmbrella 'artifacts-level-repo'
$chainContainmentRepository = Join-Path $chainUmbrella 'containment-level-repo'
$chainJunctionTarget = Join-Path $chainUmbrella 'junction-target'
$chainArtifactsTarget = Join-Path $chainUmbrella 'artifacts-target'
$chainWitness = Join-Path $chainJunctionTarget 'containment-root-witness.txt'
New-Item -ItemType Directory -Force -Path $chainArtifactsRepository | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainContainmentRepository 'artifacts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainJunctionTarget 'staging\autocad-bundles') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainArtifactsTarget 'staging\autocad-bundles') | Out-Null
Set-Content -LiteralPath $chainWitness -Value 'containment root witness must survive' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $chainArtifactsTarget 'staging\autocad-bundles\artifacts-level.dll') -Value 'artifacts level content' -Encoding ASCII
$chainWitnessHash = (Get-FileHash -LiteralPath $chainWitness -Algorithm SHA256).Hash
$chainTargetFileCount = @(Get-ChildItem -LiteralPath $chainJunctionTarget -Recurse -File -Force).Count
$chainArtifactsTargetFileCount = @(Get-ChildItem -LiteralPath $chainArtifactsTarget -Recurse -File -Force).Count
Assert-Pass ((Split-Path -Parent $chainUmbrella) -eq $tempRoot) "The containment-chain umbrella is not a direct child of the system temp root."
Assert-Pass (-not $chainUmbrella.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-chain umbrella is not actually outside the repository.'
Assert-Pass (-not $chainArtifactsRepository.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The artifacts-level fake repository is not actually outside the repository.'
Assert-Pass (-not $chainContainmentRepository.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-level fake repository is not actually outside the repository.'
Assert-Pass (-not $chainJunctionTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-chain junction target is not actually outside the repository.'
Assert-Pass (-not $chainArtifactsTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The artifacts-level junction target is not actually outside the repository.'

# Case A: the junction sits at `artifacts`, one level above the containment root,
# and the only directory that exists below it is behind the junction.
$chainArtifactsJunction = Join-Path $chainArtifactsRepository 'artifacts'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$chainArtifactsJunction" "$chainArtifactsTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $chainArtifactsJunction)) "The host refused to create the artifacts-level junction fixture at $chainArtifactsJunction."
Assert-Pass (Test-LinkReparsePoint $chainArtifactsJunction) 'The artifacts-level junction fixture is not classified as a link reparse point.'
$chainIntermediateStagingRoot = Join-Path $chainArtifactsJunction 'staging\autocad-bundles'
$chainIntermediateBundle = Join-Path $chainIntermediateStagingRoot 'bundle'
$chainIntermediateMessage = $null
try { $null = Assert-ContainedStagingDirectory $chainIntermediateBundle $chainIntermediateStagingRoot $chainArtifactsRepository } catch { $chainIntermediateMessage = [string]$_.Exception.Message }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($chainIntermediateMessage)) 'A junction at the artifacts level of the containment chain was accepted instead of failing closed.'
Assert-Pass ($chainIntermediateMessage -match 'is a reparse point \(junction or symbolic link\) on the path from the repository root to the containment root') "The artifacts-level junction was refused by something other than the containment-chain walk: $chainIntermediateMessage"
Assert-Pass ($chainIntermediateMessage.Contains($chainArtifactsJunction)) "The artifacts-level refusal does not name the offending junction '$chainArtifactsJunction': $chainIntermediateMessage"
Assert-Pass (-not (Test-Path -LiteralPath $chainIntermediateBundle)) 'The artifacts-level refusal created the bundle directory it refused to stage.'
Assert-Pass (@(Get-ChildItem -LiteralPath $chainArtifactsTarget -Recurse -File -Force).Count -eq $chainArtifactsTargetFileCount) 'The artifacts-level refusal changed the external target file count.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $chainArtifactsTarget 'staging\autocad-bundles')) 'The artifacts-level refusal removed the junction target content.'
Assert-Pass (-not ($chainIntermediateMessage -match 'between the repository artifacts staging area and the staging root')) "The artifacts-level junction was still classified by the older staging-root walk: $chainIntermediateMessage"

# Case B: the junction *is* the containment root (`artifacts\staging`), inside a
# real `artifacts` directory, which is the segment the previous walk never
# classified at all.
$chainContainmentJunction = Join-Path $chainContainmentRepository 'artifacts\staging'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$chainContainmentJunction" "$chainJunctionTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $chainContainmentJunction)) "The host refused to create the containment-root junction fixture at $chainContainmentJunction."
Assert-Pass (Test-LinkReparsePoint $chainContainmentJunction) 'The containment-root junction fixture is not classified as a link reparse point.'
$chainContainmentStagingRoot = Join-Path $chainContainmentJunction 'autocad-bundles'
$chainContainmentBundle = Join-Path $chainContainmentStagingRoot 'bundle'
$chainContainmentMessage = $null
try { $null = Assert-ContainedStagingDirectory $chainContainmentBundle $chainContainmentStagingRoot $chainContainmentRepository } catch { $chainContainmentMessage = [string]$_.Exception.Message }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($chainContainmentMessage)) 'A junction *as* the containment root was accepted instead of failing closed.'
Assert-Pass ($chainContainmentMessage -match 'is a reparse point \(junction or symbolic link\) on the path from the repository root to the containment root') "The containment-root junction was refused by something other than the containment-chain walk: $chainContainmentMessage"
Assert-Pass ($chainContainmentMessage.Contains($chainContainmentJunction)) "The containment-root refusal does not name the offending junction '$chainContainmentJunction': $chainContainmentMessage"
Assert-Pass (-not ($chainContainmentMessage -match 'outside the (repository artifacts staging area|staging root)')) "The containment-root junction was lexically rejected as an outside path instead of being classified as a link: $chainContainmentMessage"
Assert-Pass (-not (Test-Path -LiteralPath $chainContainmentBundle)) 'The containment-root refusal created the bundle directory it refused to stage.'
Assert-Pass (Test-Path -LiteralPath $chainContainmentJunction) 'The containment-root junction fixture disappeared during the refusal.'
Assert-Pass (Test-Path -LiteralPath $chainWitness) 'The containment-chain refusal removed the external witness file.'
Assert-Pass ((Get-FileHash -LiteralPath $chainWitness -Algorithm SHA256).Hash -eq $chainWitnessHash) 'The containment-chain refusal changed the external witness content.'
Assert-Pass (@(Get-ChildItem -LiteralPath $chainJunctionTarget -Recurse -File -Force).Count -eq $chainTargetFileCount) 'The containment-chain refusal changed the external target file count.'

# Positive control: the identical repository shape without the junction stays usable.
$chainRealRepository = Join-Path $chainUmbrella 'real-repo'
$chainRealStagingRoot = Join-Path $chainRealRepository 'artifacts\staging\autocad-bundles'
New-Item -ItemType Directory -Force -Path $chainRealStagingRoot | Out-Null
Assert-Pass (-not (Test-LinkReparsePoint $chainRealRepository)) 'The positive-control repository root is a link reparse point.'
Assert-Pass (-not (Test-LinkReparsePoint (Join-Path $chainRealRepository 'artifacts'))) 'The positive-control artifacts directory is a link reparse point.'
$chainAccepted = [string](Assert-ContainedStagingDirectory (Join-Path $chainRealStagingRoot 'bundle') $chainRealStagingRoot $chainRealRepository)
Assert-Pass ($chainAccepted -eq (Join-Path $chainRealStagingRoot 'bundle')) 'The containment-chain walk refused a real (junction-free) repository shape.'
$chainMissingStagingRoot = Join-Path $chainRealRepository 'artifacts\staging\not-yet-created'
$chainRealAccepted = [string](Get-SafeStagingRoot $chainMissingStagingRoot (Join-Path $chainRealRepository 'artifacts\staging'))
Assert-Pass ($chainRealAccepted -eq $chainMissingStagingRoot) 'The containment-chain walk refused a real containment root that does not exist yet.'

# The walk must classify the anchored repository root *itself*, not only the
# segments appended after it. A repository root that is a junction redirects the
# whole containment namespace, so it must be refused before any write or delete.
# ---------------------------------------------------------------------------
$repoRootGuid = ([guid]::NewGuid()).ToString('N')
$repoRootUmbrella = Join-Path $tempRoot "bim-bridge-autocad-reporoot-$repoRootGuid"
$repoRootTarget = Join-Path $repoRootUmbrella 'junction-target'
$repoRootHolder = Join-Path $repoRootUmbrella 'holder'
New-Item -ItemType Directory -Force -Path $repoRootTarget | Out-Null
New-Item -ItemType Directory -Force -Path $repoRootHolder | Out-Null
$repoRootWitness = Join-Path $repoRootTarget 'repo-root-witness.txt'
Set-Content -LiteralPath $repoRootWitness -Value 'repository-root witness must survive' -Encoding ASCII
$repoRootWitnessHash = (Get-FileHash -LiteralPath $repoRootWitness -Algorithm SHA256).Hash
$repoRootJunction = Join-Path $repoRootHolder 'fakerepo'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$repoRootJunction" "$repoRootTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $repoRootJunction)) "The host refused to create the repository-root junction fixture at $repoRootJunction."
Assert-Pass (Test-LinkReparsePoint $repoRootJunction) 'The repository-root junction fixture is not classified as a link reparse point.'
$repoRootContainment = Join-Path $repoRootJunction 'artifacts\staging'
$repoRootMessage = Assert-Rejected 'repository root is a junction' { Get-SafeStagingRoot (Join-Path $repoRootContainment 'autocad-bundles') $repoRootContainment }
Assert-Pass ($repoRootMessage -match 'on the path from the repository root to the containment root') "A junction as the repository root was refused by something other than the containment-chain walk: $repoRootMessage"
Assert-Pass ($repoRootMessage.Contains($repoRootJunction)) "The refusal does not name the offending repository root '$repoRootJunction': $repoRootMessage"
Assert-Pass (Test-Path -LiteralPath $repoRootWitness) 'The repository-root refusal removed the external witness file.'
Assert-Pass ((Get-FileHash -LiteralPath $repoRootWitness -Algorithm SHA256).Hash -eq $repoRootWitnessHash) 'The repository-root refusal changed the external witness content.'
Assert-Pass (-not (Test-Path -LiteralPath (Join-Path $repoRootTarget 'artifacts'))) 'The repository-root refusal created the containment namespace through the junction.'
# The checkout may be a plain directory or a benign cloud placeholder.
Assert-Pass (-not (Test-LinkReparsePoint $repositoryRoot)) 'The repository root was classified as a link reparse point.'
$liveRepoRootAccepted = $null
try { $liveRepoRootAccepted = [string](Get-SafeStagingRoot (Join-Path $stagingNamespace 'not-yet-created') $stagingNamespace) } catch { $liveRepoRootAccepted = $null }
Assert-Pass ($liveRepoRootAccepted -eq (Join-Path $stagingNamespace 'not-yet-created')) 'The containment-chain walk refused the working-copy repository root.'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c rmdir "$repoRootJunction" 2>&1 | Out-Null
Assert-Pass (-not (Test-Path -LiteralPath $repoRootJunction)) 'The repository-root junction fixture could not be de-linked.'
Assert-Pass (-not (Test-LinkReparsePoint $repoRootTarget)) 'Refusing to clean the repository-root fixture at a link reparse point.'
Remove-Item -LiteralPath $repoRootUmbrella -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $repoRootUmbrella)) 'The repository-root fixture survived its teardown.'

# An unreadable reparse tag must fail closed. The refusal is proven against the
# builder's own tag reader with a path that provably cannot be queried, so the
# fail-closed message comes from eng/Build-AutoCADAdapters.ps1 itself rather than
# from an injected stub. The builder classifier is only adopted where it runs: the
# guard functions are extracted into this scope, while the test's own classifier
# copy stays available for every fixture that runs before that extraction.
$unreadableCandidate = Join-Path $tempRoot "bim-bridge-autocad-missing-$scratchGuid"
Assert-Pass (-not (Test-Path -LiteralPath $unreadableCandidate)) 'The unreadable-tag fixture already exists, so it cannot prove a missing target.'
$unreadableProbeMessage = Assert-Rejected 'unreadable reparse tag' { $null = Get-LinkReparsePointTag $unreadableCandidate }
Assert-Pass ($unreadableProbeMessage -match 'could not be read') "A tag that cannot be read was not refused as unreadable: $unreadableProbeMessage"
$unreadableMessage = Assert-Rejected 'unreadable reparse tag through the classifier' { $null = Test-LinkReparsePoint $unreadableCandidate }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($unreadableMessage)) 'The classifier treated an unqueryable path as a benign target.'
Assert-Pass ([bool](Test-Path -LiteralPath $unreadableCandidate) -eq $false) 'The unreadable-tag fixture was created during the refusal, so nothing was proven.'
Assert-Pass ([bool](Test-LinkReparsePoint $repositoryRoot) -eq $false) 'The repository root stopped being accepted after the unreadable-tag refusal.'

# The real builder must refuse an unsafe bundle directory before it builds
# anything, so a rejection cannot be masked by a later build failure.
$unsafeRun = Invoke-AutoCADBuilder @('-Version', '2024', '-Configuration', 'Release', '-BundleDirectory', (Split-Path -Parent $outsideControlledSentinel))
Assert-Pass ($unsafeRun.exitCode -ne 0) 'The real builder accepted a repository-external bundle directory.'
# The refusal is asserted on evidence that survives host output wrapping: the
# exit code, the containment message, the absence of any build work, and the
# surviving sentinel files. The refused path itself is printed in the log but is
# not matched, because the host truncates long error lines.
$unsafeFlat = ([regex]::Replace($unsafeRun.text, '\s+', ' ')).Trim()
Assert-Pass ($unsafeFlat -match 'Deletion containment') "The real builder refusal is not a containment refusal: $($unsafeRun.text)"
Assert-Pass (-not ($unsafeRun.text -match 'adapter build failed')) 'The real builder reached the build step before validating the bundle directory.'
Assert-Pass (Test-Path -LiteralPath $outsideControlledSentinel) 'The real builder deleted a repository-external sentinel file.'
Assert-Pass (Test-Path -LiteralPath (Split-Path -Parent $outsideControlledSentinel)) 'The real builder removed the repository-external directory.'
$realBuildScript = Get-Content -LiteralPath $buildScriptPath -Raw
Assert-Pass ($realBuildScript.Contains("artifacts\staging\autocad-bundles")) 'The default staging root is not the script-owned repository-local staging root.'

# Legacy default output: no -Envelope means the top-level JSON array contract.
function Get-BuilderJsonPayload([string]$Text) {
    # The builder writes its JSON document last, after any MSBuild lines that
    # reach stdout plus a blank line, so the payload starts at the first line that
    # opens it. MSBuild output never begins a line with `[` or `{`.
    $lines = @($Text -split "`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].TrimStart()
        if ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{')) {
            return (@($lines[$i..($lines.Count - 1)]) -join "`n").Trim()
        }
    }
    throw "The builder did not emit a JSON payload: $Text"
}

if (-not $WithoutAutodesk) {
    $legacyRun = Invoke-AutoCADBuilder @('-Version', '2024,2025', '-Configuration', 'Release', '-SkipUnavailable', '-StagingRoot', (Join-Path $scratchRoot 'staging'))
    Assert-Pass ($legacyRun.exitCode -eq 0) "The default (no -Envelope) builder invocation failed: $($legacyRun.text)"
    $legacyJson = Get-BuilderJsonPayload $legacyRun.text
    $legacyParse = ConvertFrom-Json $legacyJson
    Assert-Pass (@($legacyParse).Count -ge 1) 'The default output is not iterable as an array after ConvertFrom-Json.'
    Assert-Pass (@($legacyParse | Where-Object { $_.version -eq '2024' }).Count -eq 1) 'The default output lost the AutoCAD 2024 result row.'
    Assert-Pass (@($legacyParse | Where-Object { $_.version -eq '2025' }).Count -eq 1) 'The default output lost the AutoCAD 2025 result row.'
    Assert-Pass ((Get-PropertyValue $legacyParse 'bundle') -eq $null -and (Get-PropertyValue $legacyParse 'results') -eq $null) 'The default output is still an envelope instead of the legacy array.'
    Assert-Pass ($legacyJson.TrimStart().StartsWith('[')) 'The default output does not start with a JSON array.'
    Assert-Pass ($legacyJson -match '"version":\s*"2024"') 'The default output does not carry the AutoCAD 2024 row.'

    # Explicit envelope: the builder may stage a bundle and must report it.
    $envelopeStagingRoot = Join-Path $scratchRoot 'staging'
    New-Item -ItemType Directory -Force -Path $envelopeStagingRoot | Out-Null
    $envelopeRoot = Join-Path (Join-Path $scratchRoot 'envelope-root') 'envelope-bundle'
    Assert-Pass ((Split-Path -Parent $envelopeRoot) -eq (Join-Path $scratchRoot 'envelope-root')) 'The envelope bundle fixture is not inside its own scratch staging root.'
    if (Test-Path -LiteralPath $envelopeRoot) { Remove-Item -LiteralPath $envelopeRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $envelopeRoot | Out-Null
    $envelopeRun = Invoke-AutoCADBuilder @('-Version', '2024,2025', '-Configuration', 'Release', '-Envelope', '-StagingRoot', (Join-Path $scratchRoot 'envelope-root'), '-BundleDirectory', $envelopeRoot)
    Assert-Pass ($envelopeRun.exitCode -eq 0) "The explicit -Envelope builder invocation failed: $($envelopeRun.text)"
    $envelopeParse = ConvertFrom-Json (Get-BuilderJsonPayload $envelopeRun.text)
    Assert-Pass (@((Get-PropertyValue $envelopeParse 'results')).Count -eq 2) "The envelope does not carry two result rows: $($envelopeRun.text)"
    Assert-Pass ((Get-PropertyValue (Get-PropertyValue $envelopeParse 'bundle') 'bundleDirectory') -eq $envelopeRoot) 'The envelope bundle directory is not the requested staging directory.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $envelopeRoot 'PackageContents.xml')) 'The staged bundle has no PackageContents.xml.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $envelopeRoot 'Contents\Windows\2024\BimBridge.AutoCAD2024.dll')) 'The staged bundle has no AutoCAD 2024 module.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $envelopeRoot 'Contents\Windows\2025\BimBridge.AutoCAD2025.dll')) 'The staged bundle has no AutoCAD 2025 module.'

    # Staging intent alone selects the envelope: -BundleDirectory without -Envelope
    # must report the bundle it staged instead of silently falling back to the legacy
    # array. This is the same shape the Revit architecture test asserts for
    # -BundleDirectory, and it is the case that was previously uncovered here: the
    # only successful staging run above also passes -Envelope, so withholding the
    # envelope would not have failed this suite.
    $bundleOnlyStagingRoot = Join-Path $scratchRoot 'bundle-only-root'
    New-Item -ItemType Directory -Force -Path $bundleOnlyStagingRoot | Out-Null
    $bundleOnlyRoot = Join-Path $bundleOnlyStagingRoot 'bundle-only'
    Assert-Pass ((Split-Path -Parent $bundleOnlyRoot) -eq $bundleOnlyStagingRoot) 'The bundle-only fixture is not inside its own scratch staging root.'
    if (Test-Path -LiteralPath $bundleOnlyRoot) { Remove-Item -LiteralPath $bundleOnlyRoot -Recurse -Force }
    $bundleOnlyRun = Invoke-AutoCADBuilder @('-Version', '2024,2025', '-Configuration', 'Release', '-StagingRoot', $bundleOnlyStagingRoot, '-BundleDirectory', $bundleOnlyRoot)
    Assert-Pass ($bundleOnlyRun.exitCode -eq 0) "The -BundleDirectory-only builder invocation failed: $($bundleOnlyRun.text)"
    $bundleOnlyJson = Get-BuilderJsonPayload $bundleOnlyRun.text
    Assert-Pass ($bundleOnlyJson.TrimStart().StartsWith('{')) "An explicit -BundleDirectory without -Envelope returned a top-level JSON array instead of the envelope: $bundleOnlyJson"
    $bundleOnlyParse = ConvertFrom-Json $bundleOnlyJson
    Assert-Pass (@((Get-PropertyValue $bundleOnlyParse 'results')).Count -eq 2) "The -BundleDirectory-only envelope does not carry two result rows: $bundleOnlyRun.text"
    Assert-Pass ((Get-PropertyValue $bundleOnlyParse 'bundle') -ne $null) "The -BundleDirectory-only output dropped the bundle summary of the run that staged it: $bundleOnlyJson"
    Assert-Pass ((Get-PropertyValue (Get-PropertyValue $bundleOnlyParse 'bundle') 'bundleDirectory') -eq $bundleOnlyRoot) 'The -BundleDirectory-only envelope does not name the requested staging directory.'
    Assert-Pass ((Get-PropertyValue (Get-PropertyValue $bundleOnlyParse 'bundle') 'components').Count -ge 1) 'The -BundleDirectory-only envelope staged an empty bundle summary.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleOnlyRoot 'PackageContents.xml')) 'The -BundleDirectory-only run staged no PackageContents.xml.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleOnlyRoot 'Contents\Windows\2024\BimBridge.AutoCAD2024.dll')) 'The -BundleDirectory-only run staged no AutoCAD 2024 module.'
    Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleOnlyRoot 'Contents\Windows\2025\BimBridge.AutoCAD2025.dll')) 'The -BundleDirectory-only run staged no AutoCAD 2025 module.'
}

# Cleanup only ever runs on scratch directories this test created itself, and each
# one is proven to be a direct child of the scratch root and not a reparse point.
foreach ($target in @((Join-Path $scratchRoot 'guard'), (Join-Path $scratchRoot 'sentinel'), (Join-Path $scratchRoot 'staging'), (Join-Path $scratchRoot 'envelope-root'), (Join-Path $scratchRoot 'bundle-only-root'), (Join-Path $scratchRoot 'intermediate-junction'), (Join-Path $scratchRoot 'bundle-swap-root'))) {
    Assert-Pass ((Split-Path -Parent $target) -eq $scratchRoot) "Refusing to clean a scratch directory outside $scratchRoot."
    if (Test-Path -LiteralPath $target) {
        Assert-Pass (-not (Test-LinkReparsePoint $target)) "Refusing to clean the link reparse point at $target."
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
# The run-scoped scratch is removed only after its own name pattern, absolute
# parent, non-reparse classification and ownership marker are re-verified. No other
# run's scratch is ever removed: the discovery helper is read-only, and this file
# contains no cross-run deletion path at all.
Assert-ScratchOwnership $scratchRoot
$testSourceAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
$reportFunctionAst = $testSourceAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LegacyScratchReport'
    }, $true)
Assert-Pass ($null -ne $reportFunctionAst) 'The read-only legacy-scratch report function is missing.'
$reportFunctionText = [string]$reportFunctionAst.Extent.Text
Assert-Pass (-not ($reportFunctionText -match 'Remove-Item')) 'The legacy-scratch report function contains a Remove-Item, so it is not read-only.'
Assert-Pass (@($reportFunctionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and @('Remove-Item', 'Remove-ItemProperty', 'rd', 'rmdir', 'del', 'erase') -contains $node.GetCommandName()
            }, $true)).Count -eq 0) 'The legacy-scratch report function invokes a deletion command.'
Assert-Pass (-not ($reportFunctionText -match 'ownership\.json|scratchMarkerName')) 'The legacy-scratch report function reads an ownership marker, so it is not a pure discovery step.'
# Every scratch-directory deletion in this file must target this run's own scratch.
$scratchDeletionSites = @($testSourceAst.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            if ($node.GetCommandName() -ne 'Remove-Item') { return $false }
            $null -ne $node.Find({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and $inner.VariablePath.UserPath -ceq 'scratchRoot'
                }, $true)
        }, $true))
Assert-Pass ($scratchDeletionSites.Count -ge 1) 'No run-scoped scratch removal site was found, so the cleanup contract is unproven.'
$crossRunDeletionSites = @($testSourceAst.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            if ($node.GetCommandName() -ne 'Remove-Item') { return $false }
            # A removal whose pipeline walks $stagingNamespace or a $candidate /
            # $legacy variable would be a cross-run deletion path.
            $walksSharedNamespace = $null -ne $node.Find({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    @('stagingNamespace', 'legacy', 'candidate', 'Legacy') -contains $inner.VariablePath.UserPath
                }, $true)
            $walksSharedNamespace
        }, $true))
Assert-Pass ($crossRunDeletionSites.Count -eq 0) "This suite contains $($crossRunDeletionSites.Count) deletion site(s) reaching a cross-run scratch variable, so another run's scratch could be deleted."
Assert-Pass (Test-Path -LiteralPath (Join-Path $scratchRoot '.ownership.json')) 'The run-scoped ownership marker disappeared before cleanup.'
Assert-Pass ((Split-Path -Parent $scratchRoot) -eq $stagingNamespace) "Refusing to clean a scratch directory outside $stagingNamespace."
Remove-Item -LiteralPath $scratchRoot -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $scratchRoot)) 'The containment scratch tree was not cleaned up.'
Assert-Pass (Test-Path -LiteralPath $stagingNamespace) 'Cleanup removed the shared artifacts staging namespace.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $intermediateJunctionTarget 'autocad-bundles\bundle')) 'Cleanup escaped the run-scoped scratch through the intermediate junction.'
Assert-Pass ((Split-Path -Parent $intermediateJunctionTarget) -eq $tempRoot) "Refusing to clean the intermediate-junction target outside the system temp root."
Assert-Pass (-not (Test-LinkReparsePoint $intermediateJunctionTarget)) "Refusing to clean the link reparse point at $intermediateJunctionTarget."
Assert-Pass (-not (Test-Path -LiteralPath $intermediateJunctionPath)) 'The intermediate junction fixture was not cleaned up with its scratch parent.'
Remove-Item -LiteralPath $intermediateJunctionTarget -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $intermediateJunctionTarget)) 'The intermediate-junction target tree was not cleaned up.'
# The bundle-swap fixture: cleanup runs only after the same controlled-parent and
# non-reparse re-verification every other scratch fixture gets.
Assert-Pass ((Split-Path -Parent $bundleSwapTarget) -eq $tempRoot) "Refusing to clean the bundle-swap witness target outside the system temp root."
Assert-Pass (-not (Test-LinkReparsePoint $bundleSwapTarget)) "Refusing to clean the link reparse point at $bundleSwapTarget."
Assert-Pass (Test-Path -LiteralPath $swapWitness) 'The bundle-swap witness was removed during the run.'
Assert-Pass ((Get-FileHash -LiteralPath $swapWitness -Algorithm SHA256).Hash -eq $swapWitnessHashBefore) 'The bundle-swap witness content changed during the run.'
Assert-Pass (-not (Test-Path -LiteralPath $bundleSwapRoot)) 'The bundle-swap staging fixture survived its scratch cleanup.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleSwapTarget 'bundle\Contents\Windows\2024\must-not-be-removed.dll')) 'The bundle-swap fixture cleanup reached through the junction into the external target.'
Remove-Item -LiteralPath $bundleSwapTarget -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $bundleSwapTarget)) 'The bundle-swap witness target tree was not cleaned up.'
# The containment-chain fixtures live in the run's own TEMP umbrella, and are
# cleaned up only after the same controlled-parent and non-reparse re-verification
# every other scratch fixture gets. Removing the umbrella removes the junctions
# themselves (as links), so the targets below are never a junction at that point,
# and each target is asserted to still hold its content before it is removed.
Assert-Pass ((Split-Path -Parent $chainUmbrella) -eq $tempRoot) "Refusing to clean a containment-chain umbrella outside the system temp root."
Assert-Pass (-not (Test-LinkReparsePoint $chainUmbrella)) "Refusing to clean the link reparse point at $chainUmbrella."
foreach ($chainFixtureDirectory in @($chainJunctionTarget, $chainArtifactsTarget)) {
    Assert-Pass ((Split-Path -Parent $chainFixtureDirectory) -eq $chainUmbrella) "Refusing to clean a containment-chain fixture outside $chainUmbrella."
    Assert-Pass (-not (Test-LinkReparsePoint $chainFixtureDirectory)) "Refusing to clean the link reparse point at $chainFixtureDirectory."
}
Assert-Pass (Test-Path -LiteralPath $chainWitness) 'The containment-chain witness was removed during the run.'
Assert-Pass ((Get-FileHash -LiteralPath $chainWitness -Algorithm SHA256).Hash -eq $chainWitnessHash) 'The containment-chain witness content changed during the run.'
Assert-Pass (@(Get-ChildItem -LiteralPath $chainJunctionTarget -Recurse -File -Force).Count -eq $chainTargetFileCount) 'The containment-chain refusal changed the external target content.'
# The junction links are unlinked explicitly before the umbrella is removed:
# `Remove-Item -Recurse` on a directory that *contains* a junction follows it and
# deletes the target's contents too (verified on this host), which would destroy
# the very witnesses these fixtures keep. Removing a link without -Recurse only
# unlinks it.
foreach ($chainJunctionFixturePath in @($chainArtifactsJunction, $chainContainmentJunction)) {
    Assert-Pass ($chainJunctionFixturePath.StartsWith($chainUmbrella + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "Refusing to unlink the containment-chain fixture junction outside the run umbrella: $chainJunctionFixturePath"
    Assert-Pass (Test-LinkReparsePoint $chainJunctionFixturePath) "Refusing to unlink a non-link at $chainJunctionFixturePath."
    $linkItem = Get-Item -LiteralPath $chainJunctionFixturePath -Force
    [IO.Directory]::Delete($linkItem.FullName)
    Assert-Pass (-not (Test-Path -LiteralPath $chainJunctionFixturePath)) "The containment-chain fixture junction $chainJunctionFixturePath was not unlinked."
}
Assert-Pass ((Split-Path -Parent $chainUmbrella) -eq $tempRoot) "Refusing to clean a containment-chain umbrella outside the system temp root."
Assert-Pass (-not (Test-LinkReparsePoint $chainUmbrella)) "Refusing to clean the link reparse point at $chainUmbrella."
Assert-Pass (-not (Test-LinkReparsePoint $chainArtifactsRepository)) "Refusing to clean the link reparse point at $chainArtifactsRepository."
Assert-Pass (-not (Test-LinkReparsePoint $chainContainmentRepository)) "Refusing to clean the link reparse point at $chainContainmentRepository."
Assert-Pass (-not (Test-LinkReparsePoint $chainJunctionTarget)) "Refusing to clean the link reparse point at $chainJunctionTarget."
Remove-Item -LiteralPath $chainUmbrella -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $chainUmbrella)) 'The containment-chain fixture umbrella was not cleaned up.'
Assert-Pass (-not (Test-Path -LiteralPath (Join-Path $chainJunctionTarget 'staging\autocad-bundles\bundle'))) 'The containment-chain cleanup created a bundle inside the external target.'
Assert-Pass (-not (Test-Path -LiteralPath $chainArtifactsJunction)) 'The artifacts-level junction fixture survived the umbrella cleanup.'
Assert-Pass (-not (Test-Path -LiteralPath $chainContainmentJunction)) 'The containment-root junction fixture survived the umbrella cleanup.'
# The targets are gone as part of the umbrella, but the witness they held was
# asserted intact immediately before that removal, so no refusal reached them.
Assert-Pass (-not (Test-Path -LiteralPath $chainJunctionTarget)) 'The containment-chain junction target survived its own umbrella cleanup.'
Assert-Pass (-not (Test-Path -LiteralPath $chainArtifactsTarget)) 'The artifacts-level junction target survived its own umbrella cleanup.'
Assert-Pass ((Split-Path -Parent $externalSentinelRoot) -eq $tempRoot) "Refusing to clean the repository-external fixture outside the system temp root."
Assert-Pass (-not (Test-LinkReparsePoint $externalSentinelRoot)) "Refusing to clean the link reparse point at $externalSentinelRoot."
Remove-Item -LiteralPath $externalSentinelRoot -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $externalSentinelRoot)) 'The repository-external fixture tree was not cleaned up.'

# ---------------------------------------------------------------------------
# Structural evidence (same AST the guard functions were extracted from).
#
# P0-A: the guard must classify the whole existing chain from the canonical
# repository root down to the containment root, including the containment root
# itself, and the reparse tag must decide the classification instead of the
# attributes.
# P0-B: the guard statement must be the *immediately* preceding statement of the
# recursive removal, and the path that call returned is the only path the removal
# may delete, so a stale preflight result is never a deletion authorization.
# ---------------------------------------------------------------------------
$guardInvocationPattern = '^Assert-ContainedStagingDirectory\s'
function Get-StatementIndex([System.Management.Automation.Language.ScriptBlockAst]$ScriptAst, [scriptblock]$Predicate) {
    $statements = @($ScriptAst.EndBlock.Statements)
    for ($i = 0; $i -lt $statements.Count; $i++) {
        if (& $Predicate $statements[$i]) { return $i }
    }
    -1
}
$bundleRootAssignmentPredicate = { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    ([string]$node.Left.Extent.Text).Trim() -ceq '$bundleRoot' -and
    $node.Right -is [System.Management.Automation.Language.PipelineAst] -and
    ([string]$node.Right.Extent.Text).TrimStart() -match '^Assert-ContainedStagingDirectory\s' }

$guardDefinitionsText = ($guardDefinitions -join "`n")
Assert-Pass ($guardDefinitionsText.Contains("`$anchoredRepositoryRoot = `$containmentRootText.Substring(0, `$containmentRootText.Length - `$artifactsStagingSuffix.Length)")) 'The containment chain walk no longer anchors on the canonical repository root recovered from the containment root.'
Assert-Pass ($guardDefinitionsText.Contains("`$walked.Equals(`$containmentRootText, [StringComparison]::OrdinalIgnoreCase)")) 'The containment chain walk no longer ends at the containment root itself.'
Assert-Pass ($guardDefinitionsText.Contains('while ($walked -and -not $walked.Equals($containmentRootText, [StringComparison]::OrdinalIgnoreCase))')) 'The containment chain walk is no longer a strict ancestor walk from the repository root to the containment root.'
Assert-Pass ($guardDefinitionsText.Contains('on the path from the repository root to the containment root')) 'The containment chain walk names no repository-to-containment refusal.'
$containmentWalkStart = $guardDefinitionsText.IndexOf('$walked = $anchoredRepositoryRoot')
$containmentWalkEnd = $guardDefinitionsText.IndexOf('$containmentPrefix = $ContainmentRoot.TrimEnd', $containmentWalkStart)
Assert-Pass ($containmentWalkStart -ge 0 -and $containmentWalkEnd -gt $containmentWalkStart) 'The repository-to-containment chain walk is not present before the staging-root walk.'
$containmentWalkText = $guardDefinitionsText.Substring($containmentWalkStart, $containmentWalkEnd - $containmentWalkStart)
Assert-Pass ($containmentWalkText.Contains('Test-LinkReparsePoint $walked')) 'The repository-to-containment chain walk does not classify every walked segment as a reparse point.'
Assert-Pass ($containmentWalkText.Contains('Test-Path -LiteralPath $walked')) 'The repository-to-containment chain walk does not classify the containment root itself.'
Assert-Pass ($containmentWalkText.Contains('$chainItem.Attributes -band [IO.FileAttributes]::Directory')) 'The repository-to-containment chain walk does not require a real directory at each existing segment.'
# The tag decides, not the attributes: only 0xA0000003 and 0xA000000C are link
# escapes, which is what keeps cloud reparse tags (0x9000e01a) benign. The
# unreadable-tag refusal must stay in the tag reader, i.e. on the only path that
# can produce a tag at all.
Assert-Pass ($guardDefinitionsText.Contains("Equals('a0000003', [StringComparison]::OrdinalIgnoreCase)")) 'The link classifier no longer recognises the junction tag 0xA0000003.'
Assert-Pass ($guardDefinitionsText.Contains("Equals('a000000c', [StringComparison]::OrdinalIgnoreCase)")) 'The link classifier no longer recognises the symbolic-link tag 0xA000000C.'
Assert-Pass ($guardDefinitionsText.Contains("if (`$tagText -notmatch '^(?:0x)?[0-9a-fA-F]{8}`$')")) 'The tag classifier no longer requires exactly eight hexadecimal digits, so a cloud tag could be misread.'
Assert-Pass ($guardDefinitionsText.Contains("the reparse tag of '`$Path' could not be read, so it cannot be trusted")) 'An unreadable reparse tag no longer fails closed.'
Assert-Pass ($guardDefinitionsText.Contains('Test-LinkReparseTag (Get-LinkReparsePointTag $Path)')) 'The reparse-point classifier no longer routes through the tag reader.'
$attributeOnlyPattern = 'Attributes\s*-band\s*\[IO\.FileAttributes\]::ReparsePoint\)\s*\{?\s*return\s+\$true'
Assert-Pass (-not ($buildScript -match $attributeOnlyPattern)) 'The reparse attribute alone decides the classification, which would misjudge cloud placeholders.'

# The removal itself: located as the command of its enclosing pipeline, so the
# assertion does not depend on which block the cleanup happens to sit in.
$removePipelines = @($buildScriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
        @($node.PipelineElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandAst] -and $_.GetCommandName() -eq 'Remove-Item'
        }).Count -gt 0
}, $true))
Assert-Pass ($removePipelines.Count -eq 1) "Expected exactly one Remove-Item pipeline in the AutoCAD build script, found $($removePipelines.Count)."
$removePipeline = $removePipelines[0]
$removeCommand = @($removePipeline.PipelineElements | Where-Object {
    $_ -is [System.Management.Automation.Language.CommandAst] -and $_.GetCommandName() -eq 'Remove-Item'
})[0]
$removeLiteralPathIndex = -1
for ($i = 0; $i -lt $removeCommand.CommandElements.Count; $i++) {
    $removeElement = $removeCommand.CommandElements[$i]
    if ($removeElement -is [System.Management.Automation.Language.CommandParameterAst] -and
        ([string]$removeElement.ParameterName).ToLowerInvariant() -ceq 'literalpath') {
        $removeLiteralPathIndex = $i
    }
}
Assert-Pass ($removeLiteralPathIndex -ge 0) 'The recursive removal no longer targets -LiteralPath.'
$removePathExpression = $removeCommand.CommandElements[$removeLiteralPathIndex + 1]
Assert-Pass ($removePathExpression -is [System.Management.Automation.Language.VariableExpressionAst] -and
    [string]$removePathExpression.VariablePath.UserPath -ceq 'bundleRoot') 'The recursive removal does not delete the canonical $bundleRoot path.'
$removeParameters = New-Object System.Collections.ArrayList
foreach ($removeElement in $removeCommand.CommandElements) {
    if ($removeElement -is [System.Management.Automation.Language.CommandParameterAst]) {
        [void]$removeParameters.Add(([string]$removeElement.ParameterName).ToLowerInvariant())
    }
}
Assert-Pass (($removeParameters -contains 'recurse') -and ($removeParameters -contains 'force')) 'The recursive removal lost -Recurse or -Force, so the re-check no longer guards a recursive force deletion.'
Assert-Pass (-not ([string]$removePipeline.Extent.Text -match '\$bundleRoot\s*\)')) 'The recursive removal re-derives its path at the call site instead of using the re-check result.'

# The re-check: the guard statement and the existence statement it feeds must be
# the two statements immediately preceding the removal, so no other command can run
# between the re-check and the deletion and the removal may not be decided by the
# stale preflight result. The removal is walked up to the block that owns the guard
# re-check, so the assertion does not depend on the exact nesting of the cleanup.
$removePipelineParent = $removePipeline.Parent
$removeClause = $null
$removeOwnerStatement = $removePipelineParent
$orderingParent = $removePipelineParent
$recheckStatementIndex = -1
$orderingStatements = @()
while ($orderingParent) {
    if ($orderingParent -is [System.Management.Automation.Language.StatementBlockAst]) {
        $candidateStatements = @($orderingParent.Statements)
        for ($i = 0; $i -lt $candidateStatements.Count; $i++) {
            if (& $bundleRootAssignmentPredicate $candidateStatements[$i]) {
                $recheckStatementIndex = $i
                $orderingStatements = $candidateStatements
            }
        }
        if ($recheckStatementIndex -ge 0) { break }
    }
    if ($orderingParent -is [System.Management.Automation.Language.IfStatementAst] -and -not $removeClause) { $removeClause = $orderingParent }
    if ($orderingParent -is [System.Management.Automation.Language.IfStatementAst] -or $orderingParent -is [System.Management.Automation.Language.AssignmentStatementAst]) { $removeOwnerStatement = $orderingParent }
    $orderingParent = $orderingParent.Parent
}
Assert-Pass ($orderingParent -is [System.Management.Automation.Language.StatementBlockAst]) 'The recursive removal is not inside a statement block that also owns the guard re-check.'
Assert-Pass ($recheckStatementIndex -ge 0) 'The guard result is never assigned to $bundleRoot in the block that owns the recursive removal.'
Assert-Pass (($recheckStatementIndex + 2) -lt $orderingStatements.Count) 'The guard re-check is not followed by both an existence decision and the recursive removal.'
$recheckStatement = $orderingStatements[$recheckStatementIndex]
$existenceStatement = $orderingStatements[$recheckStatementIndex + 1]
$removeGuardStatement = $orderingStatements[$recheckStatementIndex + 2]
Assert-Pass ($existenceStatement -is [System.Management.Automation.Language.AssignmentStatementAst]) "The statement directly after the guard re-check is not the existence decision taken from the re-checked path: $($existenceStatement.Extent.Text.Trim())"
Assert-Pass (([string]$existenceStatement.Left.Extent.Text).Trim() -ceq '$bundleRootExists') 'The existence decision after the re-check is not taken into $bundleRootExists.'
$existenceText = ([string]$existenceStatement.Right.Extent.Text -replace '\s+', ' ').Trim()
Assert-Pass ($existenceText -ceq 'Test-Path -LiteralPath $bundleRoot') "The existence decision does not test the re-checked canonical path: $existenceText"
# The existence decision must consume the re-checked variable, not a re-derived
# path, and the removal must be the only thing inside its enclosing condition.
$existenceConditionVariables = @($existenceStatement.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { [string]$_.VariablePath.UserPath })
Assert-Pass ($existenceConditionVariables.Count -eq 1 -and $existenceConditionVariables[0] -ceq 'bundleRoot') "The existence decision reads variables other than the re-checked path: $($existenceConditionVariables -join ',')"
Assert-Pass ($removeGuardStatement -is [System.Management.Automation.Language.IfStatementAst]) 'The recursive removal is no longer wrapped in the condition that consumes the existence decision.'
Assert-Pass ($null -ne $removeClause) 'The recursive removal is not inside the condition that consumes the existence decision.'
Assert-Pass ($removeClause.Clauses.Count -eq 1) "The recursive removal sits under $($removeClause.Clauses.Count) clauses instead of one."
Assert-Pass (@($removeClause.Clauses[0].Item2.Statements).Count -eq 1) 'The recursive removal is no longer the single statement of its condition.'
$removeConditionText = ([string]$removeClause.Clauses[0].Item1.Extent.Text -replace '\s+', ' ').Trim()
Assert-Pass ($removeConditionText -ceq '$bundleRootExists') "The recursive removal is not gated on the existence decision taken from the re-checked path: $removeConditionText"
$recheckCount = @($buildScriptAst.FindAll($bundleRootAssignmentPredicate, $true)).Count
Assert-Pass ($recheckCount -eq 2) "The guard result is assigned to `$bundleRoot $recheckCount times instead of exactly twice (the preflight and the pre-removal re-check), so the removal path may not be guard-produced."
foreach ($guardProducedAssignment in @($buildScriptAst.FindAll($bundleRootAssignmentPredicate, $true))) {
    Assert-Pass ([string]$guardProducedAssignment.Right.PipelineElements[0].GetCommandName() -ceq 'Assert-ContainedStagingDirectory') "A `$bundleRoot assignment is not produced by the containment guard: $($guardProducedAssignment.Extent.Text.Trim())"
}
$buildIndex = Get-StatementIndex $buildScriptAst { param($node) @($node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'dotnet' }, $true)).Count -gt 0 }
Assert-Pass ($buildIndex -ge 0) 'The matrix build invocation could not be located in the AutoCAD build script.'
# Ordering is asserted on source positions as well, because it is the property a
# reviewer can see: the re-check, the existence decision it feeds and the removal
# must all sit after the matrix build, in that order.
$buildSourceLine = $buildScriptAst.EndBlock.Statements[$buildIndex].Extent.StartLineNumber
Assert-Pass ($recheckStatement.Extent.StartLineNumber -gt $buildSourceLine) 'The pre-removal re-check is not a fresh check after the matrix build, so long build work still leaves the preflight result as the only authorization.'
Assert-Pass ($existenceStatement.Extent.StartLineNumber -gt $recheckStatement.Extent.StartLineNumber) 'The existence decision is not taken after the pre-removal re-check.'
Assert-Pass ($removePipeline.Extent.StartLineNumber -gt $existenceStatement.Extent.StartLineNumber) 'The recursive removal is not the statement after the existence decision taken from the re-checked path.'
$recheckCommand = $recheckStatement.Right.PipelineElements[0]
Assert-Pass ([string]$recheckCommand.GetCommandName() -ceq 'Assert-ContainedStagingDirectory') 'The pre-removal re-check is not the containment guard.'
$recheckArgumentVariables = @($recheckCommand.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] })
Assert-Pass ($recheckCommand.CommandElements.Count -eq 4) "The pre-removal re-check call has $($recheckCommand.CommandElements.Count) command elements instead of the guard plus three arguments."
Assert-Pass ($recheckArgumentVariables.Count -eq 3) "The pre-removal re-check call passes $($recheckArgumentVariables.Count) variables instead of three."
foreach ($guardArgument in @(@(0, 'bundleRoot'), @(1, 'StagingRoot'), @(2, 'repositoryRoot'))) {
    Assert-Pass ([string]$recheckArgumentVariables[[int]$guardArgument[0]].VariablePath.UserPath -ceq [string]$guardArgument[1]) "The pre-removal re-check call does not pass `$$($guardArgument[1]) as argument $([int]$guardArgument[0] + 1)."
}
# Line adjacency as well: the re-check and the existence decision it feeds must be
# the two statements before the removal, which is what a reviewer of the file can
# see without an AST.
$buildLines = @($buildScript -split "`n")
$removeLine = -1
for ($i = 0; $i -lt $buildLines.Count; $i++) {
    if ($buildLines[$i] -match '^\s*Remove-Item -LiteralPath \$bundleRoot -Recurse -Force\s*$') { $removeLine = $i; break }
}
Assert-Pass ($removeLine -gt 0) 'The guarded recursive removal line could not be located in the AutoCAD build script.'
$existenceLine = -1
for ($i = $removeLine - 1; $i -ge 0; $i--) {
    $candidateLine = $buildLines[$i].Trim()
    if ($candidateLine.Length -eq 0 -or $candidateLine.StartsWith('#')) { continue }
    if ($candidateLine -ceq 'if ($bundleRootExists) {') { continue }
    $existenceLine = $i
    break
}
Assert-Pass ($existenceLine -gt 0) 'The existence decision line could not be located before the recursive removal.'
$existenceLineText = $buildLines[$existenceLine].Trim()
Assert-Pass ($existenceLineText -ceq '$bundleRootExists = Test-Path -LiteralPath $bundleRoot') "The statement immediately before the recursive removal is not the existence decision taken from the re-checked path: $existenceLineText"
$recheckLine = -1
for ($i = $existenceLine - 1; $i -ge 0; $i--) {
    $candidateLine = $buildLines[$i].Trim()
    if ($candidateLine.Length -eq 0 -or $candidateLine.StartsWith('#')) { continue }
    $recheckLine = $i
    break
}
Assert-Pass ($recheckLine -gt 0) 'The containment guard re-check line could not be located before the existence decision.'
$recheckLineText = ((@($buildLines[$recheckLine..($existenceLine - 1)]) | ForEach-Object { $_.Trim() }) -join ' ')
Assert-Pass ($recheckLineText -match 'Assert-ContainedStagingDirectory\s') "The statement immediately before the existence decision is not a containment guard re-check: $recheckLineText"
Assert-Pass ($recheckLineText.Contains('$bundleRoot $StagingRoot $repositoryRoot')) "The pre-removal re-check does not re-check the bundle root against its own staging root and repository root: $recheckLineText"

[ordered]@{
    status = 'passed'
    releases = $years
    sharedProject = $projectPath
    checksPassed = $script:PassedChecks
} | ConvertTo-Json -Depth 3
