[CmdletBinding()]
param(
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
}

$marketplacePath = Join-Path $SourceRoot '.agents\plugins\marketplace.json'
$pluginPath = Join-Path $SourceRoot 'plugins\bim-bridge\.codex-plugin\plugin.json'
$workBuddyMarketplacePath = Join-Path $SourceRoot '.codebuddy-plugin\marketplace.json'
$workBuddyPluginPath = Join-Path $SourceRoot 'adapters\workbuddy\.codebuddy-plugin\plugin.json'
$workBuddyMcpPath = Join-Path $SourceRoot 'adapters\workbuddy\.mcp.json'
$releasePath = Join-Path $SourceRoot 'plugins\bim-bridge\release-manifest.json'
$releaseSignaturePath = $releasePath + '.sig'
$releaseVerifierPath = Join-Path $SourceRoot 'plugins\bim-bridge\scripts\Test-BimBridgeReleaseManifest.ps1'
$readmePath = Join-Path $SourceRoot 'README.md'
$installPath = Join-Path $SourceRoot 'INSTALL.md'
$architecturePath = Join-Path $SourceRoot 'docs\architecture.md'

$marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 | ConvertFrom-Json
$plugin = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8 | ConvertFrom-Json
$workBuddyMarketplace = Get-Content -LiteralPath $workBuddyMarketplacePath -Raw -Encoding UTF8 | ConvertFrom-Json
$workBuddyPlugin = Get-Content -LiteralPath $workBuddyPluginPath -Raw -Encoding UTF8 | ConvertFrom-Json
$workBuddyMcp = Get-Content -LiteralPath $workBuddyMcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
. $releaseVerifierPath
$verifiedRelease = Read-VerifiedBimBridgeReleaseManifest $releasePath $releaseSignaturePath
if ([string]$verifiedRelease.version -ne [string]$release.version) { throw 'Signed release verification returned a different version.' }
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
$install = Get-Content -LiteralPath $installPath -Raw -Encoding UTF8
$architecture = Get-Content -LiteralPath $architecturePath -Raw -Encoding UTF8

if ([string]$marketplace.name -ne 'bim-bridge') { throw 'Repo Marketplace name must remain bim-bridge.' }
$entry = @($marketplace.plugins | Where-Object { $_.name -eq 'bim-bridge' })
if ($entry.Count -ne 1) { throw 'Repo Marketplace must expose exactly one bim-bridge entry.' }
if ([string]$entry[0].source.source -ne 'local' -or [string]$entry[0].source.path -ne './plugins/bim-bridge') {
    throw 'Repo Marketplace must resolve the bundled Plugin relative to the repository root.'
}
if ([string]$entry[0].policy.installation -ne 'AVAILABLE') { throw 'BIM Bridge Plugin must require an explicit install action.' }
if ([string]$plugin.name -ne 'bim-bridge') { throw 'Plugin manifest name must remain bim-bridge.' }
if ([string]$plugin.version -ne [string]$release.version) { throw 'Plugin and Host release versions must match.' }

if ([string]$workBuddyMarketplace.name -ne 'bim-bridge') { throw 'WorkBuddy Marketplace name must remain bim-bridge.' }
$workBuddyEntry = @($workBuddyMarketplace.plugins | Where-Object { $_.name -eq 'bim-bridge' })
if ($workBuddyEntry.Count -ne 1 -or [string]$workBuddyEntry[0].source -ne './adapters/workbuddy') {
    throw 'WorkBuddy Marketplace must expose exactly one repository-relative bim-bridge Plugin.'
}
if ([string]$workBuddyPlugin.name -ne 'bim-bridge' -or [string]$workBuddyPlugin.version -ne [string]$release.version) {
    throw 'WorkBuddy Plugin identity and Host release versions must match.'
}
if (-not (@($workBuddyPlugin.skills) -contains './skills/bim-bridge') -or [string]$workBuddyPlugin.mcpServers -ne './.mcp.json') {
    throw 'WorkBuddy Plugin must bundle its Skill and MCP declaration.'
}
$workBuddyServer = $workBuddyMcp.mcpServers.'bim-bridge'
$expectedWorkBuddyLauncher = '${CODEBUDDY_PLUGIN_ROOT}/skills/bim-bridge/scripts/Start-BimBridgeWorkBuddyMcp.ps1'
if ([string]$workBuddyServer.command -ne 'powershell.exe' -or [string]@($workBuddyServer.args)[-1] -ne $expectedWorkBuddyLauncher) {
    throw 'WorkBuddy Plugin MCP must use its relocatable verified launcher.'
}

$canonicalPrompt = 'Install and configure BIM Bridge from https://github.com/Sideswipe3751/bim-bridge.'
if (-not $readme.Contains($canonicalPrompt) -or -not $install.Contains($canonicalPrompt)) {
    throw 'README.md and INSTALL.md must contain the same canonical one-line install request.'
}
foreach ($required in @(
    'codex plugin marketplace add Sideswipe3751/bim-bridge --ref main',
    'codex plugin marketplace upgrade bim-bridge',
    'codex plugin remove bim-bridge@bim-bridge',
    'codex plugin add bim-bridge@bim-bridge',
    '/plugin marketplace add https://github.com/Sideswipe3751/bim-bridge',
    '/plugin install bim-bridge@bim-bridge',
    '/plugins install https://github.com/Sideswipe3751/bim-bridge/tree/main'
)) {
    if (-not $install.Contains($required)) { throw "INSTALL.md is missing required command: $required" }
}
if (-not $install.Contains('not consent to mutate Autodesk or native Host state')) {
    throw 'INSTALL.md must preserve the separate native Host consent boundary.'
}
foreach ($requiredArchitecturePattern in @('Codex Repo Marketplace', 'WorkBuddy Plugin\s+Marketplace', 'Kimi repository Plugin source')) {
    if ($architecture -notmatch $requiredArchitecturePattern) {
        throw "The architecture contract is missing distribution boundary: $requiredArchitecturePattern"
    }
}

if ([bool]$release.published) {
    if (-not $release.releaseZipUri -or [string]$release.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'A published Host release requires a pinned URL and SHA-256.'
    }
} else {
    if ($release.releaseZipUri -or $release.sha256) {
        throw 'An unpublished Host release must not advertise a remote archive or checksum.'
    }
}

Write-Host 'PASS BIM Bridge cross-agent Marketplace one-line install contract is valid.'
