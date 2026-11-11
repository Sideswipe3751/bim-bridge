$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$matrixPath = Join-Path $repositoryRoot 'eng\Autodesk.Versions.props'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.csproj'
$templatePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.addin.template'
$buildScriptPath = Join-Path $repositoryRoot 'eng\Build-RevitAdapters.ps1'
$matrixHelperPath = Join-Path $repositoryRoot 'eng\RevitVersionMatrix.ps1'
$liveScriptPath = Join-Path $repositoryRoot 'eng\Run-RevitLiveAcceptance.ps1'
$bootstrapProjectPath = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\BimBridge.Revit.TestBootstrap.csproj'
$bootstrapSourcePath = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\LiveTestBootstrapApplication.cs'
$liveDriverPath = Join-Path $repositoryRoot 'tests\live\BimBridge.LiveTestDriver\Program.cs'
$trustScriptPath = Join-Path $repositoryRoot 'eng\Initialize-RevitLiveTestTrust.ps1'
$signingScriptPath = Join-Path $repositoryRoot 'eng\Sign-RevitLiveTestArtifacts.ps1'
$revitExecutorPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitConnectorExecutor.cs'
$revitFailurePreprocessorPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitFailurePreprocessor.cs'
$revitViewCapturePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitViewCaptureService.cs'
$connectorServerPath = Join-Path $repositoryRoot 'src\BimBridge.Host\ConnectorServer.cs'
$runtimeCapabilitiesPath = Join-Path $repositoryRoot 'runtime\aec_runtime\capabilities.py'
$runtimeServicePath = Join-Path $repositoryRoot 'runtime\aec_runtime\service.py'

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
    # Mirrors the classifier in eng/Build-RevitAdapters.ps1: only junction
    # (0xA0000003) and symbolic-link (0xA000000C) reparse tags are link escapes.
    # OneDrive placeholders (0x9000e01a) mark synced folders here and are benign.
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

$script:BuilderHostPath = $null
function Invoke-RevitBuilder([string[]]$BuilderArguments, [string]$PathOverride) {
    # Same host as the CI architecture step, so the exit-code contract under test
    # is the one CI observes. `$PathOverride` only ever *prepends* to the child's
    # PATH, which is how the recorded-argument stub below intercepts `dotnet`
    # without touching any other process on this machine.
    if (-not $script:BuilderHostPath) { $script:BuilderHostPath = (Get-Process -Id $PID).Path }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScriptPath) + $BuilderArguments
    $savedPath = $env:PATH
    try {
        if ($PathOverride) { $env:PATH = $PathOverride + ';' + $savedPath }
        $output = & $script:BuilderHostPath @arguments 2>&1
        $code = $LASTEXITCODE
    } catch {
        # $ErrorActionPreference = 'Stop' turns a redirected terminating error
        # record into an exception; the message is still the real refusal.
        $output = @([string]$_.Exception.Message)
        $code = 1
    } finally {
        $env:PATH = $savedPath
    }
    [pscustomobject]@{
        text = @($output | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [string]$_.Exception.Message } else { [string]$_ }
        }) -join "`n"
        exitCode = $code
    }
}

[xml]$matrix = Get-Content -LiteralPath $matrixPath -Raw
$entries = @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup } |
    Where-Object { $_.PSObject.Properties['ReleaseYear'] })
Assert-True ($entries.Count -gt 0) 'The Revit version matrix is empty.'

$years = @($entries | ForEach-Object { [string]$_.ReleaseYear })
Assert-True (@($years | Where-Object { -not $_ }).Count -eq 0) 'Every matrix entry must declare ReleaseYear.'
Assert-True (@($years | Sort-Object -Unique).Count -eq $years.Count) 'Revit ReleaseYear values must be unique.'

foreach ($entry in $entries) {
    $year = [string]$entry.ReleaseYear
    Assert-True ([string]$entry.RevitAssemblyName -eq "BimBridge.Revit$year") "Revit $year assembly identity is not BIM Bridge branded."
    Assert-True ([string]$entry.RevitManifestName -eq "BimBridge.Revit$year.addin") "Revit $year generated manifest is not BIM Bridge branded."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitTargetFramework)) "Revit $year is missing RevitTargetFramework."
    Assert-True (@('netfx', 'modern') -contains [string]$entry.RevitRuntimeFamily) "Revit $year has an invalid runtime family."
    Assert-True (@('fixed', 'installed-api-runtime') -contains [string]$entry.RevitRuntimeResolution) "Revit $year has an invalid runtime-resolution policy."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitSupportedTargetFrameworks)) "Revit $year is missing supported target frameworks."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitInstallSubdirectory)) "Revit $year is missing its install subdirectory."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitDefaultTemplateSubdirectory)) "Revit $year is missing its default live-test template."
    Assert-True (@('codedom', 'roslyn') -contains [string]$entry.RevitDynamicCompiler) "Revit $year has an invalid compiler."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitSupportStatus)) "Revit $year is missing support status."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitCertificationStatus)) "Revit $year is missing certification status."
}

$entryByYear = @{}
foreach ($entry in $entries) { $entryByYear[[string]$entry.ReleaseYear] = $entry }
Assert-True ([string]$entryByYear['2025'].RevitUseRevitContext -eq 'true') 'Revit 2025 must remain in the default load context because its manifest schema predates dependency isolation.'
foreach ($isolatedYear in @('2026', '2027')) {
    Assert-True ([string]$entryByYear[$isolatedYear].RevitUseRevitContext -eq 'false') "Revit $isolatedYear must use the supported isolated add-in context."
}

$project = Get-Content -LiteralPath $projectPath -Raw
$adapterPropertiesPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.Adapter.props'
$adapterProperties = Get-Content -LiteralPath $adapterPropertiesPath -Raw
Assert-True ($adapterProperties.Contains('Autodesk.Versions.props')) 'The Revit adapter must import the version matrix.'
Assert-True ($adapterProperties.Contains('Runtime\NetFramework\RuntimeCodeCompiler.cs')) 'The .NET Framework compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Runtime\Modern\RuntimeCodeCompiler.cs')) 'The modern compiler boundary is missing.'

$template = Get-Content -LiteralPath $templatePath -Raw
Assert-True ($template.Contains('{{ASSEMBLY_PATH}}')) 'The add-in template is missing the assembly token.'
Assert-True ($template.Contains('{{MANIFEST_SETTINGS}}')) 'The add-in template is missing the manifest-settings token.'

$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
Assert-True ($buildScript.Contains('Autodesk.Versions.props')) 'The Revit build entry point must consume the version matrix.'
Assert-True ($buildScript.Contains('RevitVersionMatrix.ps1')) 'The Revit build must use the shared runtime resolver.'

$matrixHelper = Get-Content -LiteralPath $matrixHelperPath -Raw
Assert-True ($matrixHelper.Contains('RevitAPI.runtimeconfig.json')) 'Serviced Revit runtimes must resolve from installed API metadata.'
Assert-True ($matrixHelper.Contains('RevitSupportedTargetFrameworks')) 'Resolved runtimes must be bounded by the matrix allow-list.'

$liveScript = Get-Content -LiteralPath $liveScriptPath -Raw
Assert-True ($liveScript.Contains('RevitVersionMatrix.ps1')) 'Live acceptance must use the shared runtime resolver.'
Assert-True ($liveScript.Contains('untrusted_binary')) 'Live acceptance must fail fast for untrusted test add-ins.'
Assert-True (-not $liveScript.Contains('installer\')) 'Live acceptance must remain outside the frozen installer.'
Assert-True ($liveScript.Contains('Sign-RevitLiveTestArtifacts.ps1')) 'Live acceptance must re-sign rebuilt development artifacts.'

$trustScript = Get-Content -LiteralPath $trustScriptPath -Raw
Assert-True ($trustScript.Contains('KeyExportPolicy NonExportable')) 'Development signing keys must be non-exportable.'
Assert-True ($trustScript.Contains('Cert:\CurrentUser\TrustedPublisher')) 'Development trust must be scoped to the current user.'
$signingScript = Get-Content -LiteralPath $signingScriptPath -Raw
Assert-True ($signingScript.Contains('Refusing to sign a file outside the repository')) 'Development signing must be repository-bounded.'
Assert-True ($signingScript.Contains("-ne '.dll'")) 'Development signing must be restricted to DLL artifacts.'

$bootstrapProject = Get-Content -LiteralPath $bootstrapProjectPath -Raw
Assert-True ($bootstrapProject.Contains('Autodesk.Versions.props')) 'The Revit test bootstrap must consume the version matrix.'
$bootstrapSource = Get-Content -LiteralPath $bootstrapSourcePath -Raw
Assert-True ($bootstrapSource.Contains('BIM_BRIDGE_REVIT_LIVE_TEST_REQUEST')) 'The Revit test bootstrap must be inert without a run request.'
Assert-True ($bootstrapSource.Contains('Safety gate refused')) 'The Revit test bootstrap must refuse unexpected documents.'

$liveDriver = Get-Content -LiteralPath $liveDriverPath -Raw
foreach ($requiredTool in @('aec_list_providers', 'aec_list_instances', 'aec_get_document_info', 'aec_get_selection', 'aec_execute_read', 'aec_execute_write')) {
    Assert-True ($liveDriver.Contains($requiredTool)) "Live acceptance is missing MCP route $requiredTool."
}
Assert-True ($liveDriver.Contains('rolledBack')) 'Live acceptance must verify native rollback evidence.'
Assert-True ($liveDriver.Contains('descriptor_cleanup')) 'Live acceptance must verify connector shutdown cleanup.'

$revitExecutor = Get-Content -LiteralPath $revitExecutorPath -Raw
$revitFailurePreprocessor = Get-Content -LiteralPath $revitFailurePreprocessorPath -Raw
Assert-True ($revitFailurePreprocessor.Contains('IFailuresPreprocessor')) 'The shared Revit host must preprocess native failures.'
Assert-True ($revitFailurePreprocessor.Contains('DeleteWarning')) 'Revit warnings must be captured without opening a native modal dialog.'
Assert-True ($revitFailurePreprocessor.Contains('ProceedWithRollBack')) 'Revit errors must fail closed and request rollback.'
Assert-True ($revitExecutor.Contains('SetFailuresPreprocessor')) 'Every connector-owned Revit transaction must install the failure preprocessor.'
Assert-True ($revitExecutor.Contains('SetForcedModalHandling(false)')) 'Connector-owned Revit writes must not wait for a native failure dialog.'
Assert-True ($revitExecutor.Contains('Warnings = failurePreprocessor.Warnings.ToList()')) 'Captured Revit warnings must be returned to the caller.'
Assert-True (-not $revitExecutor.Contains('DialogBoxShowing')) 'The connector must not automate or click Revit dialogs.'

$revitViewCapture = Get-Content -LiteralPath $revitViewCapturePath -Raw
$connectorServer = Get-Content -LiteralPath $connectorServerPath -Raw
$runtimeCapabilities = Get-Content -LiteralPath $runtimeCapabilitiesPath -Raw
$runtimeService = Get-Content -LiteralPath $runtimeServicePath -Raw
Assert-True ($revitViewCapture.Contains('ImageExportOptions')) 'Revit view capture must use the native image exporter.'
Assert-True ($revitViewCapture.Contains('SpecialFolder.LocalApplicationData')) 'Capture output must remain in bounded current-user state.'
Assert-True (-not $revitViewCapture.Contains('new Transaction(')) 'Read-only view capture must not modify the Revit model.'
Assert-True ($revitExecutor.Contains('"view.capture"')) 'The shared Revit connector must advertise view.capture.'
Assert-True ($connectorServer.Contains('operation == "view.capture"')) 'The frozen execute route must carry the structured capture operation.'
Assert-True ($runtimeCapabilities.Contains('"revit.view.capture"')) 'The Runtime capability registry must own the typed capture definition.'
Assert-True ($runtimeService.Contains('REVIT_HOST_PROVIDER_ID')) 'The existing provider MCP projection must expose host capture discovery.'

$legacySourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Directory |
    Where-Object { $_.Name -match '^BimBridge\.Revit\d{4}$' } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.cs' -Recurse } |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
Assert-True ($legacySourceFiles.Count -eq 0) 'Year-specific Revit business source files are not allowed.'

# ---------------------------------------------------------------------------
# Static shape of the fail-closed deletion guard and of the input validation in
# the shared renderer (eng/RevitVersionMatrix.ps1, eng/AutodeskVersionMatrix.ps1).
# The execution-shape proof follows below.
# ---------------------------------------------------------------------------
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
Assert-Pass ($buildScript -match 'Assert-ContainedStagingDirectory') 'The Revit build has no fail-closed deletion containment guard.'
Assert-Pass ($buildScript -match '(?m)^\s*\[string\]\$StagingRoot\s*,?\s*$') 'The Revit build has no explicit -StagingRoot parameter.'
Assert-Pass ($buildScript.Contains('artifacts\staging\revit-bundles')) 'The default Revit staging root is not the script-owned repository-local staging root.'
Assert-Pass ($buildScript -match 'OrdinalIgnoreCase') 'The deletion containment comparison is not ordinal case-insensitive.'
Assert-Pass (-not ($buildScript -match 'StartsWith\(\s*\$prefix\s*\)')) 'A bare StartsWith(prefix) comparison is still present in the Revit build.'
$removeItemLines = @([regex]::Matches($buildScript, '(?m)^\s*Remove(-|\s)Item.*$') | ForEach-Object { $_.Value.Trim() })
Assert-Pass ($removeItemLines.Count -eq 1) "The Revit build must have exactly one uncommented Remove-Item site, found $($removeItemLines.Count)."
Assert-Pass ($removeItemLines[0] -match 'Remove-Item -LiteralPath \$bundleRoot -Recurse -Force') 'The remaining Remove-Item is not the guarded bundle-root deletion.'
$bundleGuardIndex = $buildScript.IndexOf('Assert-ContainedStagingDirectory $BundleDirectory $stagingRootPath $repositoryRoot')
Assert-Pass ($bundleGuardIndex -gt 0) 'The bundle directory is not validated by the containment guard.'
$renderGuardIndex = $buildScript.IndexOf('Assert-ContainedStagingDirectory $RenderManifestDirectory $stagingRootPath $repositoryRoot')
Assert-Pass ($renderGuardIndex -gt 0) 'The render manifest directory is not held to the same containment rule.'
Assert-Pass ($bundleGuardIndex -lt $renderGuardIndex) 'The bundle containment guard must run before the render guard.'
Assert-Pass (-not ($buildScript -match '\[IO\.Path\]::GetFullPath\(\$BundleDirectory\)')) 'An unvalidated GetFullPath still feeds the bundle root.'
Assert-Pass (-not ($buildScript -match '\[IO\.Path\]::GetFullPath\(\$RenderManifestDirectory\)')) 'An unvalidated GetFullPath still feeds the render root.'
$removeIndex = $buildScript.IndexOf('Remove-Item -LiteralPath $bundleRoot -Recurse -Force')
Assert-Pass ($removeIndex -gt $bundleGuardIndex) 'Containment is not verified before the recursive removal.'
$buildInvocationIndex = $buildScript.IndexOf('& dotnet @arguments')
Assert-Pass ($buildInvocationIndex -gt $bundleGuardIndex) 'The staging containment guard runs after the first dotnet build, so an unsafe staging directory is only rejected after compiling.'

# ---------------------------------------------------------------------------
# P0-B: the deletion site must re-run the whole guard *immediately* before the
# recursive removal and may only delete the path that re-check returned. The
# preflight result alone is stale: the per-release build loop runs for minutes, and
# the target can be swapped for a junction in that window. The assertions walk the
# parsed script rather than the raw text, so they cannot be satisfied by a comment.
# ---------------------------------------------------------------------------
$buildScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($buildScriptPath, [ref]$null, [ref]$null)
$removeAsts = @($buildScriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-Item'
        }, $true))
Assert-Pass ($removeAsts.Count -eq 1) "Expected exactly one Remove-Item command in the Revit build script, found $($removeAsts.Count)."
$removeAst = $removeAsts[0]
$removeRecursive = @($removeAst.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { [string]$_.ParameterName })
Assert-Pass ($removeRecursive -contains 'Recurse') 'The guarded Revit removal lost -Recurse, so the re-check no longer guards a recursive delete.'
Assert-Pass ($removeRecursive -contains 'Force') 'The guarded Revit removal lost -Force.'
# The removed path must be the re-checked variable and must not re-derive anything.
Assert-Pass ($null -ne $removeAst.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq 'bundleRoot' }, $true)) 'The Revit recursive removal does not delete the re-checked $bundleRoot path.'
Assert-Pass (-not ($removeAst.Extent.Text -match '\$bundleRoot\s*\)')) 'The Revit recursive removal re-derives its path at the call site instead of using the re-check result.'

$guardAssignments = @($buildScriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            ([string]$node.Left.Extent.Text).Trim() -ceq '$bundleRoot' -and
            $null -ne $node.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-ContainedStagingDirectory' }, $true)
        }, $true))
Assert-Pass ($guardAssignments.Count -eq 2) "The guard result is assigned to `$bundleRoot $($guardAssignments.Count) times instead of exactly twice (the preflight and the pre-removal re-check), so the removal path may not be guard-produced."

# Locate the enclosing statement block of the removal and require the guard
# re-check, the existence decision taken from it, and the removal to be the three
# consecutive statements, in that order, with nothing in between.
# Locate the nearest statement block that owns the guard re-check. The removal sits
# inside its own `if ($bundleRootExists)` body, so the own block contains only the
# removal; the guard re-check and the existence decision live in the block one level
# up. The ascent stops at the first block that assigns $bundleRoot from the guard.
$recheckBlock = $null
$ascend = $removeAst
while ($null -ne $ascend -and $null -eq $recheckBlock) {
    if ($ascend -is [System.Management.Automation.Language.StatementBlockAst]) {
        $hasRecheck = @($ascend.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                ([string]$_.Left.Extent.Text).Trim() -ceq '$bundleRoot' -and
                $null -ne $_.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-ContainedStagingDirectory' }, $true)
            }).Count
        if ($hasRecheck -gt 0) { $recheckBlock = $ascend }
    }
    $ascend = $ascend.Parent
}
Assert-Pass ($null -ne $recheckBlock) 'No enclosing statement block assigns $bundleRoot from the containment guard, so the pre-removal re-check cannot be located.'
$orderedStatements = @($recheckBlock.Statements)
# The removal is nested inside its `if ($bundleRootExists)` statement, so it is not
# textually contained by any single statement of this block. The removal is instead
# the statement whose enclosing `if` is the *last* statement that starts before it.
$blockRemoveIndex = -1
for ($i = 0; $i -lt $orderedStatements.Count; $i++) {
    if ($orderedStatements[$i].Extent.StartOffset -lt $removeAst.Extent.StartOffset) { $blockRemoveIndex = $i }
}
Assert-Pass ($blockRemoveIndex -ge 2) 'The Revit recursive removal is not preceded by enough statements inside the block that owns the guard re-check.'
$guardStatement = $orderedStatements[$blockRemoveIndex - 1]
$recheckStatement = $null
for ($i = $blockRemoveIndex - 1; $i -ge 0; $i--) {
    $candidate = $orderedStatements[$i]
    if ($candidate -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        ([string]$candidate.Left.Extent.Text).Trim() -ceq '$bundleRoot' -and
        $null -ne $candidate.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-ContainedStagingDirectory' }, $true)) {
        $recheckStatement = $candidate
        break
    }
}
Assert-Pass ($null -ne $recheckStatement) 'No guard re-check assigns $bundleRoot in the block that owns the Revit recursive removal.'
Assert-Pass ($null -ne $guardStatement.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Path' }, $true)) 'The statement directly above the Revit recursive removal is not the existence decision taken from the re-checked path.'
Assert-Pass ($recheckStatement.Extent.StartLineNumber -lt $guardStatement.Extent.StartLineNumber) 'The existence decision is not taken after the guard re-check.'
Assert-Pass ($guardStatement.Extent.StartLineNumber -lt $removeAst.Extent.StartLineNumber) 'The Revit recursive removal is not the statement after the existence decision.'
$recheckText = [string]$recheckStatement.Extent.Text
Assert-Pass ($recheckText -match 'Assert-ContainedStagingDirectory\s+\$bundleRoot\s+\$stagingRootPath\s+\$repositoryRoot') "The pre-removal re-check does not re-check the bundle root against its own staging root and repository root: $recheckText"
Assert-Pass ($guardStatement.Extent.Text -match 'Test-Path -LiteralPath \$bundleRoot') "The existence decision does not test the re-checked canonical path: $($guardStatement.Extent.Text)"
Assert-Pass ($recheckStatement.Extent.StartLineNumber -gt ($buildScript.Substring(0, $buildScript.IndexOf('& dotnet @arguments')).Split("`n").Count)) 'The Revit pre-removal re-check is not a fresh check after the matrix build, so long build work still leaves the preflight result as the only authorization.'

# Render point of use: the render root must be re-checked by the same guard after
# the preflight and before the render write, because the loop resolves every earlier
# release first and the write overwrites a manifest. The preflight validates the
# parameter ($RenderManifestDirectory); the point of use must re-check the canonical
# result ($renderRoot), so both guards are located by the variable they consume.
$renderGuardVariablePredicate = {
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Assert-ContainedStagingDirectory' -and
    $null -ne $node.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq 'renderRoot' }, $true)
}
$renderPreflightPredicate = {
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Assert-ContainedStagingDirectory' -and
    $null -ne $node.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq 'RenderManifestDirectory' }, $true)
}
$renderPointOfUseCalls = @($buildScriptAst.FindAll($renderGuardVariablePredicate, $true))
$renderPreflightCalls = @($buildScriptAst.FindAll($renderPreflightPredicate, $true))
Assert-Pass ($renderPointOfUseCalls.Count -eq 1) "The render root is re-checked at its point of use $($renderPointOfUseCalls.Count) times instead of exactly once, so a render root swapped after the preflight is written through."
Assert-Pass ($renderPreflightCalls.Count -eq 1) "The render manifest directory is validated by the containment guard $($renderPreflightCalls.Count) times instead of exactly once."
$renderWriteAst = @($buildScriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Utf8NoBom' -and
            $null -ne $node.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq 'renderPath' }, $true)
        }, $true))
Assert-Pass ($renderWriteAst.Count -ge 1) 'The Revit render write site could not be located, so its point-of-use guard is unproven.'
$renderWriteLine = $renderWriteAst[0].Extent.StartLineNumber
$renderPointOfUseLine = $renderPointOfUseCalls[0].Extent.StartLineNumber
$renderPreflightLine = $renderPreflightCalls[0].Extent.StartLineNumber
Assert-Pass ($renderPreflightLine -lt $renderPointOfUseLine) 'The render root is not re-checked after the preflight that validated the parameter.'
Assert-Pass ($renderPointOfUseLine -lt $renderWriteLine) 'The render root is not re-checked before the manifest write it authorizes.'
$renderGuardLineText = [string]($buildScript -split "`r?`n")[$renderPointOfUseLine - 1]
Assert-Pass ($renderGuardLineText -match 'Assert-ContainedStagingDirectory\s+\$renderRoot\s+\$stagingRootPath\s+\$repositoryRoot') "The render point-of-use guard does not re-check the render root against its own staging root and repository root: $renderGuardLineText"

# The Revit builder must carry the same explicit -Offline switch as the AutoCAD
# builder, and the NuGet vulnerability audit must only ever be disabled inside
# that opt-in branch. Hosted CI builds therefore keep auditing.
Assert-Pass ($buildScript -match '(?m)^\s*\[switch\]\$Offline\s*,?\s*$') 'The Revit build has no explicit -Offline switch.'
Assert-Pass ($buildScript -match '(?m)^\s*if \(\$Offline\) \{') 'The NuGet audit switch is not conditional on -Offline.'
$offlineConditionalIndex = $buildScript.IndexOf('if ($Offline) {')
Assert-Pass ($offlineConditionalIndex -gt 0) 'The NuGet audit switch is not conditional on -Offline.'
$auditArgumentIndex = $buildScript.IndexOf("'-p:NuGetAudit=false'")
Assert-Pass ($auditArgumentIndex -gt $offlineConditionalIndex) 'The NuGet audit switch is applied outside the -Offline branch.'
# The quoted argument literal must appear exactly once, so the audit cannot be
# disabled from a second, unconditional site that the branch check above misses.
Assert-Pass (@([regex]::Matches($buildScript, [regex]::Escape("'-p:NuGetAudit=false'"))).Count -eq 1) 'The NuGet audit switch appears at more than one site in the Revit build.'
$argumentsDeclaredIndex = $buildScript.IndexOf('$arguments = @(')
Assert-Pass ($argumentsDeclaredIndex -gt 0 -and $auditArgumentIndex -gt $argumentsDeclaredIndex) 'The NuGet audit switch is not appended to the build argument list.'
$ciPath = Join-Path $repositoryRoot '.github\workflows\ci.yml'
$ciWorkflow = Get-Content -LiteralPath $ciPath -Raw
Assert-Pass (-not ($ciWorkflow -match 'NuGetAudit')) 'Hosted CI disables the NuGet vulnerability audit.'
# Both builders must name and shape the offline opt-in identically, because the
# release re-verification path invokes them with the same switch.
$autocadBuildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'eng\Build-AutoCADAdapters.ps1') -Raw
Assert-Pass ($autocadBuildScript -match '(?m)^\s*\[switch\]\$Offline\s*,?\s*$') 'The AutoCAD build has no explicit -Offline switch to mirror.'
Assert-Pass ($autocadBuildScript -match '(?m)^\s*if \(\$Offline\) \{') 'The AutoCAD audit switch is not conditional on -Offline.'
Assert-Pass ($autocadBuildScript.Contains("`$arguments += '-p:NuGetAudit=false'")) 'The AutoCAD build does not append the audit switch inside its -Offline branch.'
Assert-Pass ($buildScript.Contains("`$arguments += '-p:NuGetAudit=false'")) 'The Revit build does not append the audit switch inside its -Offline branch.'

$revitMatrixHelper = Get-Content -LiteralPath (Join-Path $repositoryRoot 'eng\RevitVersionMatrix.ps1') -Raw
Assert-Pass ($revitMatrixHelper -match 'Replace\(''\{\{ASSEMBLY_PATH\}\}'', \[Security\.SecurityElement\]::Escape') 'The Revit manifest renderer interpolates the assembly path without XML escaping.'
$autodeskMatrixHelper = Get-Content -LiteralPath (Join-Path $repositoryRoot 'eng\AutodeskVersionMatrix.ps1') -Raw
Assert-Pass ($autodeskMatrixHelper -match 'IsPathRooted\(\$ModuleDirectorySuffix\)') 'The bundle module directory is not validated against rooted paths.'
Assert-Pass ($autodeskMatrixHelper.Contains('$segment -eq ''..''')) 'The bundle module directory is not validated against traversal segments.'

# ---------------------------------------------------------------------------
# Input validation of the shared renderers. No filesystem state is touched. The
# AutoCAD matrix renderer is dot-sourced only for its pure render function.
# ---------------------------------------------------------------------------
. (Join-Path $repositoryRoot 'eng\AutodeskVersionMatrix.ps1')
$validationRelease = [pscustomobject]@{ Include = '2999'; AssemblyName = 'BimBridge.AutoCAD2999'; Series = 'R99.9' }
$packageTemplatePath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml'
foreach ($unsafeSuffix in @('C:\absolute\path', '\absolute\path', '..\..\escape', 'Contents/../../escape')) {
    $unsafeMessage = Assert-Rejected "module directory '$unsafeSuffix'" { New-AutoCADPackageContents @($validationRelease) '2.0.0' $packageTemplatePath $unsafeSuffix }
    Assert-Pass ($unsafeMessage -match 'relative path inside the bundle|escape the bundle') "The module directory rejection is not a containment refusal: $unsafeMessage"
}
$safeSuffixRender = New-AutoCADPackageContents @($validationRelease) '2.0.0' $packageTemplatePath 'Contents\Windows'
[xml]$safeSuffixPackage = $safeSuffixRender
Assert-Pass ([string]$safeSuffixPackage.ApplicationPackage.Components.ComponentEntry.ModuleName -eq './Contents/Windows/2999/BimBridge.AutoCAD2999.dll') 'A safe module directory no longer renders the historical module path.'

# Every XML interpolation boundary is escaped, so an XML-hostile version string
# still produces a parseable manifest whose value round-trips exactly.
$hostileVersion = '2.0.0-alpha.4&<>"'''
[xml]$hostilePackage = New-AutoCADPackageContents @($validationRelease) $hostileVersion $packageTemplatePath 'Contents\Windows'
Assert-Pass ([string]$hostilePackage.ApplicationPackage.AppVersion -eq $hostileVersion) 'The rendered AutoCAD AppVersion does not round-trip through XML.'
Assert-Pass ([string]$hostilePackage.ApplicationPackage.Components.ComponentEntry.Version -eq $hostileVersion) 'The rendered AutoCAD component Version does not round-trip through XML.'

$hostileAssemblyPath = 'C:\Program Files\B&B<Tools>\Bim''Bridge\BimBridge.Revit2999.dll'
$plainRelease = [pscustomobject]@{ Include = '2999'; UseRevitContext = 'true'; RuntimeFamily = 'netfx' }
[xml]$hostileAddIn = New-RevitAddInManifest $plainRelease $hostileAssemblyPath $templatePath
Assert-Pass ([string]$hostileAddIn.RevitAddIns.AddIn.Assembly -eq $hostileAssemblyPath) 'The rendered Revit assembly path does not round-trip through XML.'
$isolatedRelease = [pscustomobject]@{ Include = '2999'; UseRevitContext = 'false'; RuntimeFamily = 'modern' }
[xml]$isolatedAddIn = New-RevitAddInManifest $isolatedRelease $hostileAssemblyPath $templatePath
Assert-Pass ([string]$isolatedAddIn.RevitAddIns.ManifestSettings.ContextName -eq 'BIM.Bridge') 'The escaped isolation context name does not round-trip through XML.'

# ---------------------------------------------------------------------------
# Fail-closed deletion containment (eng/Build-RevitAdapters.ps1).
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
# exclusively (`c-<guid>-<pid>`), carries an ownership marker, and is validated
# against that marker, its absolute parent and its reparse classification before
# anything is removed. The shared `artifacts\staging` namespace itself is never a
# removal target, and no fixed scratch name is used, so two concurrent runs
# cannot delete each other's fixtures.
# ---------------------------------------------------------------------------
$stagingNamespace = Join-Path $repositoryRoot 'artifacts\staging'
$scratchGuid = ([guid]::NewGuid()).ToString('N')
$scratchName = "c-$scratchGuid-$PID"
$cRevitWorkspace = Join-Path $stagingNamespace $scratchName
$scratchMarkerName = '.ownership.json'
$actorName = if ($env:USERNAME) { [string]$env:USERNAME } else { 'unknown' }

# The workspace is never reset by deleting a fixed path: a stale fixed-name
# directory is reported, not removed, because it may belong to another run.
foreach ($fixedScratchName in @('c-revit-guard', 'c-revit-bundles')) {
    $fixedScratch = Join-Path $stagingNamespace $fixedScratchName
    Assert-Pass (-not (Test-Path -LiteralPath $fixedScratch)) "A fixed-name Revit scratch directory is present at $fixedScratch; this test must use a run-scoped scratch instead."
}

New-Item -ItemType Directory -Force -Path $cRevitWorkspace | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $cRevitWorkspace $scratchMarkerName),
    ([ordered]@{
        member = 'C'
        guid = $scratchGuid
        pid = $PID
        actor = $actorName
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        absolutePath = [IO.Path]::GetFullPath($cRevitWorkspace)
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
        if ($candidate.Name -notmatch '^c-[0-9a-f]{32}-\d+$') { continue }
        $legacy += [string]$candidate.Name
    }
    [pscustomobject]@{ Legacy = @($legacy) }
}

function Assert-ScratchOwnership([string]$Path) {
    # Fail closed unless this directory is provably this run's own scratch: the
    # name pattern, the exact staging parent, the non-reparse classification of
    # the directory and of every existing parent, and the ownership marker whose
    # member, guid, pid and absolute path match this run.
    Assert-Pass ([IO.Path]::GetFileName($Path) -match '^c-[0-9a-f]{32}-\d+$') "Refusing to use a scratch directory whose name is not a run-scoped c-<guid>-<pid> name: $Path"
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
        Write-Host "NOTE found $(@($legacyScratchReport.Legacy).Count) legacy Revit scratch director$(if (@($legacyScratchReport.Legacy).Count -eq 1) { 'y' } else { 'ies' }) from other runs; reported and left untouched: $(@($legacyScratchReport.Legacy) -join ', ')"
    }
    $markerPath = Join-Path $Path $scratchMarkerName
    Assert-Pass (Test-Path -LiteralPath $markerPath -PathType Leaf) "The ownership marker is missing from the scratch directory $Path."
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    foreach ($pair in @(@('member', 'C'), @('guid', $scratchGuid), @('pid', $PID), @('absolutePath', [IO.Path]::GetFullPath($Path)))) {
        $property = $marker.PSObject.Properties[[string]$pair[0]]
        Assert-Pass ($null -ne $property -and [string]$property.Value -eq [string]$pair[1]) "The ownership marker of $Path does not record $($pair[0]) = $($pair[1])."
    }
}

Assert-ScratchOwnership $cRevitWorkspace
# Repository-external trees, used only for sentinel and junction-target fixtures
# that are never passed to a removal path of their own. They are run-scoped as
# well, so concurrent runs cannot collide and no fixed TEMP root is ever removed.
$tempRoot = ([IO.Path]::GetTempPath()).TrimEnd('\')
$externalSentinelRoot = Join-Path $tempRoot "bim-bridge-revit-containment-external-$scratchGuid"
$intermediateJunctionTarget = Join-Path $tempRoot "bim-bridge-revit-junction-target-$scratchGuid"
foreach ($externalFixture in @($externalSentinelRoot, $intermediateJunctionTarget)) {
    if (Test-Path -LiteralPath $externalFixture) {
        Assert-Pass (-not (Test-LinkReparsePoint $externalFixture)) "Refusing to reset the link reparse point at $externalFixture."
        Remove-Item -LiteralPath $externalFixture -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $externalFixture | Out-Null
}

# The builder itself, not the CI runner, is the contract under test: its own
# argument binder must reject an unsafe staging directory before it compiles.
$unsafeExternalSentinel = Join-Path $externalSentinelRoot 'outside-controlled\outside-sentinel.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unsafeExternalSentinel) | Out-Null
Set-Content -LiteralPath $unsafeExternalSentinel -Value 'outside controlled sentinel' -Encoding ASCII
$unsafeOutsideRun = Invoke-RevitBuilder @('-Version', '2027', '-SkipUnavailable', '-StagingRoot', (Join-Path $cRevitWorkspace 'staging'), '-BundleDirectory', (Split-Path -Parent $unsafeExternalSentinel))
Assert-Pass ($unsafeOutsideRun.exitCode -ne 0) 'The real Revit builder accepted a repository-external bundle directory.'
Assert-Pass (([regex]::Replace($unsafeOutsideRun.text, '\s+', ' ')).Trim() -match 'Deletion containment') "The real builder refusal is not a containment refusal: $($unsafeOutsideRun.text)"
Assert-Pass (-not ($unsafeOutsideRun.text -match 'adapter build failed')) 'The real builder reached the build step before validating the staging directory.'
Assert-Pass (Test-Path -LiteralPath $unsafeExternalSentinel) 'The real builder deleted a repository-external sentinel file.'

$unsafeRootRun = Invoke-RevitBuilder @('-Version', '2027', '-SkipUnavailable', '-StagingRoot', (Join-Path $cRevitWorkspace 'staging'), '-BundleDirectory', $repositoryRoot)
Assert-Pass ($unsafeRootRun.exitCode -ne 0) 'The real Revit builder accepted the repository root as a bundle directory.'
$unsafeRenderRun = Invoke-RevitBuilder @('-Version', '2027', '-StagingRoot', (Join-Path $cRevitWorkspace 'staging'), '-RenderManifestDirectory', (Split-Path -Parent $repositoryRoot))
Assert-Pass ($unsafeRenderRun.exitCode -ne 0) 'The real Revit builder accepted the repository parent as a render directory.'
Assert-Pass (([regex]::Replace($unsafeRenderRun.text, '\s+', ' ')).Trim() -match 'Deletion containment') "The render-directory refusal is not a containment refusal: $($unsafeRenderRun.text)"

# Pure-guard checks: real system locations are classified, never deleted. Only
# the guard function definitions are extracted out of the builder: running the
# whole script here would also run its main body, and dot-sourcing it into this
# scope would leak its param() defaults over this test's own variables.
$guardFunctionNames = @(
    'Get-DirectorySegment',
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
Assert-Pass ($guardDefinitions.Count -eq $guardFunctionNames.Count) "Expected $($guardFunctionNames.Count) guard functions in the Revit build script, extracted $($guardDefinitions.Count)."
foreach ($guardFunctionName in $guardFunctionNames) {
    Assert-Pass (@($guardDefinitions | Where-Object { $_ -match "(?m)^function\s+$([regex]::Escape($guardFunctionName))\s*\(" }).Count -eq 1) "The guard function $guardFunctionName could not be extracted from the Revit build script."
}
Invoke-Expression ($guardDefinitions -join "`n")

$guardStagingRoot = Join-Path $cRevitWorkspace 'staging\revit-bundles'
New-Item -ItemType Directory -Force -Path $guardStagingRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $cRevitWorkspace 'guard-outside') | Out-Null
$containedProbe = Join-Path $guardStagingRoot 'bundle'
New-Item -ItemType Directory -Force -Path $containedProbe | Out-Null
Assert-Pass (([string](Assert-ContainedStagingDirectory $containedProbe $guardStagingRoot $repositoryRoot)) -eq $containedProbe) 'A direct child of the staging root must be accepted.'
Assert-Pass (([string](Assert-ContainedStagingDirectory $containedProbe.ToUpperInvariant() $guardStagingRoot $repositoryRoot)) -eq $containedProbe) 'Casing differences must not defeat containment.'
Assert-Pass ((Get-ExistingAncestorPath $containedProbe) -eq $containedProbe) 'The canonical resolver does not return an existing path unchanged.'

$driveRootMessage = Assert-Rejected 'drive root' { Assert-ContainedStagingDirectory ([IO.Path]::GetPathRoot($guardStagingRoot)) $guardStagingRoot $repositoryRoot }
$repoRootMessage = Assert-Rejected 'repository root' { Assert-ContainedStagingDirectory $repositoryRoot $guardStagingRoot $repositoryRoot }
$parentMessage = Assert-Rejected 'repository parent' { Assert-ContainedStagingDirectory (Split-Path -Parent $repositoryRoot) $guardStagingRoot $repositoryRoot }
$profileMessage = Assert-Rejected 'real user profile' { Assert-ContainedStagingDirectory ([Environment]::GetFolderPath('UserProfile')) $guardStagingRoot $repositoryRoot }
$installMessage = Assert-Rejected 'real Revit installation directory' { Assert-ContainedStagingDirectory (Join-Path ${env:ProgramFiles} 'Autodesk\Revit 2027') $guardStagingRoot $repositoryRoot }
foreach ($pair in @(@('drive root', $driveRootMessage), @('repository root', $repoRootMessage), @('repository parent', $parentMessage), @('user profile', $profileMessage), @('installation directory', $installMessage))) {
    Assert-Pass ($pair[1] -match 'outside the repository artifacts staging area' -or $pair[1] -match 'outside the staging root') "Rejection reason for $($pair[0]) is not a containment refusal: $($pair[1])"
}
$siblingMessage = Assert-Rejected 'sibling directory sharing the staging prefix' { Assert-ContainedStagingDirectory (Join-Path $cRevitWorkspace 'staging\revit-bundles-evil') $guardStagingRoot $repositoryRoot }
Assert-Pass ($siblingMessage -match 'outside the staging root') "The separator-terminated prefix comparison did not reject the sibling directory: $siblingMessage"
$rootItselfMessage = Assert-Rejected 'staging root itself' { Assert-ContainedStagingDirectory $guardStagingRoot $guardStagingRoot $repositoryRoot }
Assert-Pass ($rootItselfMessage -match 'never removed') "Removing the staging root itself was not refused: $rootItselfMessage"
$traversalMessage = Assert-Rejected 'relative traversal' { Assert-ContainedStagingDirectory ($guardStagingRoot + '\..\..\..') $guardStagingRoot $repositoryRoot }
Assert-Pass ($traversalMessage -match 'traversal|outside the staging root') "A traversal path was not refused as a traversal or a containment escape: $traversalMessage"
$relativeMessage = Assert-Rejected 'relative path' { Assert-ContainedStagingDirectory 'artifacts\staging\revit-bundles\x' $guardStagingRoot $repositoryRoot }
Assert-Pass ($relativeMessage -match 'absolute path') "A relative candidate was not refused: $relativeMessage"
$notYetCreated = Join-Path $guardStagingRoot 'never-created'
Assert-Pass (([string](Assert-ContainedStagingDirectory $notYetCreated $guardStagingRoot $repositoryRoot)) -eq $notYetCreated) 'A not-yet-created staging target was not returned unchanged.'
Assert-Pass (-not (Test-Path -LiteralPath $notYetCreated)) 'A not-yet-created staging target was created by the guard.'

# ---------------------------------------------------------------------------
# Regression 1 (A1): a *raw* `..` segment is refused before any
# canonicalisation, so `foo\..\bar` can no longer be folded into an accepted
# path. The refusal is matched on its prefix instead of a `-notmatch 'outside
# the'` probe: this repository's own path contains that phrase.
# ---------------------------------------------------------------------------
$traversalRefusalPrefix = 'Deletion containment: traversal is never accepted for a deletion target: '
$outsideStagingRefusalPattern = 'is outside the (repository artifacts staging area|staging root)'
$rawTraversalCandidate = "$guardStagingRoot\foo\..\bar"
$rawTraversalMessage = Assert-Rejected 'raw foo\..\bar segment' { Assert-ContainedStagingDirectory $rawTraversalCandidate $guardStagingRoot $repositoryRoot }
Assert-Pass ($rawTraversalMessage.StartsWith($traversalRefusalPrefix, [StringComparison]::Ordinal)) "A raw foo..bar segment was not refused by the pre-canonicalisation traversal check: $rawTraversalMessage"
Assert-Pass (-not ($rawTraversalMessage -match $outsideStagingRefusalPattern)) "A raw foo..bar segment was refused as an out-of-namespace path instead of a traversal: $rawTraversalMessage"
Assert-Pass ($rawTraversalMessage.Substring($traversalRefusalPrefix.Length) -ceq $rawTraversalCandidate) "The raw traversal refusal does not name its own candidate: $rawTraversalMessage"

# ---------------------------------------------------------------------------
# Regression 2 (A1): a traversal that still *collapses* inside the staging root
# must also be refused, and refused as a traversal rather than as "outside
# staging": `...\x\..\<staging-root-name>` folds back onto the staging root.
# The message prefix also proves it is not the plain "staging root itself" rule.
# ---------------------------------------------------------------------------
$collapsingName = [IO.Path]::GetFileName($guardStagingRoot)
$collapsingTraversalCandidate = "$guardStagingRoot\x\..\$collapsingName"
$collapsingTraversalMessage = Assert-Rejected 'traversal collapsing inside the staging root' { Assert-ContainedStagingDirectory $collapsingTraversalCandidate $guardStagingRoot $repositoryRoot }
Assert-Pass ($collapsingTraversalMessage.StartsWith($traversalRefusalPrefix, [StringComparison]::Ordinal)) "A traversal that collapses inside the staging root was not refused by the pre-canonicalisation traversal check: $collapsingTraversalMessage"
Assert-Pass (-not ($collapsingTraversalMessage -match $outsideStagingRefusalPattern)) "A traversal that collapses inside the staging root was refused as an out-of-namespace path instead of a traversal: $collapsingTraversalMessage"
Assert-Pass ($collapsingTraversalMessage.Substring($traversalRefusalPrefix.Length) -ceq $collapsingTraversalCandidate) "The collapsing traversal refusal does not name its own candidate: $collapsingTraversalMessage"

# A reparse point may only be used when the host actually permits creating one.
$guardOutside = Join-Path $cRevitWorkspace 'guard-outside'
$junctionPath = Join-Path $guardOutside 'junction-to-staging'
$hasJunction = $false
try {
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$junctionPath" "$guardStagingRoot" 2>&1 | Out-Null
    $hasJunction = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $junctionPath)
} catch { $hasJunction = $false }
if ($hasJunction) {
    $junctionMessage = Assert-Rejected 'junction escape' { Assert-ContainedStagingDirectory (Join-Path $junctionPath 'bundle') $guardStagingRoot $repositoryRoot }
    Assert-Pass ($junctionMessage -match 'outside the staging root') "A junction escape was not refused with a containment reason: $junctionMessage"
    $junctionTargetMessage = Assert-Rejected 'junction as the deletion target itself' { Assert-ContainedStagingDirectory $junctionPath $guardStagingRoot $repositoryRoot }
    Assert-Pass ($junctionTargetMessage -match 'outside|reparse point') "A junction deletion target was not refused: $junctionTargetMessage"
    # A junction that *is* lexically inside the staging root must still be
    # refused, because it redirects the recursive delete out of that root.
    $containedJunction = Join-Path $guardStagingRoot 'contained-junction'
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$containedJunction" "$guardOutside" 2>&1 | Out-Null
    Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $containedJunction)) 'The host refused to create the contained junction fixture.'
    $containedJunctionMessage = Assert-Rejected 'junction inside the staging root' { Assert-ContainedStagingDirectory $containedJunction $guardStagingRoot $repositoryRoot }
    Assert-Pass ($containedJunctionMessage -match 'reparse point') "A junction inside the staging root was not refused as a reparse point: $containedJunctionMessage"
    Assert-Pass (Test-Path -LiteralPath $containedJunction) 'The contained junction fixture disappeared during the pure guard checks.'
    Assert-Pass (Test-Path -LiteralPath $junctionPath) 'The junction escape fixture disappeared during the pure guard checks.'
} else {
    throw 'The host refused to create the junction fixture, so the reparse escape case cannot be proven. See the handoff notes; this is not skipped silently.'
}
Assert-Pass ((Get-DirectorySegment $guardStagingRoot).Count -gt 1) 'Internal segment helper regression.'

# ---------------------------------------------------------------------------
# P0-A chain coverage, symmetric with the AutoCAD suite: the walk must classify
# every existing directory from the repository root down to *and including* the
# containment root (`artifacts\staging`). A junction at the `artifacts` level, and
# a junction that *is* the containment root, previously went unclassified because
# the walk started after the containment root. Both must fail closed before any
# write or delete, with the external witness intact, and an ordinary junction-free
# chain must still be accepted.
# ---------------------------------------------------------------------------
$chainUmbrella = Join-Path $tempRoot "bim-bridge-revit-chain-$scratchGuid"
$chainArtifactsRepository = Join-Path $chainUmbrella 'artifacts-level-repo'
$chainContainmentRepository = Join-Path $chainUmbrella 'containment-level-repo'
$chainJunctionTarget = Join-Path $chainUmbrella 'junction-target'
$chainArtifactsTarget = Join-Path $chainUmbrella 'artifacts-target'
$chainWitness = Join-Path $chainJunctionTarget 'containment-root-witness.txt'
New-Item -ItemType Directory -Force -Path $chainArtifactsRepository | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainContainmentRepository 'artifacts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainJunctionTarget 'staging\revit-bundles') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $chainArtifactsTarget 'staging\revit-bundles') | Out-Null
Set-Content -LiteralPath $chainWitness -Value 'containment root witness must survive' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $chainArtifactsTarget 'staging\revit-bundles\artifacts-level.dll') -Value 'artifacts level content' -Encoding ASCII
$chainWitnessHash = (Get-FileHash -LiteralPath $chainWitness -Algorithm SHA256).Hash
$chainTargetFileCount = @(Get-ChildItem -LiteralPath $chainJunctionTarget -Recurse -File -Force).Count
$chainArtifactsTargetFileCount = @(Get-ChildItem -LiteralPath $chainArtifactsTarget -Recurse -File -Force).Count
Assert-Pass ((Split-Path -Parent $chainUmbrella) -eq $tempRoot) 'The containment-chain umbrella is not a direct child of the system temp root.'
Assert-Pass (-not $chainUmbrella.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-chain umbrella is not actually outside the repository.'
Assert-Pass (-not $chainArtifactsRepository.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The artifacts-level fake repository is not actually outside the repository.'
Assert-Pass (-not $chainContainmentRepository.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-level fake repository is not actually outside the repository.'
Assert-Pass (-not $chainJunctionTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The containment-chain junction target is not actually outside the repository.'
Assert-Pass (-not $chainArtifactsTarget.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) 'The artifacts-level junction target is not actually outside the repository.'

# Case A: the junction sits at `artifacts`, one level above the containment root.
$chainArtifactsJunction = Join-Path $chainArtifactsRepository 'artifacts'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$chainArtifactsJunction" "$chainArtifactsTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $chainArtifactsJunction)) "The host refused to create the artifacts-level junction fixture at $chainArtifactsJunction."
Assert-Pass (Test-LinkReparsePoint $chainArtifactsJunction) 'The artifacts-level junction fixture is not classified as a link reparse point.'
$chainIntermediateStagingRoot = Join-Path $chainArtifactsJunction 'staging\revit-bundles'
$chainIntermediateBundle = Join-Path $chainIntermediateStagingRoot 'bundle'
$chainIntermediateMessage = $null
try { $null = Assert-ContainedStagingDirectory $chainIntermediateBundle $chainIntermediateStagingRoot $chainArtifactsRepository } catch { $chainIntermediateMessage = [string]$_.Exception.Message }
Assert-Pass (-not [string]::IsNullOrWhiteSpace($chainIntermediateMessage)) 'A junction at the artifacts level of the containment chain was accepted instead of failing closed.'
Assert-Pass ($chainIntermediateMessage -match 'is a reparse point \(junction or symbolic link\) on the path from the repository root to the containment root') "The artifacts-level junction was refused by something other than the containment-chain walk: $chainIntermediateMessage"
Assert-Pass ($chainIntermediateMessage.Contains($chainArtifactsJunction)) "The artifacts-level refusal does not name the offending junction '$chainArtifactsJunction': $chainIntermediateMessage"
Assert-Pass (-not (Test-Path -LiteralPath $chainIntermediateBundle)) 'The artifacts-level refusal created the bundle directory it refused to stage.'
Assert-Pass (@(Get-ChildItem -LiteralPath $chainArtifactsTarget -Recurse -File -Force).Count -eq $chainArtifactsTargetFileCount) 'The artifacts-level refusal changed the external target file count.'
Assert-Pass (-not ($chainIntermediateMessage -match 'between the repository artifacts staging area and the staging root')) "The artifacts-level junction was still classified by the older staging-root walk: $chainIntermediateMessage"

# Case B: the junction *is* the containment root (`artifacts\staging`), inside a
# real `artifacts` directory, which the previous walk never classified at all.
$chainContainmentJunction = Join-Path $chainContainmentRepository 'artifacts\staging'
& (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$chainContainmentJunction" "$chainJunctionTarget" 2>&1 | Out-Null
Assert-Pass (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $chainContainmentJunction)) "The host refused to create the containment-root junction fixture at $chainContainmentJunction."
Assert-Pass (Test-LinkReparsePoint $chainContainmentJunction) 'The containment-root junction fixture is not classified as a link reparse point.'
$chainContainmentStagingRoot = Join-Path $chainContainmentJunction 'revit-bundles'
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
$chainRealStagingRoot = Join-Path $chainRealRepository 'artifacts\staging\revit-bundles'
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
$repoRootUmbrella = Join-Path $tempRoot "bim-bridge-revit-reporoot-$repoRootGuid"
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
$repoRootMessage = Assert-Rejected 'repository root is a junction' { Get-SafeStagingRoot (Join-Path $repoRootContainment 'revit-bundles') $repoRootContainment }
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
# The `artifacts`-level junction must never be cleaned by walking through it.
if (Test-Path -LiteralPath $chainArtifactsJunction) { & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c rmdir "$chainArtifactsJunction" 2>&1 | Out-Null }
if (Test-Path -LiteralPath $chainContainmentJunction) { & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c rmdir "$chainContainmentJunction" 2>&1 | Out-Null }
Assert-Pass (Test-Path -LiteralPath (Join-Path $chainArtifactsTarget 'staging\revit-bundles\artifacts-level.dll')) 'De-linking the artifacts-level junction destroyed the external target content.'

# ---------------------------------------------------------------------------
# Execution-shape tests: positive cleanup inside staging, and "no deletion ever
# happens before validation" proven with sentinel files that must survive.
# ---------------------------------------------------------------------------
$stagingWorkspace = Join-Path $cRevitWorkspace 'staging'
$siblingSentinel = Join-Path $cRevitWorkspace 'staging-sibling\sibling-sentinel.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $siblingSentinel) | Out-Null
Set-Content -LiteralPath $siblingSentinel -Value 'sibling sentinel must survive' -Encoding ASCII
$siblingSentinelHash = (Get-FileHash -LiteralPath $siblingSentinel -Algorithm SHA256).Hash

$bundleFixture = Join-Path $stagingWorkspace 'revit-bundles\candidate-bundle'
New-Item -ItemType Directory -Force -Path (Join-Path $bundleFixture 'src\BimBridge.Revit\bin\Debug\2999') | Out-Null
Set-Content -LiteralPath (Join-Path $bundleFixture 'src\BimBridge.Revit\bin\Debug\2999\stale.dll') -Value 'stale product' -Encoding ASCII
$containedCanonical = Assert-ContainedStagingDirectory $bundleFixture (Join-Path $stagingWorkspace 'revit-bundles') $repositoryRoot
Assert-Pass ($containedCanonical -eq $bundleFixture) 'A contained staging directory was not accepted for cleanup.'
Remove-Item -LiteralPath $containedCanonical -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $bundleFixture)) 'Positive case: the staging directory still holds its own stale product after cleanup.'
Assert-Pass (Test-Path -LiteralPath $siblingSentinel) 'Positive case: the sibling sentinel next to the staging directory was removed.'
Assert-Pass ((Get-FileHash -LiteralPath $siblingSentinel -Algorithm SHA256).Hash -eq $siblingSentinelHash) 'Positive case: the sibling sentinel content changed.'

# The reparse-point escape fixture: the sentinel lives outside every staging
# root, and the junction inside staging must never let a removal reach it.
$escapeJunction = Join-Path $stagingWorkspace 'revit-bundles\escape-junction'
$escapedContent = Join-Path $cRevitWorkspace 'escaped-content'
New-Item -ItemType Directory -Force -Path $escapedContent | Out-Null
$escapeWitness = Join-Path $escapedContent 'escape-witness.txt'
Set-Content -LiteralPath $escapeWitness -Value 'must not be removed' -Encoding ASCII
$escapeJunctionReady = $false
try {
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c mklink /J "$escapeJunction" "$escapedContent" 2>&1 | Out-Null
    $escapeJunctionReady = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $escapeJunction)
} catch { $escapeJunctionReady = $false }
Assert-Pass $escapeJunctionReady 'The host refused to create the reparse-point escape fixture.'
Assert-Pass ((Split-Path -Parent $escapeJunction) -eq (Join-Path $stagingWorkspace 'revit-bundles')) 'The escape fixture is not inside the staging root.'

# This is the exact production sequence: validate, and only then remove.
function Invoke-GuardedBundleRemoval([string]$Candidate, [string]$RemovalStagingRoot = (Join-Path $stagingWorkspace 'revit-bundles')) {
    $canonical = Assert-ContainedStagingDirectory $Candidate $RemovalStagingRoot $repositoryRoot
    if (Test-Path -LiteralPath $canonical) { Remove-Item -LiteralPath $canonical -Recurse -Force }
    $canonical
}

$escapeCases = @(
    @{ label = 'repository-external controlled directory'; candidate = (Split-Path -Parent $unsafeExternalSentinel); sentinel = $unsafeExternalSentinel },
    @{ label = 'repository root'; candidate = $repositoryRoot; sentinel = $unsafeExternalSentinel },
    @{ label = 'repository parent'; candidate = (Split-Path -Parent $repositoryRoot); sentinel = $unsafeExternalSentinel },
    @{ label = 'traversal path'; candidate = (Join-Path $cRevitWorkspace 'staging\revit-bundles\..\..\..\..'); sentinel = $unsafeExternalSentinel },
    @{ label = 'reparse point escape'; candidate = (Join-Path $escapeJunction 'src'); sentinel = $escapeWitness }
)
foreach ($case in $escapeCases) {
    $message = $null
    try { $null = Invoke-GuardedBundleRemoval $case.candidate } catch { $message = [string]$_.Exception.Message }
    Assert-Pass (-not [string]::IsNullOrWhiteSpace($message)) "Guarded removal accepted the $($case.label) instead of refusing it."
    Assert-Pass (Test-Path -LiteralPath $case.sentinel) "The sentinel for the $($case.label) was deleted, so a removal ran before validation."
    Assert-Pass (-not [string]::IsNullOrWhiteSpace((Get-FileHash -LiteralPath $case.sentinel -Algorithm SHA256).Hash)) "The sentinel for the $($case.label) is unreadable."
}
Assert-Pass (Test-Path -LiteralPath $unsafeExternalSentinel) 'The repository-external controlled sentinel was removed.'
Assert-Pass (Test-Path -LiteralPath $escapeWitness) 'The reparse-point target witness was removed.'
Assert-Pass (Test-Path -LiteralPath $escapeJunction) 'The reparse-point fixture was removed.'

# ---------------------------------------------------------------------------
# Intermediate-segment junction (A2), execution shape: the junction sits between
# the repository artifacts staging namespace and the staging root, so classifying
# only the final staging-root item is not enough. The junction points at a
# controlled directory inside the system temp root, which holds a witness that
# must still exist after the refusal, and the removal path is the exact
# production sequence (validate, and only then remove).
# ---------------------------------------------------------------------------
$intermediateJunctionParent = Join-Path $cRevitWorkspace 'intermediate-junction'
$intermediateJunctionName = "junction-$scratchGuid"
$intermediateJunctionPath = Join-Path $intermediateJunctionParent $intermediateJunctionName
$intermediateJunctionStagingRoot = Join-Path $intermediateJunctionPath 'revit-bundles'
$intermediateJunctionBundle = Join-Path $intermediateJunctionStagingRoot 'bundle'
$intermediateWitness = Join-Path $intermediateJunctionTarget 'junction-target-witness.txt'
New-Item -ItemType Directory -Force -Path $intermediateJunctionParent | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $intermediateJunctionTarget 'revit-bundles\bundle') | Out-Null
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
Assert-Pass (Test-Path -LiteralPath $unsafeExternalSentinel) 'The intermediate-junction refusal reached the repository-external sentinel.'
Assert-Pass (Test-Path -LiteralPath $siblingSentinel) 'The intermediate-junction refusal reached the staging sibling sentinel.'

# ---------------------------------------------------------------------------
# -Offline (NuGet audit) behaviour, execution shape. `dotnet` is intercepted by
# a recording shim inside this run's scratch directory: the shim writes the exact
# argument line it received to a private file and then invokes the real `dotnet`
# with the untouched arguments, so the switch contract is observed on a real
# invocation instead of inferred from the source text alone. `-p:NuGetAudit=false`
# must only ever reach MSBuild when the caller passed `-Offline`; the default and
# hosted-CI path must keep the vulnerability audit enabled.
# ---------------------------------------------------------------------------
$recordDirectory = Join-Path $cRevitWorkspace 'recorded'
$shimDirectory = Join-Path $cRevitWorkspace 'shim'
New-Item -ItemType Directory -Force -Path $recordDirectory, $shimDirectory | Out-Null
$realDotnetPath = $null
foreach ($candidate in @(Get-Command dotnet -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })) {
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    if ([string]::IsNullOrWhiteSpace($realDotnetPath)) { $realDotnetPath = $item.FullName }
}
Assert-Pass (-not [string]::IsNullOrWhiteSpace($realDotnetPath)) 'The real dotnet host could not be located for the recording shim.'

function Invoke-RecordedRevitBuilder([string[]]$BuilderArguments, [string]$RecordName) {
    $recordPath = Join-Path $recordDirectory "$RecordName.txt"
    if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }
    $shimBody = @"
@echo off
echo %*>"$recordPath"
"$realDotnetPath" %*
exit /b %ERRORLEVEL%
"@
    $shimPath = Join-Path $shimDirectory 'dotnet.cmd'
    [IO.File]::WriteAllText($shimPath, ($shimBody -replace "`r?`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    $run = Invoke-RevitBuilder $BuilderArguments $shimDirectory
    $recorded = ''
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) { $recorded = (Get-Content -LiteralPath $recordPath -Raw).Trim() }
    [pscustomobject]@{ run = $run; recorded = $recorded; recordPath = $recordPath }
}

# Each recorded run owns its output path exclusively: the release output
# directory is removed first, so a build product left over from an earlier run
# can never mask a recorded invocation that did not reach the build itself.
function Remove-RecordedRevitOutputDirectory([string]$Year) {
    $yearRoot = Join-Path $repositoryRoot "src\BimBridge.Revit\bin\Debug\$Year"
    if (-not (Test-Path -LiteralPath $yearRoot)) { return }
    Assert-Pass ((Split-Path -Parent $yearRoot) -eq (Join-Path $repositoryRoot 'src\BimBridge.Revit\bin\Debug')) 'Refusing to reset a Revit output directory outside the repository build output.'
    Assert-Pass (-not (Test-LinkReparsePoint $yearRoot)) "Refusing to reset the link reparse point at $yearRoot."
    Remove-Item -LiteralPath $yearRoot -Recurse -Force
}

$offlineYear = '2024'
$offlineTargetFramework = [string]$entryByYear[$offlineYear].RevitTargetFramework
Remove-RecordedRevitOutputDirectory $offlineYear
$offlineRecordedRun = Invoke-RecordedRevitBuilder @('-Version', $offlineYear, '-Offline') 'offline-on'
Assert-Pass ($offlineRecordedRun.run.exitCode -eq 0) "The -Offline staging-root invocation failed: $($offlineRecordedRun.run.text)"
Assert-Pass (-not [string]::IsNullOrWhiteSpace($offlineRecordedRun.recorded)) "The recording shim never saw a dotnet invocation: $($offlineRecordedRun.run.text)"
Assert-Pass ($offlineRecordedRun.recorded -like 'build*BimBridge.Revit.csproj*') "The recorded dotnet invocation is not the Revit builder's own build: $($offlineRecordedRun.recorded)"
Assert-Pass ($offlineRecordedRun.recorded -like '*-p:NuGetAudit=false*') "The Revit builder did not pass -p:NuGetAudit=false with -Offline: $($offlineRecordedRun.recorded)"
Assert-Pass (@([regex]::Matches($offlineRecordedRun.recorded, [regex]::Escape('-p:NuGetAudit=false'))).Count -eq 1) "The Revit builder passed the audit switch more than once: $($offlineRecordedRun.recorded)"
Assert-Pass (Test-Path -LiteralPath (Join-Path $repositoryRoot "src\BimBridge.Revit\bin\Debug\$offlineYear\$offlineTargetFramework\BimBridge.Revit$offlineYear.dll") -PathType Leaf) 'The recorded run did not reach its build output.'

Remove-RecordedRevitOutputDirectory $offlineYear
$defaultRecordedRun = Invoke-RecordedRevitBuilder @('-Version', $offlineYear) 'offline-off'
Assert-Pass ($defaultRecordedRun.run.exitCode -eq 0) "The default (audit-on) invocation failed: $($defaultRecordedRun.run.text)"
Assert-Pass (-not [string]::IsNullOrWhiteSpace($defaultRecordedRun.recorded)) "The recording shim never saw a dotnet invocation: $($defaultRecordedRun.run.text)"
Assert-Pass ($defaultRecordedRun.recorded -notlike '*NuGetAudit*') "The Revit builder disabled the NuGet vulnerability audit without -Offline: $($defaultRecordedRun.recorded)"
Assert-Pass ($defaultRecordedRun.recorded -like 'build*BimBridge.Revit.csproj*') "The default recorded invocation is not the Revit builder's own build: $($defaultRecordedRun.recorded)"
Assert-Pass ($defaultRecordedRun.recorded -notmatch '--offline') "The Revit builder passed an offline restore switch: $($defaultRecordedRun.recorded)"

# A render-only run never reaches dotnet at all, and -Offline is still accepted
# (and still inert) on that path, so a machine with no adapter build can verify
# the switch binding.
$renderRootFixture = Join-Path $stagingWorkspace 'revit-renders\render'
$renderRun = Invoke-RevitBuilder @('-Version', '2027', '-Offline', '-StagingRoot', (Join-Path $stagingWorkspace 'revit-renders'), '-RenderManifestDirectory', $renderRootFixture, '-RenderAssemblyPathTemplate', '{assemblyName}.dll')
Assert-Pass ($renderRun.exitCode -eq 0) "The explicit render-staging invocation with -Offline failed: $($renderRun.text)"
$renderPayload = ConvertFrom-Json (Get-BuilderJsonPayload $renderRun.text)
$renderedRows = @((Get-PropertyValue $renderPayload 'renderedManifests'))
Assert-Pass ($renderedRows.Count -eq 1) 'The render-staging envelope does not report one rendered manifest.'
$renderedManifestPath = [string](Get-PropertyValue @($renderedRows)[0] 'manifest')
Assert-Pass (-not [string]::IsNullOrWhiteSpace($renderedManifestPath)) 'The render-staging envelope reports no manifest path.'
Assert-Pass (Test-Path -LiteralPath $renderedManifestPath -PathType Leaf) "The render-staging run produced no manifest: $renderedManifestPath"
Assert-Pass (([IO.Path]::GetFullPath($renderedManifestPath)).StartsWith($renderRootFixture + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "The rendered manifest was written outside the requested render staging directory: $renderedManifestPath"
Assert-Pass ([string][IO.Path]::GetFileName($renderedManifestPath) -eq 'BimBridge.Revit2027.addin') 'The rendered manifest has the wrong file name.'
[xml]$renderedManifestXml = Get-Content -LiteralPath $renderedManifestPath -Raw
Assert-Pass ([string]$renderedManifestXml.RevitAddIns.AddIn.Assembly -eq 'BimBridge.Revit2027.dll') 'The rendered manifest lost its assembly path token.'

# ---------------------------------------------------------------------------
# Real-builder execution shape, using only installed releases and only staging
# directories this test created itself.
# ---------------------------------------------------------------------------
$realBundle = Join-Path $stagingWorkspace 'revit-bundles\real-bundle'
New-Item -ItemType Directory -Force -Path $realBundle | Out-Null
$staleFile = Join-Path $realBundle 'src\BimBridge.Revit\bin\Debug\2999\stale-product.dll'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $staleFile) | Out-Null
Set-Content -LiteralPath $staleFile -Value 'stale product from a previous stage' -Encoding ASCII

$bundleRun = Invoke-RevitBuilder @('-Version', '2024,2026', '-SkipUnavailable', '-StagingRoot', (Join-Path $stagingWorkspace 'revit-bundles'), '-BundleDirectory', $realBundle)
Assert-Pass ($bundleRun.exitCode -eq 0) "The explicit staging builder invocation failed: $($bundleRun.text)"
$bundlePayload = ConvertFrom-Json (Get-BuilderJsonPayload $bundleRun.text)
$bundleResults = @((Get-PropertyValue $bundlePayload 'results'))
Assert-Pass ($bundleResults.Count -eq 2) "The explicit staging envelope does not carry two result rows: $($bundleRun.text)"
Assert-Pass (@($bundleResults | Where-Object { [string]$_.version -eq '2024' -and [string]$_.status -eq 'built' }).Count -eq 1) 'The explicit staging envelope lost the built Revit 2024 row.'
Assert-Pass (@($bundleResults | Where-Object { [string]$_.version -eq '2026' -and [string]$_.status -eq 'unavailable' }).Count -eq 1) 'The explicit staging envelope lost the unavailable Revit 2026 row.'
$bundleSection = Get-PropertyValue $bundlePayload 'bundle'
Assert-Pass ((Get-PropertyValue $bundleSection 'bundleDirectory') -eq $realBundle) 'The envelope bundle directory is not the requested staging directory.'
$manifestPath = Join-Path $realBundle 'bundle-manifest.json'
Assert-Pass (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The staged bundle has no bundle-manifest.json.'
Assert-Pass (-not (Test-Path -LiteralPath $staleFile)) 'Positive case: the stale product inside the bundle survived the rebuild.'
$bundleManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-Pass (@((Get-PropertyValue $bundleManifest 'files')).Count -ge 1) 'The staged Revit index carries no file entries.'
$bundleRootFull = [IO.Path]::GetFullPath($realBundle)
foreach ($entry in @((Get-PropertyValue $bundleManifest 'files'))) {
    # Contract (docs/architecture.md, "Staged packages, builder output, and
    # gaps"): the Revit staging index uses forward slashes relative to the bundle
    # root, and repeats the same value in `path` and `relativePath`.
    Assert-Pass (-not ([string]$entry.relativePath).Contains('\')) "A staged index path is not forward-slash normalised: $($entry.relativePath)"
    Assert-Pass (-not ([string]$entry.relativePath).StartsWith('/')) "A staged index path is not relative to the bundle root: $($entry.relativePath)"
    Assert-Pass ([string]$entry.path -eq [string]$entry.relativePath) "The staged index path and relativePath bases diverged: $($entry.path) vs $($entry.relativePath)"
    Assert-Pass (Test-Path -LiteralPath (Join-Path $bundleRootFull ([string]$entry.relativePath -replace '/', '\')) -PathType Leaf) "A staged index entry does not resolve from the bundle root: $($entry.relativePath)"
}
$unavailable = @((Get-PropertyValue $bundleManifest 'unavailableReleases'))
Assert-Pass (@($unavailable | Where-Object { [string]$_.id -eq 'revit-2026-not-installed' }).Count -eq 1) 'The staged index lost the revit-2026-not-installed gap record.'
Assert-Pass (@($unavailable | Where-Object { [string]$_.id -eq 'revit-2026-not-installed' -and @($_.probeEvidence.probes).Count -gt 0 }).Count -eq 1) 'The staged gap record lost its probe evidence.'
Assert-Pass (@($unavailable | Where-Object { [string]$_.severity -eq 'blocking' -and $_.fakeSuccess -eq $false }).Count -eq 1) 'The staged gap record is not a blocking, non-fabricated gap.'
Assert-Pass (Test-Path -LiteralPath $siblingSentinel) 'The sibling sentinel outside the staging root was removed by the real builder.'
Assert-Pass ((Get-FileHash -LiteralPath $siblingSentinel -Algorithm SHA256).Hash -eq $siblingSentinelHash) 'The sibling sentinel outside the staging root changed content.'
Assert-Pass (Test-Path -LiteralPath $escapeWitness) 'The real builder reached the reparse-point escape witness.'
Assert-Pass (Test-Path -LiteralPath $unsafeExternalSentinel) 'The real builder reached the repository-external sentinel.'
Assert-Pass (Test-Path -LiteralPath $intermediateWitness) 'The real builder reached the intermediate-junction witness.'

# Legacy default output: with neither -BundleDirectory nor
# -RenderManifestDirectory the top-level JSON array contract is preserved.
$legacyRun = Invoke-RevitBuilder @('-Version', '2027')
Assert-Pass ($legacyRun.exitCode -eq 0) "The default (no staging) builder invocation failed: $($legacyRun.text)"
$legacyJson = Get-BuilderJsonPayload $legacyRun.text
Assert-Pass ($legacyJson.TrimStart().StartsWith('[')) 'The default output does not start with a JSON array.'
$legacyParse = ConvertFrom-Json $legacyJson
Assert-Pass (@($legacyParse).Count -eq 1) 'The default output is not iterable as an array after ConvertFrom-Json.'
Assert-Pass (@($legacyParse | Where-Object { [string]$_.version -eq '2027' }).Count -eq 1) 'The default output lost the Revit 2027 result row.'
Assert-Pass ((Get-PropertyValue $legacyParse 'bundle') -eq $null -and (Get-PropertyValue $legacyParse 'results') -eq $null) 'The default output is still an envelope instead of the legacy array.'

# An unavailable release is still reported in the legacy array, with its gap id.
$gapRun = Invoke-RevitBuilder @('-Version', '2026', '-SkipUnavailable')
Assert-Pass ($gapRun.exitCode -eq 0) "The unavailable-release invocation failed: $($gapRun.text)"
$gapRows = @(ConvertFrom-Json (Get-BuilderJsonPayload $gapRun.text))
Assert-Pass (@($gapRows | Where-Object { [string]$_.status -eq 'unavailable' -and [string]$_.gap -eq 'revit-2026-not-installed' }).Count -eq 1) 'An unavailable release is not reported as an explicit revit-2026-not-installed gap row.'

# Cleanup only ever runs on scratch directories this test created itself. The
# intermediate junction is unlinked before the recursive removal of its scratch
# parent, so the recursive delete can never be the step that resolves it, and its
# out-of-repository target is asserted to be intact afterwards.
if (Test-Path -LiteralPath $intermediateJunctionPath) {
    Assert-Pass (Test-LinkReparsePoint $intermediateJunctionPath) "The intermediate junction fixture at $intermediateJunctionPath is not a link reparse point."
    # A junction is unlinked with [IO.Directory]::Delete, which removes the link
    # itself and never resolves it. Windows PowerShell's
    # `Remove-Item -LiteralPath <junction> -Force` (no -Recurse) throws
    # System.NullReferenceException on a junction whose target is non-empty,
    # before unlinking anything, which aborted this run's cleanup.
    [IO.Directory]::Delete($intermediateJunctionPath)
}
Assert-Pass (-not (Test-Path -LiteralPath $intermediateJunctionPath)) 'The intermediate junction fixture was not unlinked.'
Assert-Pass (Test-Path -LiteralPath (Join-Path $intermediateJunctionTarget 'revit-bundles\bundle')) 'Unlinking the intermediate junction removed content outside the repository.'
foreach ($target in @((Join-Path $stagingWorkspace 'revit-bundles'), $stagingWorkspace, (Join-Path $cRevitWorkspace 'staging-sibling'), $guardOutside, (Join-Path $cRevitWorkspace 'intermediate-junction'), $escapedContent, $recordDirectory, $shimDirectory)) {
    Assert-Pass ((Split-Path -Parent $target) -eq $cRevitWorkspace -or (Split-Path -Parent $target) -eq $stagingWorkspace) "Refusing to clean a scratch directory outside the run-scoped scratch root."
    if (Test-Path -LiteralPath $target) {
        Assert-Pass (-not (Test-LinkReparsePoint $target)) "Refusing to clean the link reparse point at $target."
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
# The run-scoped scratch is removed only after its own name pattern, absolute
# parent, non-reparse classification and ownership marker are re-verified. No other
# run's scratch is ever removed: the discovery helper is read-only, and this file
# contains no cross-run deletion path at all.
Assert-ScratchOwnership $cRevitWorkspace
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
                    $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and $inner.VariablePath.UserPath -ceq 'cRevitWorkspace'
                }, $true)
        }, $true))
Assert-Pass ($scratchDeletionSites.Count -ge 1) 'No run-scoped scratch removal site was found, so the cleanup contract is unproven.'
$crossRunDeletionSites = @($testSourceAst.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            if ($node.GetCommandName() -ne 'Remove-Item') { return $false }
            $walksSharedNamespace = $null -ne $node.Find({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    @('stagingNamespace', 'legacy', 'candidate', 'Legacy') -contains $inner.VariablePath.UserPath
                }, $true)
            $walksSharedNamespace
        }, $true))
Assert-Pass ($crossRunDeletionSites.Count -eq 0) "This suite contains $($crossRunDeletionSites.Count) deletion site(s) reaching a cross-run scratch variable, so another run's scratch could be deleted."
Assert-Pass (Test-Path -LiteralPath (Join-Path $cRevitWorkspace '.ownership.json')) 'The run-scoped ownership marker disappeared before cleanup.'
Assert-Pass ((Split-Path -Parent $cRevitWorkspace) -eq $stagingNamespace) "Refusing to clean a scratch directory outside the containment namespace."
Remove-Item -LiteralPath $cRevitWorkspace -Recurse -Force
Assert-Pass (-not (Test-Path -LiteralPath $cRevitWorkspace)) 'The containment scratch tree was not cleaned up.'
Assert-Pass (Test-Path -LiteralPath $stagingNamespace) 'Cleanup removed the shared artifacts staging namespace.'
foreach ($externalFixture in @($intermediateJunctionTarget, $externalSentinelRoot)) {
    Assert-Pass ((Split-Path -Parent $externalFixture) -eq $tempRoot) "Refusing to clean the repository-external fixture outside the system temp root."
    Assert-Pass (-not (Test-LinkReparsePoint $externalFixture)) "Refusing to clean the link reparse point at $externalFixture."
    Remove-Item -LiteralPath $externalFixture -Recurse -Force
    Assert-Pass (-not (Test-Path -LiteralPath $externalFixture)) "The repository-external fixture tree $externalFixture was not cleaned up."
}
Assert-Pass ((Split-Path -Parent $stagingNamespace) -eq (Join-Path $repositoryRoot 'artifacts')) 'The artifacts directory above the staging namespace disappeared during cleanup.'

[ordered]@{
    status = 'passed'
    releases = $years
    sharedProject = $projectPath
    checksPassed = $script:PassedChecks
} | ConvertTo-Json -Depth 3
