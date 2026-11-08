[CmdletBinding()]
param(
    [string[]]$Version,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$SkipUnavailable,
    [switch]$NoRestore,
    # Offline re-verification escape hatch: skips the NuGet vulnerability audit,
    # the only build step that reaches nuget.org. Never enabled by default so a
    # networked build (and hosted CI) still audits.
    [switch]$Offline,
    # Fail-closed deletion guard. A bundle directory is only ever removed when it
    # canonically resolves inside this script-owned staging root. Never point
    # this at a drive root, the repository root, a user profile, or an Autodesk
    # installation directory; the assertion below rejects those.
    [string]$StagingRoot,
    [string]$BundleDirectory,
    # Opt-in machine-readable envelope. Without it the legacy top-level JSON
    # array of per-release results is preserved for existing callers.
    [switch]$Envelope
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$matrixPath = Join-Path $PSScriptRoot 'Autodesk.Versions.props'
$packageTemplatePath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.csproj'
. (Join-Path $PSScriptRoot 'AutodeskVersionMatrix.ps1')

function Get-AutoCADRequestedYears([string[]]$RequestedVersion) {
    # `-Version 2024,2025` reaches a `-File` invocation as one comma-separated
    # token, so every requested value is tokenized before matrix lookup. The
    # release list itself is never hard-coded here; it is validated below
    # against eng/Autodesk.Versions.props.
    $years = New-Object System.Collections.ArrayList
    foreach ($value in @($RequestedVersion)) {
        foreach ($token in ([string]$value -split '[,;]')) {
            $trimmed = $token.Trim()
            if ($trimmed) { [void]$years.Add($trimmed) }
        }
    }
    @($years)
}

# ---------------------------------------------------------------------------
# Fail-closed deletion containment.
#
# The only directory this script is ever allowed to delete is a bundle staging
# directory that canonically resolves *inside* its own staging root
# (`artifacts\staging\autocad-bundles` by default). Every check below is a
# refusal: a drive root, the repository root or its parent, a user profile, a
# real Autodesk installation directory, a relative or absolute traversal, or a
# reparse point (junction/symlink) that escapes the root all throw before any
# Remove-Item can run.
# ---------------------------------------------------------------------------

function Get-DirectorySegment([string]$Path) {
    # Splitting on both separators keeps `..` segments detectable on every
    # platform; [IO.Path]::GetFullPath leaves them in place.
    @([string]$Path -split '[\\/]' | Where-Object { $_ -ne '' })
}

function Test-LinkReparseTag([string]$ReparseTag) {
    # The reparse tag alone decides whether a reparse point is an escape: only a
    # directory junction / mount point (0xA0000003) or a symbolic link
    # (0xA000000C) can redirect a recursive delete. Cloud-sync placeholder tags
    # (OneDrive uses 0x9000e01a) classify every synced folder as a reparse point
    # in its attributes and are benign, so the attributes alone must never drive
    # this decision. Only the exact eight-digit tag is accepted: anything else
    # fails closed instead of being read as a non-link tag. The tag is compared
    # as text because 0xA0000003 as a signed Int32 literal is negative, so a
    # numeric comparison against the unsigned tag value would never be true.
    if ([string]::IsNullOrWhiteSpace($ReparseTag)) {
        throw 'Deletion containment: a reparse tag must be a non-empty hexadecimal value.'
    }
    $tagText = ([string]$ReparseTag).Trim()
    if ($tagText -notmatch '^(?:0x)?[0-9a-fA-F]{8}$') {
        throw "Deletion containment: the reparse tag '$ReparseTag' is not an eight-digit hexadecimal tag value."
    }
    $tagText = $tagText -replace '^0x', ''
    return [bool]($tagText.Equals('a0000003', [StringComparison]::OrdinalIgnoreCase) -or
        $tagText.Equals('a000000c', [StringComparison]::OrdinalIgnoreCase))
}

function Get-LinkReparsePointTag([string]$Path) {
    # Only a link-style reparse point can redirect a recursive delete, so the tag
    # is read rather than the attributes. An unreadable or missing tag fails
    # closed. The return value is a tag string: fsutil output is never leaked.
    $output = @(& (Join-Path $env:SystemRoot 'System32\fsutil.exe') reparsepoint query $Path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Deletion containment: the reparse tag of '$Path' could not be read, so it cannot be trusted."
    }
    $tagLine = @($output | Where-Object { [string]$_ -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]{8})(?![0-9a-fA-F])' })[0]
    if (-not $tagLine) {
        throw "Deletion containment: no reparse tag was reported for '$Path'."
    }
    $null = [string]$tagLine -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]{8})(?![0-9a-fA-F])'
    [string]$Matches[1]
}

function Test-LinkReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    # A host that reports the reparse attribute for a synced directory without
    # actually exposing a reparse point (observed on OneDrive-synced trees, where
    # fsutil answers "not a reparse point") is classified as a non-link: there is
    # no tag to redirect anything. A real read failure still fails closed above.
    [bool](Test-LinkReparseTag (Get-LinkReparsePointTag $Path))
}

function Get-ExistingAncestorPath([string]$Path) {
    # A path that does not exist yet cannot be a reparse point, so the deepest
    # existing ancestor carries all the link information. Resolving that ancestor
    # catches a junction or symlink anywhere along the candidate's parent chain.
    $candidate = [string]$Path
    while ($candidate -and -not (Test-Path -LiteralPath $candidate)) {
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $candidate) { return $null }
        $candidate = $parent
    }
    if (-not $candidate) { return $null }
    $resolved = @(Resolve-Path -LiteralPath $candidate -ErrorAction Stop)
    if ($resolved.Count -ne 1) { throw "Deletion containment: '$candidate' did not resolve to exactly one path." }
    [IO.Path]::GetFullPath([string]$resolved[0].ProviderPath)
}

function Resolve-CanonicalContainmentRoot([string]$RepositoryRoot) {
    # The containment namespace is anchored on the canonical repository root, so
    # a caller can neither relocate it nor express it as `..` traversal.
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { throw 'Deletion containment: the repository root is unknown.' }
    $canonicalRepositoryRoot = Get-ExistingAncestorPath ([IO.Path]::GetFullPath($RepositoryRoot))
    if (-not $canonicalRepositoryRoot) { throw "Deletion containment: the repository root '$RepositoryRoot' could not be canonicalised." }
    $canonicalRepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + '\artifacts\staging'
}

function Assert-InContainmentNamespace([string]$Candidate, [string]$ContainmentRoot, [string]$Label) {
    # Canonical containment uses a separator-terminated prefix comparison. A bare
    # StartsWith(prefix) would accept sibling paths such as
    # `...\artifacts\staging-evil` and is deliberately not used here.
    if ([string]::IsNullOrWhiteSpace($Candidate)) { throw "Deletion containment: $Label is empty." }
    if (-not [IO.Path]::IsPathRooted($Candidate)) { throw "Deletion containment: $Label must be an absolute path: $Candidate" }
    # Raw-segment traversal refusal runs *before* any canonicalisation: GetFullPath
    # collapses `..`, so `foo\..\bar` or `<staging>\x\..\<staging>` would otherwise
    # be accepted (or rejected as merely "outside staging") after
    # normalisation removed the evidence.
    if (@(Get-DirectorySegment $Candidate | Where-Object { $_ -ceq '..' }).Count -gt 0) {
        throw "Deletion containment: traversal is never accepted for a deletion target: $Candidate"
    }
    $expanded = [IO.Path]::GetFullPath($Candidate)
    if (@(Get-DirectorySegment $expanded).Count -eq 0) { throw "Deletion containment: $Label '$Candidate' is not a usable path." }
    $trimmed = $expanded.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $ContainmentRoot + [IO.Path]::DirectorySeparatorChar
    if ($trimmed.Equals($ContainmentRoot, [StringComparison]::OrdinalIgnoreCase)) { return $expanded }
    if (-not $expanded.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: '$expanded' is outside the repository artifacts staging area."
    }
    $expanded
}

function Get-SafeStagingRoot([string]$CandidateRoot, [string]$ContainmentRoot) {
    # The staging root is a namespace, so it may be named before it exists: only
    # the existing components can carry a link, and those are classified below.
    $root = Assert-InContainmentNamespace $CandidateRoot $ContainmentRoot 'the staging root'
    $root = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    # Fail closed on *every* existing directory from the canonical repository root
    # down to the containment root, the containment root itself included, and do it
    # before the walk below. The walk below only starts *after* the containment
    # root, so a junction planted at `artifacts` or at `artifacts\staging` (the
    # containment root this script derives itself) previously went unclassified
    # even though it redirects the whole staging namespace, and with it every later
    # recursive delete, outside the repository. This chain is a strict prefix of
    # that walk, so it is classified first: the earliest escape on the chain is the
    # one that is reported. Segments that do not exist yet cannot carry a link and
    # are skipped rather than created. The chain is anchored on the canonical
    # repository root recovered from the containment root, whose last two segments
    # are always `artifacts\staging` (Resolve-CanonicalContainmentRoot appends
    # exactly those), so this needs no extra parameter and stays in step with that
    # resolver. The repository root is recovered by trimming the separator-terminated
    # `artifacts\staging` suffix as text rather than by slicing the split segment
    # array, so the walk order is deterministic whatever the host does with
    # single-element array results.
    $existingChain = @($ContainmentRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -split '[\\/]' | Where-Object { $_ -ne '' })
    if ($existingChain.Count -lt 3) {
        throw "Deletion containment: the containment root '$ContainmentRoot' is not a canonical artifacts staging root."
    }
    $artifactsStagingSuffix = [IO.Path]::DirectorySeparatorChar + 'artifacts' + [IO.Path]::DirectorySeparatorChar + 'staging'
    $containmentRootText = $ContainmentRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $containmentRootText.EndsWith($artifactsStagingSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: the containment root '$ContainmentRoot' is not a canonical artifacts staging root."
    }
    $anchoredRepositoryRoot = $containmentRootText.Substring(0, $containmentRootText.Length - $artifactsStagingSuffix.Length)
    if ([string]::IsNullOrEmpty($anchoredRepositoryRoot) -or -not [IO.Path]::IsPathRooted($anchoredRepositoryRoot)) {
        throw "Deletion containment: the containment root '$ContainmentRoot' does not resolve to a repository root inside the artifacts staging area."
    }
    # Get-DirectorySegment returns its whole array as one pipeline object, so an
    # assignment of its result keeps that array as a *single* value and `.Count`
    # then reads 1: exactly what silently truncated an earlier version of this walk.
    # The chain below therefore re-parses the growing path text one segment at a
    # time instead of moving segment arrays around.

    foreach ($segment in (Get-DirectorySegment $anchoredRepositoryRoot)) {
        if ([string]$segment -ceq '..') {
            throw "Deletion containment: the containment root '$ContainmentRoot' contains a traversal segment."
        }
    }
    $walked = $anchoredRepositoryRoot
    $chainGuard = 0
    while ($walked -and -not $walked.Equals($containmentRootText, [StringComparison]::OrdinalIgnoreCase)) {
        $chainGuard++
        if ($chainGuard -gt ($existingChain.Count + 1)) {
            throw "Deletion containment: the path from the repository root to the containment root '$ContainmentRoot' is not a strict ancestor chain."
        }
        # The current segment is classified *before* the next one is appended. The
        # loop used to append first and classify afterwards, which meant the
        # anchored repository root itself was never inspected: a repository root that
        # is a junction or symbolic link redirects the whole containment namespace and
        # every later recursive delete, yet it was the one segment the walk skipped.
        # Classifying first now covers the repository root, `artifacts` and
        # `artifacts\staging` with the same rule. A benign cloud placeholder
        # (OneDrive, tag 0x9000e01a) is still tolerated, because Test-LinkReparsePoint
        # decides on the reparse tag rather than on the attribute alone, and a
        # placeholder reports no link tag.
        if (Test-Path -LiteralPath $walked) {
            $chainItem = Get-Item -LiteralPath $walked -Force -ErrorAction SilentlyContinue
            if (-not $chainItem) {
                throw "Deletion containment: '$walked' on the path from the repository root to the containment root '$ContainmentRoot' could not be inspected, so it cannot be trusted."
            }
            if (-not ($chainItem.Attributes -band [IO.FileAttributes]::Directory)) {
                throw "Deletion containment: '$walked' on the path from the repository root to the containment root '$ContainmentRoot' is not a directory."
            }
            if (Test-LinkReparsePoint $walked) {
                throw "Deletion containment: '$walked' is a reparse point (junction or symbolic link) on the path from the repository root to the containment root '$ContainmentRoot'; refusing to treat '$root' as the staging root."
            }
        }
        $remainingSegments = @(Get-DirectorySegment ($containmentRootText.Substring($walked.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)))
        if ($remainingSegments.Count -eq 0) { break }
        $walked = $walked + [IO.Path]::DirectorySeparatorChar + [string]$remainingSegments[0]
    }
    if (-not $walked.Equals($containmentRootText, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: the path from the repository root to the containment root '$ContainmentRoot' could not be walked."
    }
    # The loop above classifies each segment and stops *at* the containment root, so
    # the containment root itself - the namespace anchor every deletion depends on -
    # must be classified here. Without this the loop's exit condition would leave the
    # one segment that matters most unexamined.
    if (Test-Path -LiteralPath $walked) {
        $containmentItem = Get-Item -LiteralPath $walked -Force -ErrorAction SilentlyContinue
        if (-not $containmentItem) {
            throw "Deletion containment: the containment root '$walked' could not be inspected, so it cannot be trusted."
        }
        if (-not ($containmentItem.Attributes -band [IO.FileAttributes]::Directory)) {
            throw "Deletion containment: the containment root '$walked' is not a directory."
        }
        if (Test-LinkReparsePoint $walked) {
            throw "Deletion containment: '$walked' is a reparse point (junction or symbolic link) on the path from the repository root to the containment root '$ContainmentRoot'; refusing to treat '$root' as the staging root."
        }
    }
    # Fail closed on *every* existing intermediate directory between the
    # containment root and the staging root. Classifying only the final staging
    # root left a junction or symbolic link in an intermediate segment free to
    # redirect the later recursive delete outside the repository staging
    # namespace. Segments that do not exist yet cannot carry a link and are
    # therefore skipped rather than created. The chain is rebuilt from the
    # containment root rather than from the staging root's parsed segments,
    # because a parsed path starts with the drive designator ('C:'), which is not
    # a child of the repository. [IO.Path]::GetRelativePath is deliberately not
    # used: it does not exist on .NET Framework 4.8, which this script supports.
    $containmentPrefix = $ContainmentRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $containmentSegments = @(Get-DirectorySegment $containmentPrefix)
    $stagingSegments = @(Get-DirectorySegment $root)
    if ($stagingSegments.Count -le $containmentSegments.Count -or
        @(0..($containmentSegments.Count - 1) | Where-Object { -not ([string]$stagingSegments[$_]).Equals([string]$containmentSegments[$_], [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw "Deletion containment: the staging root '$root' is not a dedicated directory inside '$containmentPrefix'."
    }
    $relativeSegments = @($stagingSegments[$containmentSegments.Count..($stagingSegments.Count - 1)])
    foreach ($relativeSegment in $relativeSegments) {
        if ([string]$relativeSegment -ceq '..') {
            throw "Deletion containment: the staging root '$root' is not inside '$containmentPrefix'."
        }
    }
    $walked = $containmentPrefix
    for ($i = 0; $i -lt ($relativeSegments.Count - 1); $i++) {
        $walked = $walked + [IO.Path]::DirectorySeparatorChar + [string]$relativeSegments[$i]
        if (-not (Test-Path -LiteralPath $walked)) { break }
        if (Test-LinkReparsePoint $walked) {
            throw "Deletion containment: '$walked' is a reparse point (junction or symbolic link) between the repository artifacts staging area and the staging root '$root'; refusing to treat '$root' as the staging root."
        }
    }
    if (Test-Path -LiteralPath $root) {
        if (Test-LinkReparsePoint $root) {
            throw "Deletion containment: '$root' is a reparse point (junction or symbolic link); refusing to treat it as the staging root."
        }
    }
    $root
}

function Assert-ContainedStagingDirectory([string]$Candidate, [string]$StagingRoot, [string]$RepositoryRoot) {
    $containmentRoot = Resolve-CanonicalContainmentRoot $RepositoryRoot
    $root = Get-SafeStagingRoot $StagingRoot $containmentRoot
    $expanded = Assert-InContainmentNamespace $Candidate $containmentRoot 'the bundle directory'

    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    $trimmed = $expanded.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($trimmed.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: the staging root '$root' itself is never removed; pass a dedicated bundle subdirectory."
    }
    if (-not $expanded.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: '$expanded' is outside the staging root '$root'."
    }

    if (Test-Path -LiteralPath $expanded) {
        $item = Get-Item -LiteralPath $expanded -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::Directory)) {
            throw "Deletion containment: '$expanded' is not a directory."
        }
        if (Test-LinkReparsePoint $expanded) {
            throw "Deletion containment: '$expanded' is a reparse point (junction or symbolic link); refusing to remove it."
        }
    } elseif (Get-Item -LiteralPath $expanded -Force -ErrorAction SilentlyContinue) {
        # A link (including a dangling one) can exist without Test-Path resolving
        # it, so the attribute check runs before the existence decision.
        if (Test-LinkReparsePoint $expanded) {
            throw "Deletion containment: '$expanded' is a reparse point (junction or symbolic link); refusing to remove it."
        }
    }

    # A link anywhere in the parent chain between the staging root and the
    # candidate could redirect the recursive delete outside it, so every existing
    # component is classified before the canonical check below.
    $ancestor = [IO.Path]::GetDirectoryName($trimmed)
    while ($ancestor -and $ancestor.Length -gt $root.Length) {
        if (Test-Path -LiteralPath $ancestor) {
            if (Test-LinkReparsePoint $ancestor) {
                throw "Deletion containment: '$ancestor' in the parent chain of '$expanded' is a reparse point (junction or symbolic link); refusing to remove '$expanded'."
            }
        }
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $ancestor) { break }
        $ancestor = $parent
    }

    if (-not (Test-Path -LiteralPath $expanded)) {
        # Nothing to remove yet. The path is link-free, so the caller's
        # New-Item/Copy-Item creates real directories inside the staging root.
        return $expanded
    }

    $canonical = Get-ExistingAncestorPath $expanded
    if (-not $canonical) { throw "Deletion containment: '$expanded' could not be canonicalised." }
    # The canonical path must stay both inside the staging root and inside the
    # repository artifacts staging namespace, so a link cannot relocate it.
    $canonicalWithSeparator = [string]$canonical + [IO.Path]::DirectorySeparatorChar
    if (-not $canonicalWithSeparator.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: '$expanded' resolves outside the staging root '$root'."
    }
    # IndexOf is used instead of String.Contains(string, StringComparison): the
    # two-argument Contains overload only exists on .NET Core, and this script
    # also runs on Windows PowerShell 5.1 / .NET Framework 4.8.
    if ($canonicalWithSeparator.IndexOf([string]$containmentRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Deletion containment: '$expanded' resolves outside the repository artifacts staging area."
    }
    $canonical
}

$releases = @(Get-AutoCADMatrixEntries $matrixPath)
if (-not $Version -or $Version.Count -eq 0) {
    $requestedYears = @($releases | ForEach-Object { [string]$_.Include })
} else {
    $requestedYears = @(Get-AutoCADRequestedYears $Version)
}
if ($requestedYears.Count -eq 0) { throw 'No AutoCAD release was requested.' }

# Fail closed on the bundle staging root before any build work: an unsafe
# -BundleDirectory must be rejected up front, not after the matrix has already
# compiled adapters for this machine.
$bundleRoot = $null
if ($PSBoundParameters.ContainsKey('BundleDirectory') -and -not [string]::IsNullOrWhiteSpace($BundleDirectory)) {
    if (-not $PSBoundParameters.ContainsKey('StagingRoot') -or [string]::IsNullOrWhiteSpace($StagingRoot)) {
        $StagingRoot = Join-Path $repositoryRoot 'artifacts\staging\autocad-bundles'
    }
    $bundleRoot = Assert-ContainedStagingDirectory $BundleDirectory $StagingRoot $repositoryRoot
}

$results = New-Object System.Collections.ArrayList
$resolvedReleases = New-Object System.Collections.ArrayList
foreach ($year in $requestedYears) {
    $release = @($releases | Where-Object { [string]$_.Include -eq [string]$year })
    if ($release.Count -ne 1) { throw "Unknown or duplicate AutoCAD release in matrix: $year" }
    try {
        $release = Resolve-AutoCADMatrixEntry $release[0]
    } catch {
        if ($SkipUnavailable) {
            [void]$results.Add([ordered]@{ version=$year; status='skipped'; reason=$_.Exception.Message })
            continue
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $release.ApiPath -PathType Leaf)) {
        if ($SkipUnavailable) {
            [void]$results.Add([ordered]@{ version=$year; status='skipped'; reason='AutoCAD managed API not installed' })
            continue
        }
        throw "AutoCAD $year managed API was not found: $($release.ApiPath)"
    }

    $arguments = @(
        'build', $projectPath,
        '--nologo', '-v:minimal', '-clp:ErrorsOnly',
        '-c', $Configuration,
        '-nodeReuse:false', '-m:1',
        '-p:UseSharedCompilation=false',
        "-p:AutoCADVersion=$year",
        "-p:AutoCADTargetFramework=$($release.TargetFramework)",
        "-p:AutoCADInstallDir=$($release.InstallDirectory)",
        "-p:BaseIntermediateOutputPath=obj\$year\",
        "-p:MSBuildProjectExtensionsPath=obj\$year\"
    )
    if ($Offline) {
        # Explicit opt-in for a machine with no network access: the vulnerability
        # audit is the only step that reaches nuget.org, and it emits an
        # unreachable-source failure as NU1900 noise. Networked builds and hosted
        # CI keep the audit enabled.
        $arguments += '-p:NuGetAudit=false'
    }
    if ($NoRestore) { $arguments += '--no-restore' }
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "AutoCAD $year adapter build failed." }

    $outputDirectory = Join-Path $repositoryRoot "src\BimBridge.AutoCAD\bin\$Configuration\$year\$($release.TargetFramework)"
    $assemblyPath = Join-Path $outputDirectory "$($release.AssemblyName).dll"
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Expected AutoCAD $year adapter output was not produced: $assemblyPath"
    }

    [void]$resolvedReleases.Add($release)
    [void]$results.Add([ordered]@{
        version = $year
        status = 'built'
        targetFramework = $release.TargetFramework
        runtimeFamily = $release.RuntimeFamily
        runtimeResolution = $release.RuntimeResolution
        detectedRuntime = $release.DetectedRuntime
        dynamicCompiler = $release.DynamicCompiler
        supportStatus = $release.SupportStatus
        certificationStatus = $release.CertificationStatus
        assembly = $assemblyPath
    })
}

$bundleResult = $null
if ($BundleDirectory) {
    # Offline bundle staging: the surviving (non-skipped) matrix entries are
    # copied under Contents/Windows/<year>/ and one PackageContents.xml is
    # rendered from the shared template plus the single Autodesk matrix. No
    # second year list and no per-year manifest copy is involved.
    if ($resolvedReleases.Count -eq 0) { throw 'No resolved AutoCAD release is available to stage into a bundle.' }
    # The preflight above ran before the matrix compiled anything, so it must never
    # be the only authorization for a recursive delete: the staging root and the
    # bundle directory may have been replaced by a junction or symbolic link during
    # the build (TOCTOU). The whole guard therefore runs again immediately before
    # the removal, and only the path *this* re-check returned is deleted: the
    # canonical path is never re-derived from the preflight result. The guard
    # returns a path that does not exist whenever the canonical staging target is
    # still absent (a first-time run), so the existence decision is taken here,
    # from the re-checked path, and no removal is attempted in that case. Only
    # assignment statements separate the re-check from the removal, so nothing can
    # run between them.
    $bundleRoot = Assert-ContainedStagingDirectory $bundleRoot $StagingRoot $repositoryRoot
    $bundleRootExists = Test-Path -LiteralPath $bundleRoot
    if ($bundleRootExists) {
        Remove-Item -LiteralPath $bundleRoot -Recurse -Force
    }
    $stagedComponents = New-Object System.Collections.ArrayList
    foreach ($release in $resolvedReleases) {
        $year = [string]$release.Include
        $source = Join-Path $repositoryRoot "src\BimBridge.AutoCAD\bin\$Configuration\$year\$($release.TargetFramework)"
        $destination = Join-Path $bundleRoot "Contents\Windows\$year"
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
        $stagedAssembly = Join-Path $destination "$($release.AssemblyName).dll"
        if (-not (Test-Path -LiteralPath $stagedAssembly -PathType Leaf)) {
            throw "Staged AutoCAD $year adapter is missing: $stagedAssembly"
        }
        [void]$stagedComponents.Add([ordered]@{
            version = $year
            series = [string]$release.Series
            targetFramework = [string]$release.TargetFramework
            module = "./Contents/Windows/$year/$($release.AssemblyName).dll"
            assembly = $stagedAssembly
        })
    }
    $packageContents = New-AutoCADPackageContents $resolvedReleases -AppVersion '2.0.0' -TemplatePath $packageTemplatePath -ModuleDirectorySuffix 'Contents\Windows'
    $packageContentsPath = Join-Path $bundleRoot 'PackageContents.xml'
    [IO.File]::WriteAllText($packageContentsPath, $packageContents, [Text.UTF8Encoding]::new($false))

    # Fail the build if the rendered bundle ever loses the package identity that
    # the shared template owns, or if it declares a module that was not staged.
    # The shared verifier checks bundle structure but not these two properties,
    # so the renderer asserts its own output instead of leaving a silent gap.
    [xml]$renderedPackage = $packageContents
    $renderedRoot = $renderedPackage.ApplicationPackage
    if (-not $renderedRoot) { throw "The staged AutoCAD bundle has no ApplicationPackage root: $packageContentsPath" }
    if ([string]::IsNullOrWhiteSpace([string]$renderedRoot.ProductCode)) {
        throw "The staged AutoCAD bundle lost its ApplicationPackage ProductCode: $packageContentsPath"
    }
    if ([string]::IsNullOrWhiteSpace([string]$renderedRoot.AppVersion)) {
        throw "The staged AutoCAD bundle lost its ApplicationPackage AppVersion: $packageContentsPath"
    }
    $renderedComponents = @($renderedRoot.Components)
    if ($renderedComponents.Count -ne $resolvedReleases.Count) {
        throw "The staged AutoCAD bundle declares $($renderedComponents.Count) components for $($resolvedReleases.Count) resolved releases."
    }
    foreach ($staged in $stagedComponents) {
        $declared = @($renderedComponents | Where-Object { [string]$_.Description -eq "AutoCAD $($staged.version)" })
        if ($declared.Count -ne 1) { throw "The staged AutoCAD bundle has no single component for AutoCAD $($staged.version)." }
        if ([string]$declared[0].RuntimeRequirements.SeriesMin -ne [string]$staged.series -or
            [string]$declared[0].RuntimeRequirements.SeriesMax -ne [string]$staged.series) {
            throw "The staged AutoCAD $($staged.version) component does not declare series $($staged.series)."
        }
        if ([string]$declared[0].ComponentEntry.ModuleName -ne [string]$staged.module) {
            throw "The staged AutoCAD $($staged.version) component declares '$([string]$declared[0].ComponentEntry.ModuleName)' instead of '$($staged.module)'."
        }
    }

    $bundleResult = [ordered]@{
        bundleDirectory = $bundleRoot
        packageContents = $packageContentsPath
        productCode = [string]$renderedRoot.ProductCode
        appVersion = [string]$renderedRoot.AppVersion
        components = @($stagedComponents)
    }
}

$resultRows = @($results)
# One staging-intent rule, identical in both builders (docs/architecture.md,
# "Staged packages, builder output, and gaps"): an explicit staging request
# selects the envelope. -Envelope is accepted as a redundant spelling of that
# intent, so -BundleDirectory alone must not fall back to the array and silently
# discard the bundle summary it just wrote.
if ($Envelope -or ($null -ne $bundleRoot)) {
    # Machine-readable envelope for callers that need the staged bundle
    # description alongside the per-release results.
    [ordered]@{
        results = $resultRows
        bundle = $bundleResult
    } | ConvertTo-Json -Depth 6
} else {
    # Legacy contract: with no staging parameter and no envelope parameter the
    # builder still emits the top-level JSON array of per-release results that
    # existing callers iterate after ConvertFrom-Json.
    ConvertTo-Json -InputObject $resultRows -Depth 6
}
