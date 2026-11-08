[CmdletBinding()]
param(
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDirectory))
}

$adapterRoot = Join-Path $SourceRoot 'adapters\kimi'
$skillRoot = Join-Path $adapterRoot 'skills\bim-bridge'
$statusScript = Join-Path $skillRoot 'scripts\Get-BimBridgeKimiStatus.ps1'
$configScript = Join-Path $skillRoot 'scripts\Get-BimBridgeKimiMcpConfig.ps1'
$launcherScript = Join-Path $skillRoot 'scripts\Start-BimBridgeKimiMcp.ps1'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$manifestPath = Join-Path $SourceRoot 'kimi.plugin.json'

foreach ($path in @($statusScript, $configScript, $launcherScript, $skillPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Kimi adapter file: $path" }
}

foreach ($script in @($statusScript, $configScript, $launcherScript)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell parse failure in $script`: $($errors[0].Message)" }
}
Write-Host 'PASS Kimi adapter scripts parse'

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.name -ne 'bim-bridge' -or [string]$manifest.skills -ne './adapters/kimi/skills/') {
    throw 'Kimi plugin manifest does not expose the BIM Bridge Kimi Skill.'
}
$pluginServer = $manifest.mcpServers.'bim-bridge'
if ([string]$pluginServer.command -ne 'powershell.exe' -or [string]$pluginServer.cwd -ne './adapters/kimi') {
    throw 'Kimi plugin manifest does not declare the expected relative stdio server.'
}
$pluginLauncherArgument = [string]@($pluginServer.args)[-1]
if ($pluginLauncherArgument -ne './skills/bim-bridge/scripts/Start-BimBridgeKimiMcp.ps1') {
    throw 'Kimi plugin manifest does not target its bundled launcher wrapper.'
}
if ([IO.Path]::IsPathRooted($pluginLauncherArgument) -or [IO.Path]::IsPathRooted([string]$pluginServer.cwd)) {
    throw 'Kimi plugin manifest must remain relocatable inside the managed plugin copy.'
}
Write-Host 'PASS Kimi plugin manifest is relocatable and bounded'

$skill = Get-Content -LiteralPath $skillPath -Raw
foreach ($required in @('type: prompt', 'whenToUse:', 'disableModelInvocation: false', '${KIMI_SKILL_DIR}')) {
    if (-not $skill.Contains($required)) { throw "Kimi Skill is missing required field or placeholder: $required" }
}
Write-Host 'PASS Kimi Skill uses supported frontmatter and Skill path resolution'

$config = (& $configScript) | ConvertFrom-Json
$server = $config.mcpServers.'bim-bridge'
if ([string]$server.command -ne 'powershell.exe' -or $server.PSObject.Properties['url']) {
    throw 'Generated Kimi MCP configuration is not a PowerShell stdio server.'
}
$generatedLauncher = [string]@($server.args)[-1]
if (-not [IO.Path]::IsPathRooted($generatedLauncher) -or
    [IO.Path]::GetFullPath($generatedLauncher) -ne [IO.Path]::GetFullPath($launcherScript)) {
    throw 'Generated Kimi MCP configuration does not target the absolute bundled launcher wrapper.'
}
Write-Host 'PASS Kimi project MCP configuration is absolute and deterministic'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-kimi-test-' + [Guid]::NewGuid().ToString('N'))
$hostRoot = Join-Path $temporaryRoot 'host\test'
$mcpRoot = Join-Path $hostRoot 'mcp-server'
$pythonRoot = Join-Path $hostRoot 'python'
New-Item -ItemType Directory -Force -Path $mcpRoot, $pythonRoot | Out-Null
try {
    $fakeLauncher = Join-Path $hostRoot 'Start-BimBridgeMcp.ps1'
    $fakePython = Join-Path $pythonRoot 'python.exe'
    $fakeServer = Join-Path $mcpRoot 'aec_mcp_server.py'
    Set-Content -LiteralPath $fakeLauncher -Value '[Console]::Out.WriteLine("fake-kimi-mcp:" + $env:BIM_BRIDGE_AGENT_ADAPTER)' -Encoding UTF8
    Set-Content -LiteralPath $fakePython -Value 'test' -Encoding UTF8
    Set-Content -LiteralPath $fakeServer -Value 'test' -Encoding UTF8
    $files = @($fakeLauncher, $fakePython, $fakeServer) | ForEach-Object {
        [ordered]@{ path=[IO.Path]::GetFullPath($_); sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($fakeLauncher)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
        files = $files
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8

    $status = (& $statusScript -StateRoot $temporaryRoot -KimiVersionOverride '0.28.1') | ConvertFrom-Json
    if ([string]$status.status -ne 'healthy' -or [string]$status.adapter -ne 'kimi') {
        throw "Healthy fixture returned unexpected status: $($status.status)"
    }
    Write-Host 'PASS Kimi read-only status accepts a healthy neutral Host'

    Set-Content -LiteralPath $fakeServer -Value 'changed' -Encoding UTF8
    $changed = (& $statusScript -StateRoot $temporaryRoot -KimiVersionOverride '0.28.1') | ConvertFrom-Json
    if ([string]$changed.status -ne 'needs_repair' -or @($changed.host.changedFiles).Count -ne 1) {
        throw 'Changed MCP server was not reported as a Host repair condition.'
    }
    Write-Host 'PASS Kimi read-only status detects changed Host files'

    $invalidState = Get-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Raw | ConvertFrom-Json
    $invalidState.PSObject.Properties.Remove('files')
    $invalidState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $invalid = (& $statusScript -StateRoot $temporaryRoot -KimiVersionOverride '0.28.1') | ConvertFrom-Json
    if ([string]$invalid.status -ne 'needs_repair' -or [string]$invalid.host.stateError -notmatch "missing 'files'") {
        throw 'Missing Host file manifest was not reported as a repair condition.'
    }
    Write-Host 'PASS Kimi read-only status fails closed on incomplete Host state'

    Set-Content -LiteralPath $fakeServer -Value 'test' -Encoding UTF8
    [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($fakeLauncher)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
        files = $files
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8

    $stderrPath = Join-Path $temporaryRoot 'stderr.txt'
    $output = (& powershell.exe -NoLogo -NoProfile -NonInteractive -File $launcherScript -StateRoot $temporaryRoot 2> $stderrPath) -join [Environment]::NewLine
    $processExitCode = $LASTEXITCODE
    $output = $output.Trim()
    if ($processExitCode -ne 0 -or $output -ne 'fake-kimi-mcp:kimi') {
        $stderr = Get-Content -LiteralPath $stderrPath -Raw
        throw "Verified Kimi launcher did not delegate with the Kimi adapter identity. $stderr"
    }
    Write-Host 'PASS Kimi launcher verifies and delegates to the neutral Host'

    $outsideLauncher = Join-Path $temporaryRoot 'outside-host.ps1'
    Set-Content -LiteralPath $outsideLauncher -Value "Write-Output 'unsafe'" -Encoding UTF8
    $outsideFiles = @($outsideLauncher, $fakePython, $fakeServer) | ForEach-Object {
        [ordered]@{ path=[IO.Path]::GetFullPath($_); sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($outsideLauncher)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
        files = $outsideFiles
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $outsideStderrPath = Join-Path $temporaryRoot 'outside-stderr.txt'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 promotes redirected native stderr to a
        # NativeCommandError when the surrounding test uses Stop. The child
        # process exit code and captured stderr are the assertions here.
        $ErrorActionPreference = 'Continue'
        [void](& powershell.exe -NoLogo -NoProfile -NonInteractive -File $launcherScript -StateRoot $temporaryRoot 2> $outsideStderrPath)
        $outsideExitCode = $LASTEXITCODE
        # GitHub Actions dot-sources this test file. Do not leave the expected
        # negative child exit code as the surrounding step's final status.
        $global:LASTEXITCODE = 0
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    # Windows PowerShell 5.1 renders a redirected child stderr stream through the
    # console host, which wraps the message at the current buffer width and can
    # split the asserted phrase across lines. Fold all whitespace runs to single
    # spaces so the assertion tests the message text, not the host's wrapping.
    $outsideStderr = (Get-Content -LiteralPath $outsideStderrPath -Raw) -replace '\s+', ' '
    if ($outsideExitCode -eq 0 -or $outsideStderr -notmatch 'outside the BIM Bridge Host root') {
        throw 'Kimi launcher did not reject a recorded launcher outside the neutral Host root.'
    }
    Write-Host 'PASS Kimi launcher rejects paths outside the neutral Host root'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
