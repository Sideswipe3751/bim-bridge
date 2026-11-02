[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '2.0.0-alpha.4',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProgressPreference = 'SilentlyContinue'
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\release' }

function Copy-ReleasePath([string]$RelativePath, [string]$StageRoot) {
    $source = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Release input is missing: $source" }
    $destination = Join-Path $StageRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))
}

function Copy-CertifiedOutputs([object[]]$Entries, [string]$Product, [string]$StageRoot) {
    $productRoot = Join-Path $SourceRoot ("src\BimBridge.$Product\bin\Release")
    foreach ($entry in @($Entries | Where-Object { $_.CertificationStatus -eq 'certified' })) {
        $targets = @(([string]$entry.CertifiedTargetFrameworks).Split(';', [StringSplitOptions]::RemoveEmptyEntries))
        if ($targets.Count -eq 0) {
            throw "$Product $($entry.Include) is certified but has no certified target frameworks."
        }
        foreach ($target in $targets) {
            $relative = "src\BimBridge.$Product\bin\Release\$($entry.Include)\$target"
            $source = Join-Path $SourceRoot $relative
            if (-not (Test-Path -LiteralPath (Join-Path $source ("$($entry.AssemblyName).dll")) -PathType Leaf)) {
                throw "$Product $($entry.Include) certified $target release output is missing: $source"
            }
            Copy-ReleasePath $relative $StageRoot
        }
    }
}

function Get-CertifiedVariantKeys([object[]]$Entries, [string]$Product) {
    @($Entries | Where-Object CertificationStatus -eq 'certified' | ForEach-Object {
        $entry = $_
        @(([string]$entry.CertifiedTargetFrameworks).Split(';', [StringSplitOptions]::RemoveEmptyEntries)) |
            ForEach-Object { "$($Product.ToLowerInvariant())/$($entry.Include)/$_" }
    })
}

$pluginManifestPath = Join-Path $SourceRoot 'plugins\bim-bridge\.codex-plugin\plugin.json'
$releaseManifestPath = Join-Path $SourceRoot 'plugins\bim-bridge\release-manifest.json'
$pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw | ConvertFrom-Json
$releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
if (([string]$pluginManifest.version -replace '\+.*$','') -ne $Version -or [string]$releaseManifest.version -ne $Version) {
    throw 'Requested release version does not match the plugin and release manifests.'
}

. (Join-Path $SourceRoot 'eng\RevitVersionMatrix.ps1')
. (Join-Path $SourceRoot 'eng\AutodeskVersionMatrix.ps1')
$matrixPath = Join-Path $SourceRoot 'eng\Autodesk.Versions.props'
$revitEntries = @(Get-RevitMatrixEntries $matrixPath)
$autoCADEntries = @(Get-AutoCADMatrixEntries $matrixPath)
if (@($revitEntries | Where-Object CertificationStatus -eq 'certified').Count -ne 4 -or
    @($autoCADEntries | Where-Object CertificationStatus -eq 'certified').Count -ne 4) {
    throw 'The release gate requires four certified Revit and four certified AutoCAD entries.'
}
$expectedVariants = @(
    Get-CertifiedVariantKeys $revitEntries 'Revit'
    Get-CertifiedVariantKeys $autoCADEntries 'AutoCAD'
) | Sort-Object
$manifestVariants = @(
    @($releaseManifest.certifiedVariants.revit) | ForEach-Object { "revit/$($_.version)/$($_.targetFramework)" }
    @($releaseManifest.certifiedVariants.autocad) | ForEach-Object { "autocad/$($_.version)/$($_.targetFramework)" }
) | Sort-Object
if (($expectedVariants -join '|') -ne ($manifestVariants -join '|')) {
    throw 'The signed release manifest certified variants do not match the Autodesk version matrix.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-release-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'bim-bridge'
New-Item -ItemType Directory -Force -Path $stageRoot,$OutputDirectory | Out-Null
try {
    foreach ($path in @(
        'LICENSE','LICENSE-APACHE-2.0','COMMERCIAL.md',
        'COMMERCIAL_LICENSE_TEMPLATE.md','docs\license-transition.md','NOTICE','README.md','CHANGELOG.md','SECURITY.md','THIRD_PARTY_NOTICES.md',
        'installer\Install-BimBridge.ps1','installer\Start-BimBridgeMcp.ps1',
        'plugins\bim-bridge\.codex-plugin\plugin.json',
        'plugins\bim-bridge\scripts\AutodeskProductDiscovery.ps1',
        'plugins\aec-codex\mcp-server','runtime\aec_runtime',
        'eng\Autodesk.Versions.props','eng\AutodeskVersionMatrix.ps1','eng\RevitVersionMatrix.ps1',
        'src\BimBridge.AutoCAD\PackageContents.template.xml'
    )) { Copy-ReleasePath $path $stageRoot }
    $embeddedManifest = ($releaseManifest | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    $embeddedManifest.channel = 'embedded'
    $embeddedManifest.published = $false
    $embeddedManifest.releaseZipUri = $null
    $embeddedManifest.sha256 = $null
    $embeddedManifestPath = Join-Path $stageRoot 'plugins\bim-bridge\release-manifest.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $embeddedManifestPath) | Out-Null
    Write-Utf8NoBom $embeddedManifestPath ($embeddedManifest | ConvertTo-Json -Depth 10)
    Copy-CertifiedOutputs $revitEntries 'Revit' $stageRoot
    Copy-CertifiedOutputs $autoCADEntries 'AutoCAD' $stageRoot

    $runtimeLock = Get-Content -LiteralPath (Join-Path $SourceRoot 'plugins\aec-codex\providers\providers.lock.json') -Raw | ConvertFrom-Json
    $pythonSpec = $runtimeLock.runtimes.'python-windows-x64'
    if (-not $pythonSpec -or $pythonSpec.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Pinned private Python metadata is invalid.' }
    $pythonArchive = Join-Path $temporaryRoot 'python-embed.zip'
    Invoke-WebRequest -Uri ([uri]$pythonSpec.url) -OutFile $pythonArchive -UseBasicParsing
    $pythonHash = (Get-FileHash -LiteralPath $pythonArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pythonHash -ne ([string]$pythonSpec.sha256).ToLowerInvariant()) { throw 'Pinned private Python archive checksum mismatch.' }
    $pythonRoot = Join-Path $stageRoot 'runtime\python'
    Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force
    $pth = Get-ChildItem -LiteralPath $pythonRoot -Filter 'python*._pth' -File | Select-Object -First 1
    if (-not $pth) { throw 'Private Python path configuration is missing.' }
    $pythonVersion = [version]$pythonSpec.version
    Write-Utf8NoBom $pth.FullName (("python$($pythonVersion.Major)$($pythonVersion.Minor).zip",'.','import site') -join [Environment]::NewLine)

    $privatePython = Join-Path $pythonRoot 'python.exe'
    $stagedServer = Join-Path $stageRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py'
    $initialize = [ordered]@{
        jsonrpc='2.0'; id=1; method='initialize'; params=[ordered]@{
            protocolVersion='2025-06-18'; capabilities=[ordered]@{}
            clientInfo=[ordered]@{ name='bim-bridge-release'; version=$Version }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $errorPath = Join-Path $temporaryRoot 'mcp.stderr.txt'
    $global:LASTEXITCODE = 0
    $response = @($initialize | & $privatePython $stagedServer 2>$errorPath | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or $response.Count -ne 1) {
        $detail = if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { '' }
        throw "The staged private Host failed MCP initialization. $detail"
    }
    $initialized = $response[0] | ConvertFrom-Json
    if ([string]$initialized.result.serverInfo.name -ne 'aec-codex') { throw 'The staged MCP server identity is invalid.' }

    foreach ($cacheDirectory in @(Get-ChildItem -LiteralPath $stageRoot -Directory -Recurse -Filter '__pycache__' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
        Remove-Item -LiteralPath $cacheDirectory.FullName -Recurse -Force
    }
    foreach ($compiledPython in @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Filter '*.pyc' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $compiledPython.FullName -Force
    }

    $forbidden = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object {
        $_.Name -match '^(\.env|\.npmrc|id_rsa|credentials)$' -or $_.Extension -match '^\.(pem|key|pfx|p12)$'
    })
    if ($forbidden.Count -gt 0) { throw ('Release contains forbidden files: ' + ($forbidden.FullName -join ', ')) }

    $zipName = "bim-bridge-host-$Version-win-x64.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { throw "Release output already exists: $zipPath" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot,$zipPath,[IO.Compression.CompressionLevel]::Optimal,$true)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom ($zipPath + '.sha256') ($hash + '  ' + $zipName + [Environment]::NewLine)
    [ordered]@{ status='created'; version=$Version; path=$zipPath; sha256=$hash } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe release cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
