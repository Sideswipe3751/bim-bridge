[CmdletBinding()]
param(
    [string]$SourceRoot
)

# BIM Bridge version authority gate.
#
# Requirement: the two version numbers BIM Bridge publishes must be traceable to
# one repository source instead of being guessed or re-declared ad hoc.
#
#   * `Directory.Build.props` `<Version>` is the package/SemVer identity
#     (`2.0.0-alpha.4`).
#   * The Autodesk bundle manifest's `AppVersion` / `ComponentEntry Version` must
#     be a stable numeric version, and Autodesk defines `ComponentEntry/@Version`
#     as the minimum required AutoCAD product version - so it is a different kind
#     of value and cannot simply repeat the package version.
#
# `eng/Get-BimBridgeVersion.ps1` is the single source of that mapping (SemVer
# prerelease/build metadata stripped, dotted numeric core kept). This test proves
# the mapping is well defined, that the package version it derives from matches
# `Directory.Build.props`, and that every declared Autodesk AppVersion in the
# repository equals the mapped value. A drift fails here instead of shipping.
#
# Read-only: it parses source and one repository JSON file. It writes nothing,
# starts no Autodesk product, and touches no user state.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

$failed = New-Object System.Collections.ArrayList
$passed = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        $script:passed++
        Write-Host "PASS $Name"
    } else {
        [void]$script:failed.Add($Name)
        Write-Host "FAIL $Name"
    }
}

function Read-RepositoryText([string]$RelativePath) {
    $full = Join-Path $SourceRoot ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Expected repository file is missing: $RelativePath" }
    return [string](Get-Content -LiteralPath $full -Raw)
}

# ------------------------------------------------------- single source of truth

$versionHelperRelative = 'eng/Get-BimBridgeVersion.ps1'
$versionHelperPath = Join-Path $SourceRoot ($versionHelperRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
Assert-True (Test-Path -LiteralPath $versionHelperPath -PathType Leaf) "The version mapping helper exists: $versionHelperRelative"

. $versionHelperPath -RepositoryRoot $SourceRoot

$directoryBuildProps = Read-RepositoryText 'Directory.Build.props'
$declaredPackageVersion = [regex]::Match($directoryBuildProps, '<Version>([^<]+)</Version>').Groups[1].Value.Trim()
$declaredAssemblyVersion = [regex]::Match($directoryBuildProps, '<AssemblyVersion>([^<]+)</AssemblyVersion>').Groups[1].Value.Trim()
$declaredFileVersion = [regex]::Match($directoryBuildProps, '<FileVersion>([^<]+)</FileVersion>').Groups[1].Value.Trim()

$mapping = Get-BimBridgeVersionMapping
Assert-True ($mapping.PackageVersion -eq $declaredPackageVersion) "Package version tracks Directory.Build.props <Version> ($declaredPackageVersion)"
Assert-True ($mapping.AssemblyVersion -eq $declaredAssemblyVersion) "AssemblyVersion tracks Directory.Build.props <AssemblyVersion> ($declaredAssemblyVersion)"
Assert-True ($mapping.FileVersion -eq $declaredFileVersion) "FileVersion tracks Directory.Build.props <FileVersion> ($declaredFileVersion)"
Assert-True ($mapping.Source -eq (Join-Path $SourceRoot 'Directory.Build.props')) 'The mapping reports Directory.Build.props as its source'
Assert-True ($mapping.PackageVersion -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') "Package version is SemVer-shaped ($($mapping.PackageVersion))"
Assert-True ($mapping.AutodeskAppVersion -match '^\d+\.\d+\.\d+$') "Derived Autodesk AppVersion is a stable numeric version ($($mapping.AutodeskAppVersion))"
Assert-True ($mapping.AutodeskAppVersion -eq (ConvertTo-BimBridgeAutodeskAppVersion $mapping.PackageVersion)) 'The derived AppVersion is a pure function of the package version'
Assert-True ($mapping.AssemblyVersion -match ('^' + [regex]::Escape($mapping.AutodeskAppVersion) + '\.\d+$')) "AssemblyVersion ($($mapping.AssemblyVersion)) shares the derived AppVersion prefix"

# ------------------------------------------------------------- mapping contract

$mapCases = @(
    @{ Version = '2.0.0-alpha.4'; Expected = '2.0.0' }
    @{ Version = '2.0.0'; Expected = '2.0.0' }
    @{ Version = '2.0.0+build.5'; Expected = '2.0.0' }
    @{ Version = '2.0.0-alpha.4+build.5'; Expected = '2.0.0' }
    @{ Version = '1.1.0-rc.3'; Expected = '1.1.0' }
    @{ Version = '10.20.30'; Expected = '10.20.30' }
)
foreach ($case in $mapCases) {
    $actual = ConvertTo-BimBridgeAutodeskAppVersion $case.Version
    Assert-True ($actual -eq $case.Expected) "Mapping $($case.Version) -> $($case.Expected) (got $actual)"
}

$alphaParts = Get-BimBridgeVersionParts '2.0.0-alpha.4+ci.7'
Assert-True ($alphaParts.Prerelease -eq 'alpha.4') 'Prerelease segment is parsed without being folded into the numeric core'
Assert-True ($alphaParts.BuildMetadata -eq 'ci.7') 'Build metadata is parsed and excluded from the numeric core'
Assert-True ($alphaParts.NumericCore -eq '2.0.0') 'Numeric core is the dotted major.minor.patch triple'

foreach ($unsupported in @('', '2.0', '2.0.0.0', 'v2.0.0')) {
    $threw = $false
    try { [void](Get-BimBridgeVersionParts $unsupported) } catch { $threw = $true }
    Assert-True $threw "Unsupported version '$unsupported' is rejected instead of guessed"
}

# ------------------------------------------- every declared Autodesk AppVersion

$engMatrix = Read-RepositoryText 'eng/AutodeskVersionMatrix.ps1'
$engBuilder = Read-RepositoryText 'eng/Build-AutoCADAdapters.ps1'
$installer = Read-RepositoryText 'installer/Install-BimBridge.ps1'

$matrixDefault = [regex]::Match($engMatrix, '\[string\]\$AppVersion\s*=\s*''([^'']+)''').Groups[1].Value
Assert-True ($matrixDefault.Length -gt 0) 'eng/AutodeskVersionMatrix.ps1 declares an AppVersion parameter default'
Assert-True ($matrixDefault -eq $mapping.AutodeskAppVersion) "Matrix AppVersion default equals the derived value ($matrixDefault)"

$builderMatches = @([regex]::Matches($engBuilder, '-AppVersion\s+''([^'']+)''') | ForEach-Object { $_.Groups[1].Value })
Assert-True ($builderMatches.Count -ge 1) 'eng/Build-AutoCADAdapters.ps1 passes an explicit AppVersion'
foreach ($value in $builderMatches) {
    Assert-True ($value -eq $mapping.AutodeskAppVersion) "Build-AutoCADAdapters.ps1 -AppVersion '$value' equals the derived value"
}

$installerMatches = @([regex]::Matches($installer, 'New-AutoCADPackageContents\s+\S+\s+''([^'']+)''') | ForEach-Object { $_.Groups[1].Value })
Assert-True ($installerMatches.Count -ge 1) 'installer/Install-BimBridge.ps1 passes an explicit AppVersion positionally'
foreach ($value in $installerMatches) {
    Assert-True ($value -eq $mapping.AutodeskAppVersion) "Install-BimBridge.ps1 positional AppVersion '$value' equals the derived value"
}

# The released AutoCAD package payload and the staged package must carry the same
# value as the mapping, so the legacy bundle and a matrix-built bundle agree.
$legacyPackage = Read-RepositoryText 'src/BimBridge.AutoCAD2024/PackageContents.xml'
$legacyAppVersion = ([xml]$legacyPackage).ApplicationPackage.AppVersion
Assert-True ($legacyAppVersion -eq $mapping.AutodeskAppVersion) "src/BimBridge.AutoCAD2024/PackageContents.xml AppVersion equals the derived value ($legacyAppVersion)"
Assert-True ($legacyPackage -match ('ComponentEntry[^>]*Version="' + [regex]::Escape($mapping.AutodeskAppVersion) + '"')) 'The legacy package ComponentEntry Version equals the derived value'

$template = Read-RepositoryText 'src/BimBridge.AutoCAD/PackageContents.template.xml'
Assert-True ($template -match 'AppVersion="\{\{APP_VERSION\}\}"') 'The shared bundle template keeps AppVersion as the single substitution point'

# ------------------------------------------------- documented and staged value

$architecture = Read-RepositoryText 'docs/architecture.md'
Assert-True ($architecture -match [regex]::Escape('`' + $mapping.AutodeskAppVersion + '`')) "docs/architecture.md documents the derived Autodesk AppVersion ($($mapping.AutodeskAppVersion))"
Assert-True ($architecture -match [regex]::Escape('`' + $mapping.PackageVersion + '`')) "docs/architecture.md documents the package version ($($mapping.PackageVersion))"
Assert-True ($architecture -match 'Get-BimBridgeVersion\.ps1') 'docs/architecture.md names eng/Get-BimBridgeVersion.ps1 as the mapping source'

$stagedPackagePath = Join-Path $SourceRoot 'artifacts\staging\bim-bridge-connectors-2.0.0-alpha.4\autocad\BIM Bridge.bundle\PackageContents.xml'
if (Test-Path -LiteralPath $stagedPackagePath -PathType Leaf) {
    $stagedAppVersion = ([xml](Get-Content -LiteralPath $stagedPackagePath -Raw)).ApplicationPackage.AppVersion
    Assert-True ($stagedAppVersion -eq $mapping.AutodeskAppVersion) "The staged AutoCAD bundle AppVersion equals the derived value ($stagedAppVersion)"
} else {
    Write-Host "SKIP staged bundle comparison: $stagedPackagePath is absent"
}

Write-Host ''
Write-Host "BIM Bridge version authority: $passed passed, $($failed.Count) failed"
if ($failed.Count -gt 0) {
    foreach ($name in $failed) { Write-Host "  FAILED: $name" }
    exit 1
}
exit 0
