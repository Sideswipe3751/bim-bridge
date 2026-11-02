[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '1.1.0-rc.3',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\release' }

function Copy-ReleasePath([string]$RelativePath, [string]$StageRoot) {
    $source = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Release input is missing: $source" }
    $destination = Join-Path $StageRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

& dotnet build (Join-Path $SourceRoot 'BIM.Bridge.slnx') -c Release
if ($LASTEXITCODE -ne 0) { throw 'AEC Codex release build failed.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-release-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'aec-codex'
New-Item -ItemType Directory -Force -Path $stageRoot,$OutputDirectory | Out-Null
try {
    $providerArtifacts = Join-Path $SourceRoot 'artifacts\providers'
    $providerReady = $false
    if (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json')) {
        try {
            & (Join-Path $SourceRoot 'providers\Test-ProviderBundles.ps1') -SourceRoot $SourceRoot -ArtifactsRoot $providerArtifacts
            $providerReady = $true
        } catch {
            Write-Warning ('Cached provider bundles are stale and will be rebuilt: ' + $_.Exception.Message)
        }
    }
    if (-not $providerReady) {
        $providerArtifacts = Join-Path $temporaryRoot 'provider-artifacts'
        & (Join-Path $SourceRoot 'providers\Build-Providers.ps1') -SourceRoot $SourceRoot -OutputRoot $providerArtifacts
        & (Join-Path $SourceRoot 'providers\Test-ProviderBundles.ps1') -SourceRoot $SourceRoot -ArtifactsRoot $providerArtifacts
    }
    if (-not (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json'))) {
        throw 'Verified provider bundles are required for a release.'
    }

    foreach ($path in @(
        'LICENSE','LICENSE-APACHE-2.0','COMMERCIAL.md',
        'COMMERCIAL_LICENSE_TEMPLATE.md','docs\license-transition.md',
        'NOTICE',
        'README.md',
        'CHANGELOG.md',
        'SECURITY.md',
        'THIRD_PARTY_NOTICES.md',
        'installer\Install-AecCodex.ps1',
        'installer\Install-AecProviders.ps1',
        'installer\bootstrap.ps1',
        'plugins\aec-codex\.codex-plugin\plugin.json',
        'plugins\aec-codex\mcp-server',
        'plugins\aec-codex\scripts\Start-AecCodexMcp.ps1',
        'plugins\aec-codex\providers\providers.lock.json',
        'providers',
        'src\BimBridge.Revit2024\BimBridge.Revit2024.addin',
        'src\BimBridge.Revit2024\bin\Release\net48',
        'src\BimBridge.AutoCAD2024\PackageContents.xml',
        'src\BimBridge.AutoCAD2024\bin\Release\net48'
    )) { Copy-ReleasePath $path $stageRoot }

    $providerStage = Join-Path $stageRoot 'artifacts\providers'
    New-Item -ItemType Directory -Force -Path $providerStage | Out-Null
    Get-ChildItem -LiteralPath $providerArtifacts -Force |
        Copy-Item -Destination $providerStage -Recurse -Force

    # Provider verification uses the npm CLI before staging. The installed
    # Revit child server only needs node.exe, so strip the package-manager tree
    # from the release payload. This removes thousands of unused files,
    # including npm's empty .npmrc, without changing the verified server tree.
    foreach ($nodeRoot in @(Get-ChildItem -LiteralPath (Join-Path $providerStage 'revit-community') -Directory -Recurse |
            Where-Object { $_.FullName -match '[\\/]runtime[\\/]node$' })) {
        $nodeExe = Join-Path $nodeRoot.FullName 'node.exe'
        $nodeLicense = Join-Path $nodeRoot.FullName 'LICENSE'
        if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath $nodeLicense -PathType Leaf)) {
            throw "Verified Node runtime is incomplete: $($nodeRoot.FullName)"
        }
        $minimalRoot = Join-Path $nodeRoot.Parent.FullName ('node-minimal-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $minimalRoot | Out-Null
        Copy-Item -LiteralPath $nodeExe,$nodeLicense -Destination $minimalRoot -Force
        $resolvedNodeRoot = [IO.Path]::GetFullPath($nodeRoot.FullName)
        $resolvedProviderStage = [IO.Path]::GetFullPath($providerStage)
        if (-not $resolvedNodeRoot.StartsWith($resolvedProviderStage, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe Node runtime trim target: $resolvedNodeRoot"
        }
        Remove-Item -LiteralPath $resolvedNodeRoot -Recurse -Force
        Move-Item -LiteralPath $minimalRoot -Destination $resolvedNodeRoot
    }

    # Public installs must be self-contained. Build a relocatable CPython
    # runtime now, on the trusted release machine, rather than asking every
    # user to install Python and resolve provider dependencies during setup.
    $providerLockPath = Join-Path $stageRoot 'plugins\aec-codex\providers\providers.lock.json'
    $providerLock = Get-Content -LiteralPath $providerLockPath -Raw | ConvertFrom-Json
    $pythonSpec = $providerLock.runtimes.'python-windows-x64'
    if (-not $pythonSpec -or -not $pythonSpec.url -or $pythonSpec.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'The pinned Windows Python runtime is missing or invalid.'
    }
    $buildPython = Get-Command python -ErrorAction SilentlyContinue
    if (-not $buildPython) { throw 'Python is required on the release build machine.' }
    $expectedPython = [version]$pythonSpec.version
    $buildPythonVersionText = & $buildPython.Source -c 'import sys;print(sys.version_info.major,sys.version_info.minor,sys.version_info.micro,sep=chr(46))'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the release build Python version.' }
    $buildPythonVersion = [version]$buildPythonVersionText
    if ($buildPythonVersion.Major -ne $expectedPython.Major -or $buildPythonVersion.Minor -ne $expectedPython.Minor) {
        throw "Release build Python $buildPythonVersion does not match pinned runtime $expectedPython."
    }

    $pythonArchive = Join-Path $temporaryRoot 'python-embed.zip'
    Invoke-WebRequest -Uri ([uri]$pythonSpec.url) -OutFile $pythonArchive -UseBasicParsing
    $pythonArchiveHash = (Get-FileHash -LiteralPath $pythonArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pythonArchiveHash -ne ([string]$pythonSpec.sha256).ToLowerInvariant()) {
        throw "Python runtime checksum mismatch. Expected $($pythonSpec.sha256), received $pythonArchiveHash."
    }
    $pythonRoot = Join-Path $stageRoot 'runtime\python'
    Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force
    $sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
    New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
    $pthFile = Get-ChildItem -LiteralPath $pythonRoot -Filter 'python*._pth' -File | Select-Object -First 1
    if (-not $pthFile) { throw 'The embedded Python path configuration is missing.' }
    $stdlibZip = 'python' + $expectedPython.Major + $expectedPython.Minor + '.zip'
    Write-Utf8NoBom $pthFile.FullName (($stdlibZip, '.', 'Lib\site-packages', 'import site') -join [Environment]::NewLine)

    $providerWheel = Get-ChildItem -LiteralPath (Join-Path $providerStage ('autocad-pro\' + (($providerLock.providers | Where-Object id -eq 'autocad-pro').version))) -Filter 'autocad_mcp_pro-*.whl' -File | Select-Object -First 1
    if (-not $providerWheel) { throw 'The verified AutoCAD provider wheel is missing from the release stage.' }
    $autocadSpec = $providerLock.providers | Where-Object id -eq 'autocad-pro'
    $constraintsPath = Join-Path $stageRoot ([string]$autocadSpec.runtimeConstraints.path)
    if (-not (Test-Path -LiteralPath $constraintsPath -PathType Leaf) -or $autocadSpec.runtimeConstraints.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'The pinned AutoCAD runtime constraints are missing or invalid.'
    }
    $constraintsHash = (Get-FileHash -LiteralPath $constraintsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($constraintsHash -ne ([string]$autocadSpec.runtimeConstraints.sha256).ToLowerInvariant()) {
        throw "AutoCAD runtime constraints checksum mismatch. Expected $($autocadSpec.runtimeConstraints.sha256), received $constraintsHash."
    }
    & $buildPython.Source -m pip install --quiet --disable-pip-version-check --no-input --no-compile --constraint $constraintsPath --target $sitePackages ($providerWheel.FullName + '[com]')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to assemble the private AutoCAD provider runtime.' }
    $privatePython = Join-Path $pythonRoot 'python.exe'
    $privateProviderServer = Join-Path $sitePackages 'server.py'
    if (-not (Test-Path -LiteralPath $privatePython -PathType Leaf) -or -not (Test-Path -LiteralPath $privateProviderServer -PathType Leaf)) {
        throw 'The assembled private Python runtime is incomplete.'
    }
    & $privatePython -c 'import ezdxf, fastmcp, pydantic, PIL, win32com.client'
    if ($LASTEXITCODE -ne 0) { throw 'The assembled private Python runtime failed its import test.' }
    $stagedMcpServer = Join-Path $stageRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py'
    $initializeRequest = [ordered]@{
        jsonrpc='2.0'; id=1; method='initialize'; params=[ordered]@{
            protocolVersion='2025-06-18'; capabilities=[ordered]@{}
            clientInfo=[ordered]@{ name='aec-codex-release-build'; version=$Version }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $initializeErrorPath = Join-Path $temporaryRoot 'mcp-initialize.stderr.txt'
    $initializeOutput = @($initializeRequest | & $privatePython $stagedMcpServer 2>$initializeErrorPath)
    $initializeExitCode = $LASTEXITCODE
    $initializeResponse = $initializeOutput | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    if ($initializeExitCode -ne 0 -or -not $initializeResponse) {
        $initializeError = if (Test-Path -LiteralPath $initializeErrorPath) { (Get-Content -LiteralPath $initializeErrorPath -Raw).Trim() } else { '' }
        throw "The private runtime could not initialize the staged AEC Codex MCP server (exit $initializeExitCode). $initializeError"
    }
    try { $initialized = $initializeResponse | ConvertFrom-Json } catch { throw 'The staged AEC Codex MCP returned invalid initialization JSON.' }
    if ($initialized.result.serverInfo.name -ne 'aec-codex' -or $initialized.result.serverInfo.version -ne $Version) {
        throw 'The staged AEC Codex MCP server identity or version is invalid.'
    }

    foreach ($required in @(
        'installer\Install-AecCodex.ps1',
        'plugins\aec-codex\.codex-plugin\plugin.json',
        'plugins\aec-codex\mcp-server\aec_mcp_server.py',
        'plugins\aec-codex\scripts\Start-AecCodexMcp.ps1',
        'runtime\python\python.exe',
        'runtime\python\Lib\site-packages\server.py',
        'artifacts\providers\build-manifest.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $stageRoot $required) -PathType Leaf)) {
            throw "Host payload is missing required file: $required"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $stageRoot 'plugins\aec-codex\release-manifest.json')) {
        throw 'Host payload must not contain the self-pinning release manifest.'
    }
    $forbidden = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object {
        $isCertifiTrustStore = $_.FullName.EndsWith('runtime\python\Lib\site-packages\certifi\cacert.pem', [StringComparison]::OrdinalIgnoreCase)
        $_.Name -match '^(\.env|\.npmrc|id_rsa|credentials)$' -or
            (($_.Extension -match '^\.(pem|key|pfx|p12)$') -and -not $isCertifiTrustStore)
    })
    if ($forbidden.Count -gt 0) {
        throw ('Host payload contains forbidden files: ' + (($forbidden | Select-Object -ExpandProperty FullName) -join ', '))
    }

    # This is a host-only payload. In particular, it excludes the plugin's
    # release-manifest.json so the payload SHA-256 can be pinned by that
    # manifest without creating a self-referential archive hash.
    $zipName = "aec-codex-host-$Version-win-x64.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { throw "Release output already exists: $zipPath" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', ($hash + '  ' + $zipName + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Release: $zipPath"
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe release cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
