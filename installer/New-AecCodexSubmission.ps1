[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '1.1.0-rc.3',
    [string]$OutputDirectory,
    [switch]$AllowUnpublished
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\submission' }

function Copy-SubmissionPath([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Submission input is missing: $Source" }
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

$pluginRoot = Join-Path $SourceRoot 'plugins\aec-codex'
$pluginManifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
$releaseManifest = Get-Content -LiteralPath (Join-Path $pluginRoot 'release-manifest.json') -Raw | ConvertFrom-Json
$listing = Get-Content -LiteralPath (Join-Path $SourceRoot 'submission\listing.json') -Raw | ConvertFrom-Json
if ([string]$pluginManifest.version -ne $Version -or [string]$releaseManifest.version -ne $Version -or [string]$listing.version -ne $Version) {
    throw "Plugin, release, and submission versions must all equal $Version."
}
if (-not $AllowUnpublished) {
    if (-not [bool]$releaseManifest.published) { throw "AEC Codex $Version is not published." }
    if ([string]$releaseManifest.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'The published release SHA-256 is missing.' }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-submission-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'aec-codex'
$stageSkillRoot = Join-Path $stageRoot 'skills\aec-codex'
New-Item -ItemType Directory -Force -Path $stageRoot,$stageSkillRoot,$OutputDirectory | Out-Null
try {
    $sourceSkill = Join-Path $pluginRoot 'skills\aec-codex'
    Copy-SubmissionPath (Join-Path $sourceSkill 'SKILL.md') (Join-Path $stageSkillRoot 'SKILL.md')
    Copy-SubmissionPath (Join-Path $sourceSkill 'references') (Join-Path $stageSkillRoot 'references')
    Copy-SubmissionPath (Join-Path $sourceSkill 'agents') (Join-Path $stageSkillRoot 'agents')
    Copy-SubmissionPath (Join-Path $pluginRoot 'scripts\Get-AecCodexHostStatus.ps1') (Join-Path $stageSkillRoot 'scripts\Get-AecCodexHostStatus.ps1')
    Copy-SubmissionPath (Join-Path $pluginRoot 'scripts\Install-AecCodexHost.ps1') (Join-Path $stageSkillRoot 'scripts\Install-AecCodexHost.ps1')
    Copy-SubmissionPath (Join-Path $pluginRoot 'release-manifest.json') (Join-Path $stageSkillRoot 'release-manifest.json')
    foreach ($legalPath in @(
        'LICENSE','LICENSE-APACHE-2.0','NOTICE','THIRD_PARTY_NOTICES.md',
        'COMMERCIAL.md','COMMERCIAL_LICENSE_TEMPLATE.md','docs\license-transition.md'
    )) {
        Copy-SubmissionPath (Join-Path $SourceRoot $legalPath) (Join-Path $stageRoot $legalPath)
    }
    Copy-SubmissionPath (Join-Path $SourceRoot 'branding\official\bim-bridge-logo-transparent.png') (Join-Path $stageRoot 'assets\aec-codex-logo-transparent.png')

    $publicPluginManifest = [ordered]@{
        name = 'aec-codex'
        version = $Version
        description = [string]$listing.shortDescription
        author = [ordered]@{
            name = [string]$listing.publisherIdentity
            url = 'https://github.com/Sideswipe3751'
        }
        homepage = [string]$listing.websiteURL
        repository = 'https://github.com/Sideswipe3751/aec-codex'
        license = 'PolyForm-Noncommercial-1.0.0'
        keywords = @('autocad', 'revit', 'autodesk', 'aec', 'codex')
        skills = './skills/'
        interface = [ordered]@{
            displayName = [string]$listing.name
            shortDescription = [string]$listing.shortDescription
            longDescription = [string]$listing.longDescription
            developerName = [string]$listing.publisherIdentity
            category = [string]$listing.category
            capabilities = @('Interactive', 'Read', 'Write')
            websiteURL = [string]$listing.websiteURL
            privacyPolicyURL = [string]$listing.privacyPolicyURL
            termsOfServiceURL = [string]$listing.termsOfServiceURL
            defaultPrompt = @($listing.starterPrompts)
            brandColor = [string]$listing.brandColor
            composerIcon = './assets/aec-codex-logo-transparent.png'
            logo = './assets/aec-codex-logo-transparent.png'
        }
    }
    $manifestDirectory = Join-Path $stageRoot '.codex-plugin'
    New-Item -ItemType Directory -Force -Path $manifestDirectory | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $manifestDirectory 'plugin.json'),
        (($publicPluginManifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )

    $skillText = Get-Content -LiteralPath (Join-Path $stageSkillRoot 'SKILL.md') -Raw
    if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*aec-codex\s*\r?\ndescription:') {
        throw 'Public skill front matter is invalid.'
    }
    $forbiddenFiles = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object {
        $_.Name -in @('.mcp.json', 'marketplace.json') -or $_.Extension -match '^\.(exe|dll|whl|pfx|p12|pem|key)$'
    })
    if ($forbiddenFiles.Count -gt 0) {
        throw ('Public skill bundle contains forbidden files: ' + (($forbiddenFiles | Select-Object -ExpandProperty FullName) -join ', '))
    }
    $forbiddenText = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Select-String -Pattern '\|\s*(Invoke-Expression|iex)\b|--ref\s+latest|BEGIN (RSA |OPENSSH )?PRIVATE KEY' -CaseSensitive:$false)
    if ($forbiddenText.Count -gt 0) {
        throw ('Public skill bundle contains a forbidden instruction: ' + $forbiddenText[0].Path)
    }

    $zipName = "aec-codex-public-skill-$Version.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    $stagePrefix = [IO.Path]::GetFullPath($stageRoot)
    if (-not $stagePrefix.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $stagePrefix += [IO.Path]::DirectorySeparatorChar
    }
    $zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Sort-Object FullName)) {
                $entryName = $file.FullName.Substring($stagePrefix.Length).Replace('\', '/')
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $inputStream = $file.OpenRead()
                $outputStream = $entry.Open()
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $zipStream.Dispose()
    }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', ($hash + '  ' + $zipName + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Submission bundle: $zipPath"
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe submission cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
