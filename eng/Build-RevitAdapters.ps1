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
    [string]$RenderManifestDirectory,
    [string]$RenderAssemblyPathTemplate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$matrixPath = Join-Path $PSScriptRoot 'Autodesk.Versions.props'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.csproj'
$templatePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.addin.template'
$matrixHelperPath = Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1'
. $matrixHelperPath

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-RelativePath([string]$Root, [string]$Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$pathFull' is outside '$rootFull'."
    }
    $pathFull.Substring($rootFull.Length).Replace('\', '/')
}

# ---------------------------------------------------------------------------
# Fail-closed deletion containment.
#
# The only directory this script is ever allowed to remove is a bundle staging
# directory that canonically resolves *inside* its own staging root
# (`artifacts\staging\revit-bundles` by default). Every check below is a
# refusal: a drive root, the repository root or its parent, a user profile, a
# real Autodesk installation directory, a relative or absolute traversal, or a
# reparse point (junction/symlink) that escapes the root all throw before any
# Remove-Item can run. `-RenderManifestDirectory` is held to the same rule, so a
# render target can never be relocated outside the repository staging namespace
# either.
# ---------------------------------------------------------------------------

function Get-DirectorySegment([string]$Path) {
    # Splitting on both separators keeps `..` segments detectable on every
    # platform; [IO.Path]::GetFullPath leaves them in place.
    @([string]$Path -split '[\\/]' | Where-Object { $_ -ne '' })
}

function Test-LinkReparsePoint([string]$Path) {
    # Only link-style reparse points (a directory junction / mount point, tag
    # 0xA0000003, or a symbolic link, tag 0xA000000C) can redirect a recursive
    # delete outside the staging root. Hosts that classify *every* synced folder
    # as a reparse point (OneDrive placeholders use 0x9000e01a) must keep
    # working, so the reparse tag decides rather than the attributes alone. An
    # unreadable or missing tag fails closed. The return value is always a
    # boolean: fsutil output is discarded so it can never leak into the result.
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $output = @(& (Join-Path $env:SystemRoot 'System32\fsutil.exe') reparsepoint query $Path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Deletion containment: the reparse tag of '$Path' could not be read, so it cannot be trusted."
    }
    $tagLine = @($output | Where-Object { [string]$_ -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]+)' })[0]
    if (-not $tagLine) {
        throw "Deletion containment: no reparse tag was reported for '$Path'."
    }
    $null = [string]$tagLine -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]+)'
    # Compared as text: 0xA0000003 as an Int32 literal is negative, so a numeric
    # comparison against the unsigned tag value would never be true.
    $tagText = [string]$Matches[1]
    $isLink = $tagText.Equals('a0000003', [StringComparison]::OrdinalIgnoreCase) -or $tagText.Equals('a000000c', [StringComparison]::OrdinalIgnoreCase)
    return [bool]$isLink
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
    $expanded = Assert-InContainmentNamespace $Candidate $containmentRoot 'the staging directory'

    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    $trimmed = $expanded.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($trimmed.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deletion containment: the staging root '$root' itself is never removed; pass a dedicated staging subdirectory."
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

$releases = @(Get-RevitMatrixEntries $matrixPath)
if (-not $Version -or $Version.Count -eq 0) {
    $requestedYears = @($releases | ForEach-Object { [string]$_.Include })
} else {
    $requestedYears = @(Get-RevitRequestedYears $Version)
}
if ($requestedYears.Count -eq 0) { throw 'No Revit release was requested.' }

# Fail closed on every staging target before any build or render work: an unsafe
# -BundleDirectory or -RenderManifestDirectory must be rejected up front, not
# after the matrix has already compiled adapters for this machine.
$stagingRootPath = $StagingRoot
if (-not $PSBoundParameters.ContainsKey('StagingRoot') -or [string]::IsNullOrWhiteSpace($stagingRootPath)) {
    $stagingRootPath = Join-Path $repositoryRoot 'artifacts\staging\revit-bundles'
}
$bundleRoot = $null
$renderRoot = $null
if ($PSBoundParameters.ContainsKey('BundleDirectory') -and -not [string]::IsNullOrWhiteSpace($BundleDirectory)) {
    $bundleRoot = Assert-ContainedStagingDirectory $BundleDirectory $stagingRootPath $repositoryRoot
}
if ($PSBoundParameters.ContainsKey('RenderManifestDirectory') -and -not [string]::IsNullOrWhiteSpace($RenderManifestDirectory)) {
    # Render output is held to the same containment rule as the deleted bundle
    # root, so a render target can never be a drive root, the repository, a user
    # profile, or a real Autodesk installation directory.
    $renderRoot = Assert-ContainedStagingDirectory $RenderManifestDirectory $stagingRootPath $repositoryRoot
}
# The legacy contract is the default: only an explicit staging request switches
# the stdout shape from the top-level result array to the machine-readable
# envelope.
$explicitStaging = ($null -ne $bundleRoot) -or ($null -ne $renderRoot)

$results = New-Object System.Collections.ArrayList
$gaps = New-Object System.Collections.ArrayList
$renderedManifests = New-Object System.Collections.ArrayList
$resolvedReleases = New-Object System.Collections.ArrayList

foreach ($year in $requestedYears) {
    $release = @($releases | Where-Object { [string]$_.Include -eq [string]$year })
    if ($release.Count -ne 1) { throw "Unknown or duplicate Revit release in matrix: $year" }
    $declared = $release[0]

    # Render-only mode resolves nothing from the machine: it proves that the
    # shared template plus the single version matrix still produce a valid
    # manifest for every declared release, including a release whose product is
    # not installed here.
    if ($RenderManifestDirectory) {
        $renderTarget = [string]$declared.TargetFramework
        $assemblyPath = if ($RenderAssemblyPathTemplate) {
            ([string]$RenderAssemblyPathTemplate).
                Replace('{year}', [string]$declared.Include).
                Replace('{targetFramework}', $renderTarget).
                Replace('{assemblyName}', [string]$declared.AssemblyName)
        } else {
            "$($declared.AssemblyName).dll"
        }
        $renderDirectory = Join-Path $renderRoot ("$($declared.Include)\$renderTarget")
        # Point-of-use re-check. The render root was proven contained when the run
        # started, but every earlier release in this loop has since been resolved,
        # and the path is about to create directories and overwrite a manifest. The
        # guard is re-run here, adjacent to the first write, and only the canonical
        # path it returns is used: a render root swapped for a junction after the
        # preflight is refused before anything is created or overwritten.
        $renderRoot = Assert-ContainedStagingDirectory $renderRoot $stagingRootPath $repositoryRoot
        $renderDirectory = Join-Path $renderRoot ("$($declared.Include)\$renderTarget")
        New-Item -ItemType Directory -Force -Path $renderDirectory | Out-Null
        $renderPath = Join-Path $renderDirectory ([string]$declared.ManifestName)
        Write-Utf8NoBom $renderPath (New-RevitAddInManifest $declared $assemblyPath $templatePath)
        $validation = Test-RevitAddInManifest $declared $renderPath
        if (-not $validation.valid) {
            throw "Rendered Revit $year manifest is invalid: $($validation.errors -join '; ')"
        }
        [void]$renderedManifests.Add([ordered]@{
            version = [string]$declared.Include
            targetFramework = $renderTarget
            manifest = $renderPath
            addInId = $validation.addInId
            useRevitContext = $validation.useRevitContext
            contextName = $validation.contextName
            assemblyPathToken = $assemblyPath
        })
        continue
    }

    # An absent product is reported as an explicit gap before the runtime
    # resolver runs, so the top-level message names the missing product instead
    # of one secondary metadata file inside it.
    $declaredInstallDirectory = Join-Path $env:ProgramFiles ([string]$declared.InstallSubdirectory)
    if (-not (Test-Path -LiteralPath $declaredInstallDirectory -PathType Container)) {
        $reason = "Revit $year is not installed on this machine: $declaredInstallDirectory"
        if (-not $SkipUnavailable) { throw $reason }
        [void]$gaps.Add((New-RevitUnavailableGap ([pscustomobject]@{
            Include = [string]$declared.Include
            AssemblyName = [string]$declared.AssemblyName
            ManifestName = [string]$declared.ManifestName
            InstallDirectory = $declaredInstallDirectory
            ApiPath = Join-Path $declaredInstallDirectory 'RevitAPI.dll'
            RevitExecutable = Join-Path $declaredInstallDirectory 'Revit.exe'
            RuntimeFamily = [string]$declared.RuntimeFamily
            RuntimeResolution = [string]$declared.RuntimeResolution
        }) $reason 'T4'))
        [void]$results.Add([ordered]@{
            version = $year
            status = 'unavailable'
            reason = $reason
            gap = 'revit-' + $year + '-not-installed'
        })
        continue
    }

    try {
        $resolved = Resolve-RevitMatrixEntry $declared
    } catch {
        if (-not $SkipUnavailable) { throw }
        $declaredForGap = [pscustomobject]@{
            Include = [string]$declared.Include
            AssemblyName = [string]$declared.AssemblyName
            ManifestName = [string]$declared.ManifestName
            InstallDirectory = $declaredInstallDirectory
            ApiPath = Join-Path $declaredInstallDirectory 'RevitAPI.dll'
            RevitExecutable = Join-Path $declaredInstallDirectory 'Revit.exe'
            RuntimeFamily = [string]$declared.RuntimeFamily
            RuntimeResolution = [string]$declared.RuntimeResolution
        }
        [void]$gaps.Add((New-RevitUnavailableGap $declaredForGap $_.Exception.Message 'T4'))
        [void]$results.Add([ordered]@{
            version = $year
            status = 'unavailable'
            reason = $_.Exception.Message
            gap = 'revit-' + $year + '-not-installed'
        })
        continue
    }

    if (-not (Test-Path -LiteralPath $resolved.ApiPath -PathType Leaf)) {
        $reason = "Revit $year API was not found: $($resolved.ApiPath)"
        if (-not $SkipUnavailable) { throw $reason }
        [void]$gaps.Add((New-RevitUnavailableGap $resolved $reason 'T4'))
        [void]$results.Add([ordered]@{
            version = $year
            status = 'unavailable'
            reason = $reason
            gap = 'revit-' + $year + '-not-installed'
        })
        continue
    }

    $targetFramework = $resolved.TargetFramework
    $installDir = $resolved.InstallDirectory
    $arguments = @(
        'build', $projectPath,
        '--nologo', '-v:minimal', '-clp:ErrorsOnly',
        '-c', $Configuration,
        # One build node only: the parallel multi-target build of the shared core
        # project is not reliable in this environment and reports a bare failure
        # with no diagnostic.
        '-m:1', '-nodeReuse:false', '-p:UseSharedCompilation=false',
        "-p:RevitVersion=$year",
        "-p:RevitTargetFramework=$targetFramework",
        "-p:RevitInstallDir=$installDir",
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
    if ($LASTEXITCODE -ne 0) { throw "Revit $year adapter build failed." }

    $outputDirectory = Join-Path $repositoryRoot "src\BimBridge.Revit\bin\$Configuration\$year\$targetFramework"
    $assemblyName = "$($resolved.AssemblyName).dll"
    $assemblyPath = Join-Path $outputDirectory $assemblyName
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Expected Revit $year adapter output was not produced: $assemblyPath"
    }

    $manifestPath = Join-Path $outputDirectory $resolved.ManifestName
    Write-Utf8NoBom $manifestPath (New-RevitAddInManifest $resolved $assemblyPath $templatePath)
    $validation = Test-RevitAddInManifest $resolved $manifestPath
    if (-not $validation.valid) {
        throw "Generated Revit $year manifest is invalid: $($validation.errors -join '; ')"
    }

    [void]$resolvedReleases.Add($resolved)
    [void]$results.Add([ordered]@{
        version = $year
        status = 'built'
        targetFramework = $targetFramework
        runtimeFamily = $resolved.RuntimeFamily
        runtimeResolution = $resolved.RuntimeResolution
        detectedRuntime = $resolved.DetectedRuntime
        dynamicCompiler = $resolved.DynamicCompiler
        addInId = $validation.addInId
        useRevitContext = $validation.useRevitContext
        contextName = $validation.contextName
        supportStatus = $resolved.SupportStatus
        certificationStatus = $resolved.CertificationStatus
        assembly = $assemblyPath
        manifest = $manifestPath
    })
}

$bundleResult = $null
if ($bundleRoot) {
    # Offline staging only. The bundle is a repository-local development
    # package: nothing here writes an Autodesk add-in location, user state, or
    # the registry.
    if ($resolvedReleases.Count -eq 0) { throw 'No resolved Revit release is available to stage into a bundle.' }
    # The preflight guard above proved the target was contained when the run
    # started, but the per-release build loop runs for minutes, and the target can
    # be replaced with a junction or symbolic link in that window (TOCTOU). The
    # whole guard therefore runs again immediately before the removal, and only the
    # path *this* re-check returned is deleted: the canonical path is never
    # re-derived from the preflight result. The guard returns a path that does not
    # exist whenever the canonical staging target is still absent (a first-time
    # run), so the existence decision is taken here, from the re-checked path, and
    # no removal is attempted in that case. Only assignment statements separate the
    # re-check from the removal, so nothing can run between them.
    $bundleRoot = Assert-ContainedStagingDirectory $bundleRoot $stagingRootPath $repositoryRoot
    $bundleRootExists = Test-Path -LiteralPath $bundleRoot
    if ($bundleRootExists) {
        Remove-Item -LiteralPath $bundleRoot -Recurse -Force
    }

    $stagedFiles = New-Object System.Collections.ArrayList
    foreach ($resolved in $resolvedReleases) {
        $year = [string]$resolved.Include
        $source = Join-Path $repositoryRoot "src\BimBridge.Revit\bin\$Configuration\$year\$($resolved.TargetFramework)"
        $destination = Join-Path $bundleRoot "src\BimBridge.Revit\bin\$Configuration\$year\$($resolved.TargetFramework)"
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        # An explicit file list keeps retired, non-BIM-Bridge artifacts that may
        # still sit in the output directory out of the package.
        $componentFiles = @(
            "$($resolved.AssemblyName).dll",
            "$($resolved.AssemblyName).pdb",
            [string]$resolved.ManifestName,
            'BimBridge.Host.dll',
            'BimBridge.Host.pdb'
        )
        if ([string]$resolved.RuntimeFamily -eq 'modern') {
            $componentFiles += "$($resolved.AssemblyName).deps.json"
        }
        foreach ($name in $componentFiles) {
            $sourceFile = Join-Path $source $name
            if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                throw "Expected Revit $year build output is missing: $sourceFile"
            }
            Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $destination $name) -Force
        }

        $stagedAssembly = Join-Path $destination "$($resolved.AssemblyName).dll"
        if (-not (Test-Path -LiteralPath $stagedAssembly -PathType Leaf)) {
            throw "Staged Revit $year adapter is missing: $stagedAssembly"
        }
        $stagedManifest = Join-Path $destination $resolved.ManifestName
        if (-not (Test-Path -LiteralPath $stagedManifest -PathType Leaf)) {
            throw "Staged Revit $year manifest is missing: $stagedManifest"
        }
        $stagedValidation = Test-RevitAddInManifest $resolved $stagedManifest
        if (-not $stagedValidation.valid) {
            throw "Staged Revit $year manifest is invalid: $($stagedValidation.errors -join '; ')"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $destination -File -Recurse)) {
            # `path` is duplicated as `relativePath` so the integrator can merge
            # this fragment into either shape of the release manifest.
            $relative = Get-RelativePath $bundleRoot $file.FullName
            [void]$stagedFiles.Add([ordered]@{
                path = $relative
                relativePath = $relative
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                bytes = $file.Length
                year = $year
                targetFramework = [string]$resolved.TargetFramework
                resolvedRuntime = $resolved.DetectedRuntime
            })
        }
    }

    $bundleManifest = [ordered]@{
        schemaVersion = 1
        product = 'bim-bridge'
        component = 'revit'
        configuration = $Configuration
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        releases = @($resolvedReleases | ForEach-Object {
            [ordered]@{
                version = [string]$_.Include
                assemblyName = [string]$_.AssemblyName
                manifestName = [string]$_.ManifestName
                targetFramework = [string]$_.TargetFramework
                runtimeFamily = [string]$_.RuntimeFamily
                runtimeResolution = [string]$_.RuntimeResolution
                resolvedRuntime = $_.DetectedRuntime
                certificationStatus = [string]$_.CertificationStatus
                supportStatus = [string]$_.SupportStatus
            }
        })
        files = @($stagedFiles)
        unavailableReleases = @($gaps)
    }
    $bundleManifestPath = Join-Path $bundleRoot 'bundle-manifest.json'
    Write-Utf8NoBom $bundleManifestPath ($bundleManifest | ConvertTo-Json -Depth 6)

    $bundleResult = [ordered]@{
        bundleDirectory = $bundleRoot
        manifest = $bundleManifestPath
        releases = @($resolvedReleases | ForEach-Object { [string]$_.Include })
        fileCount = $stagedFiles.Count
        unavailableReleases = @($gaps | ForEach-Object { $_.year })
    }
}

$resultRows = @($results)
if ($explicitStaging) {
    # Explicit staging mode: the caller asked for a bundle or a rendered manifest
    # directory, so it also receives the machine-readable envelope that describes
    # the staged output.
    [ordered]@{
        results = $resultRows
        renderedManifests = @($renderedManifests)
        gaps = @($gaps)
        bundle = $bundleResult
    } | ConvertTo-Json -Depth 6
} else {
    # Legacy contract: without -BundleDirectory or -RenderManifestDirectory the
    # builder still emits the top-level JSON array of per-release results that
    # existing callers iterate after ConvertFrom-Json.
    ConvertTo-Json -InputObject $resultRows -Depth 6
}
