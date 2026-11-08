# BIM Bridge version authority.
#
# One repository source declares the package version, and one function maps it to
# the stable numeric version an Autodesk bundle manifest can carry. This file is
# the single place for that mapping: nothing else may derive it independently.
#
# Why two numbers exist at all, and why they are not interchangeable:
#
#   * `Directory.Build.props` `<Version>` is the package/SemVer identity of a
#     release ("2.0.0-alpha.4"). It is what the installer, the release manifest
#     and the release notes publish, and a prerelease label belongs in it.
#   * `ApplicationPackage/@AppVersion` and `ComponentEntry/@Version` in an
#     AutoCAD bundle manifest are NOT package identity. Autodesk treats
#     `ComponentEntry/@Version` as the minimum required AutoCAD product version,
#     so a prerelease string there is not "the same version with a suffix" - it is
#     a different kind of value, and putting "2.0.0-alpha.4" in it can change
#     Autodesk load gating.
#
# The mapping rule is therefore explicit and narrow: strip the SemVer
# prerelease and build-metadata segments and keep the dotted numeric core. That
# is the only supported derivation, and `tests/architecture/Test-BimBridgeVersionAuthority.ps1`
# holds every declared Autodesk AppVersion to the value it produces.
#
# Consuming the helper from build scripts: `eng/AutodeskVersionMatrix.ps1`
# (parameter default), `eng/Build-AutoCADAdapters.ps1` (call site) and
# `installer/Install-BimBridge.ps1` (call site) still carry the literal '2.0.0'.
# That value is asserted equal to this mapping, so a drift fails a test instead
# of shipping; replacing the literals with `Get-BimBridgeVersionMapping` calls is
# a follow-up for those files' owners because they are outside this helper's
# ownership.

[CmdletBinding()]
param(
    # Repository root that owns Directory.Build.props. Defaults to the checkout
    # containing this script.
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$script:BimBridgeVersionRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:BimBridgeVersionSource = Join-Path $script:BimBridgeVersionRoot 'Directory.Build.props'

function Get-BimBridgeVersionSourcePath {
    return $script:BimBridgeVersionSource
}

function Get-BimBridgeVersionParts([string]$Version) {
    <#
        Splits a version string into its dotted numeric core and the trailing
        prerelease / build-metadata segments, without guessing.

        Returns @{ Major; Minor; Patch; Prerelease; BuildMetadata; NumericCore }.
        An empty or unparsable version throws: a version this repository cannot
        interpret must fail loudly rather than silently map to something.
    #>
    if ([string]::IsNullOrWhiteSpace($Version)) { throw 'A version string is required.' }
    $match = [regex]::Match(([string]$Version).Trim(), '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$')
    if (-not $match.Success) { throw "Unsupported version string '$Version'; expected major.minor.patch with an optional prerelease/build suffix." }
    return [ordered]@{
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
        Prerelease = if ($match.Groups[4].Success) { [string]$match.Groups[4].Value } else { $null }
        BuildMetadata = if ($match.Groups[5].Success) { [string]$match.Groups[5].Value } else { $null }
        NumericCore = '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
    }
}

function ConvertTo-BimBridgeAutodeskAppVersion([string]$Version) {
    <#
        The single supported mapping from a BIM Bridge version to the stable
        numeric value an Autodesk bundle manifest can carry. SemVer prerelease
        and build-metadata segments are dropped; the dotted numeric core is kept.
    #>
    return [string]((Get-BimBridgeVersionParts $Version).NumericCore)
}

function Get-BimBridgeVersionMapping {
    <#
        Reads the repository's authoritative package version and derives the
        Autodesk manifest version from it. Returns an ordered map:

          PackageVersion      Directory.Build.props <Version>       2.0.0-alpha.4
          AutodeskAppVersion  derived stable numeric value          2.0.0
          AssemblyVersion     Directory.Build.props <AssemblyVersion> 2.0.0.0
          FileVersion         Directory.Build.props <FileVersion>      2.0.0.0
          NumericCore         SemVer numeric core of PackageVersion 2.0.0
          Prerelease          SemVer prerelease label, or $null    alpha.4
          Source              absolute path of Directory.Build.props

        Every value comes from Directory.Build.props; nothing is hard-coded here.
    #>
    if (-not (Test-Path -LiteralPath $script:BimBridgeVersionSource -PathType Leaf)) {
        throw "The BIM Bridge version source is missing: $($script:BimBridgeVersionSource)"
    }
    $props = Get-Content -LiteralPath $script:BimBridgeVersionSource -Raw
    $packageVersion = $null
    $assemblyVersion = $null
    $fileVersion = $null
    foreach ($line in @($props -split "`r?`n")) {
        $property = [regex]::Match($line, '^\s*<(Version|AssemblyVersion|FileVersion)>([^<]+)</\1>\s*$')
        if (-not $property.Success) { continue }
        switch ($property.Groups[1].Value) {
            'Version' { $packageVersion = $property.Groups[2].Value.Trim() }
            'AssemblyVersion' { $assemblyVersion = $property.Groups[2].Value.Trim() }
            'FileVersion' { $fileVersion = $property.Groups[2].Value.Trim() }
        }
    }
    if (-not $packageVersion) { throw "Directory.Build.props declares no <Version>: $($script:BimBridgeVersionSource)" }
    if (-not $assemblyVersion) { throw "Directory.Build.props declares no <AssemblyVersion>: $($script:BimBridgeVersionSource)" }
    if (-not $fileVersion) { throw "Directory.Build.props declares no <FileVersion>: $($script:BimBridgeVersionSource)" }
    $parts = Get-BimBridgeVersionParts $packageVersion
    return [ordered]@{
        PackageVersion = [string]$packageVersion
        AutodeskAppVersion = [string]$parts.NumericCore
        AssemblyVersion = [string]$assemblyVersion
        FileVersion = [string]$fileVersion
        NumericCore = [string]$parts.NumericCore
        Prerelease = $parts.Prerelease
        Source = [string]$script:BimBridgeVersionSource
    }
}
