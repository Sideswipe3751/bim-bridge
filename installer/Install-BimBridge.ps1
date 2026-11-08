[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$SourceRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SkipBuild,
    [switch]$ValidateOnly,
    [switch]$MigrateLegacy,
    [hashtable]$ProductInstallPathOverrides,
    [object[]]$RegistryInstallRecords,
    # Test seam: point the pre-existing install-state files at controlled paths so a
    # regression can exercise state-dependent resolution without touching the real
    # per-user installation. The installer itself never passes these.
    [string]$StatePathOverride,
    [string]$LegacyStatePathOverride
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

function Get-UserPath([Environment+SpecialFolder]$Folder) {
    [Environment]::GetFolderPath($Folder)
}

# ---------------------------------------------------------------------------
# Read-only preflight contract, enforced before any CLI discovery, MCP read,
# install-state read, process check, ShouldProcess prompt or write.
#
# `-ValidateOnly` means "inspect and report, change nothing". It previously sat after
# the `-Action Uninstall` branch, so `-Action Uninstall -ValidateOnly` still ran the
# uninstall path. The action is now restricted up front, and the test-seam overrides
# are only accepted for that read-only preflight with a permitted action.
# ---------------------------------------------------------------------------
if ($ValidateOnly -and $Action -notin @('Install', 'Repair')) {
    throw ("-ValidateOnly is a read-only preflight and is only supported for -Action Install or -Action Repair. Received -Action $Action with -ValidateOnly; uninstalling is never a read-only operation.")
}
$overrideSupplied = [bool]($StatePathOverride -or $LegacyStatePathOverride)
if ($overrideSupplied -and (-not $ValidateOnly -or $Action -notin @('Install', 'Repair'))) {
    throw ('-StatePathOverride and -LegacyStatePathOverride are read-only preflight test seams and are only supported with -ValidateOnly together with -Action Install or -Action Repair. ' +
        "Received Action '$Action', ValidateOnly '$ValidateOnly'.")
}
# The containment roots the trusted resolver checks against. Without an override they
# are the real per-user roots; with one they are derived from the override's own
# parent, so a controlled test tree is judged against the controlled root rather than
# against the real installation.
$effectiveStateRoot = Join-Path (Get-UserPath LocalApplicationData) 'BIM Bridge'
$effectiveLegacyStateRoot = Join-Path (Get-UserPath LocalApplicationData) 'AEC Codex'
if ($StatePathOverride) { $effectiveStateRoot = Split-Path -Parent ([IO.Path]::GetFullPath($StatePathOverride)) }
if ($LegacyStatePathOverride) { $effectiveLegacyStateRoot = Split-Path -Parent ([IO.Path]::GetFullPath($LegacyStatePathOverride)) }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Write-Utf8NoBom $temporary ($Value | ConvertTo-Json -Depth 12)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Remove-DirectoryTree([string]$Path, [switch]$BestEffort) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $resolved = [IO.Path]::GetFullPath($Path)
        $extended = if ($resolved.StartsWith('\\?\')) { $resolved } else { '\\?\' + $resolved }
        foreach ($file in [IO.Directory]::EnumerateFiles($extended, '*', [IO.SearchOption]::AllDirectories)) {
            try { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal) } catch { }
            [IO.File]::Delete($file)
        }
        foreach ($directory in @([IO.Directory]::EnumerateDirectories($extended, '*', [IO.SearchOption]::AllDirectories) | Sort-Object Length -Descending)) {
            [IO.Directory]::Delete($directory, $false)
        }
        [IO.Directory]::Delete($extended, $false)
    } catch {
        if (-not $BestEffort) { throw }
    }
}

function Copy-Directory([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Required directory is missing: $Source" }
    if (Test-Path -LiteralPath $Destination) { throw "Staging destination already exists: $Destination" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
}

function Backup-Path([string]$Path, [string]$BackupRoot, [System.Collections.ArrayList]$Records) {
    $backup = $null
    if (Test-Path -LiteralPath $Path) {
        $backup = Join-Path $BackupRoot ([Guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $Path -Destination $backup
    }
    [void]$Records.Add([pscustomobject]@{ Path=$Path; Backup=$backup })
}

function Restore-Backups([System.Collections.ArrayList]$Records) {
    for ($index = $Records.Count - 1; $index -ge 0; $index--) {
        $record = $Records[$index]
        if (Test-Path -LiteralPath $record.Path) { Remove-DirectoryTree $record.Path }
        if ($record.Backup -and (Test-Path -LiteralPath $record.Backup)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $record.Path) | Out-Null
            Move-Item -LiteralPath $record.Backup -Destination $record.Path
        }
    }
}

function Find-CodexCli {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) {
        try { & $command.Source --version *> $null; if ($LASTEXITCODE -eq 0) { return $command.Source } } catch { }
    }
    $candidate = Join-Path (Get-UserPath UserProfile) '.codex\plugins\.plugin-appserver\codex.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        try { & $candidate --version *> $null; if ($LASTEXITCODE -eq 0) { return $candidate } } catch { }
    }
    throw 'Codex CLI is unavailable; BIM Bridge cannot safely update its MCP registration.'
}

function Test-CodexMcp([string]$Cli, [string]$Name) {
    try { & $Cli mcp get $Name --json *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Get-CodexMcp([string]$Cli, [string]$Name) {
    try {
        $json = & $Cli mcp get $Name --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) { return ($json | ConvertFrom-Json) }
    } catch { }
    return $null
}

function Remove-CodexMcp([string]$Cli, [string]$Name) {
    if (-not (Test-CodexMcp $Cli $Name)) { return }
    & $Cli mcp remove $Name *> $null
    if ($LASTEXITCODE -ne 0) { throw "Unable to remove Codex MCP registration '$Name'." }
}

function Register-CodexMcp([string]$Cli, [string]$Name, [string]$Launcher) {
    Remove-CodexMcp $Cli $Name
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $Cli mcp add $Name -- $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Launcher
    if ($LASTEXITCODE -ne 0 -or -not (Test-CodexMcp $Cli $Name)) {
        throw "Unable to register Codex MCP '$Name'."
    }
}

function Restore-CodexMcp([string]$Cli, [string]$Name, [object]$Definition) {
    Remove-CodexMcp $Cli $Name
    if (-not $Definition) { return }
    $transport = $Definition.transport
    if (-not $transport -or [string]$transport.type -ne 'stdio' -or -not $transport.command) {
        throw "Cannot restore unsupported MCP registration '$Name'."
    }
    $arguments = New-Object System.Collections.ArrayList
    [void]$arguments.Add('mcp')
    [void]$arguments.Add('add')
    [void]$arguments.Add($Name)
    if ($transport.env) {
        foreach ($property in $transport.env.PSObject.Properties) {
            [void]$arguments.Add('--env')
            [void]$arguments.Add(([string]$property.Name + '=' + [string]$property.Value))
        }
    }
    [void]$arguments.Add('--')
    [void]$arguments.Add([string]$transport.command)
    foreach ($argument in @($transport.args)) { [void]$arguments.Add([string]$argument) }
    & $Cli @arguments *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-CodexMcp $Cli $Name)) {
        throw "Unable to restore Codex MCP registration '$Name'."
    }
}

function Test-LinkReparseTag([string]$TagText) {
    # Only a real directory junction / mount point (0xA0000003) or symbolic link
    # (0xA000000C) can redirect a path out of its root. A cloud-sync placeholder
    # (OneDrive uses 0x9000e01a) carries the reparse *attribute* but is benign, so the
    # attribute alone must never decide. A tag that cannot be read fails closed.
    if ([string]::IsNullOrWhiteSpace($TagText)) { return $false }
    $normalized = ([string]$TagText).Trim().ToLowerInvariant() -replace '^0x', ''
    return ($normalized -eq 'a0000003' -or $normalized -eq 'a000000c')
}

function Test-LinkReparsePoint([string]$Path) {
    # Returns $true only for a real link-style reparse point; $null when the entry is a
    # reparse point whose tag could not be classified (the caller must fail closed).
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $output = @(& (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\fsutil.exe') reparsepoint query $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { return $null }
    $tagLine = @($output | Where-Object { [string]$_ -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]{8})' })[0]
    if (-not $tagLine) { return $null }
    $null = [string]$tagLine -match 'Reparse Tag Value\s*:\s*0x([0-9a-fA-F]{8})'
    return [bool](Test-LinkReparseTag ([string]$Matches[1]))
}

function Test-PathContainedInDirectory([string]$Candidate, [string]$Root) {
    # Fail-closed containment for a path that a state file points at. A state file is
    # data, not authority: a tampered or stale `python` value must not be able to name
    # an executable anywhere on the machine.
    #
    # Rules, applied to the *root itself* and to every existing segment below it:
    #   * both paths rooted and canonicalised, compared with a separator-terminated
    #     prefix;
    #   * raw `..` segments refused before canonicalisation;
    #   * a real link reparse point (junction / mount point / symlink) anywhere on the
    #     chain - the root included - refused, so a junction cannot redirect the lookup
    #     outside the root;
    #   * a reparse point whose tag cannot be read refused;
    #   * a benign cloud placeholder tolerated, because it cannot redirect anything.
    # Returns @{ Contained; Reason }.
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) {
        return @{ Contained = $false; Reason = 'the path or its root is empty' }
    }
    if (-not [IO.Path]::IsPathRooted($Candidate) -or -not [IO.Path]::IsPathRooted($Root)) {
        return @{ Contained = $false; Reason = 'the path or its root is not absolute' }
    }
    if (@([string]$Candidate -split '[\\/]' | Where-Object { $_ -ceq '..' }).Count -gt 0) {
        return @{ Contained = $false; Reason = 'the path contains a traversal segment' }
    }
    try {
        $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $canonicalCandidate = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    } catch {
        return @{ Contained = $false; Reason = 'the path or its root could not be canonicalised' }
    }
    $prefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    if ($canonicalCandidate -ne $canonicalRoot -and -not $canonicalCandidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Contained = $false; Reason = "is outside '$canonicalRoot'" }
    }
    # The root itself, then every existing segment below it.
    $probe = $canonicalRoot
    $relative = $canonicalCandidate.Substring($canonicalRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $segments = @('') + @($relative -split '[\\/]' | Where-Object { $_ -ne '' })
    foreach ($segment in $segments) {
        if ($segment) { $probe = $probe + [IO.Path]::DirectorySeparatorChar + $segment }
        if (-not (Test-Path -LiteralPath $probe)) { continue }
        $linkState = Test-LinkReparsePoint $probe
        if ($null -eq $linkState) {
            return @{ Contained = $false; Reason = "'$probe' is a reparse point whose tag could not be classified" }
        }
        if ($linkState) {
            return @{ Contained = $false; Reason = "'$probe' is a link reparse point (junction, mount point or symbolic link)" }
        }
    }
    return @{ Contained = $true; Reason = $null }
}

function Resolve-PrivatePythonSource([string]$RepoRoot, [object]$CurrentState, [object]$LegacyState, [string]$StateRoot, [string]$LegacyStateRoot) {
    # The single source of truth for "which private Python runtime gets shipped".
    # Read-only: it probes paths and returns a decision, and never creates, writes,
    # moves or deletes anything.
    #
    # Both the read-only preflight (`-ValidateOnly`) and the real Install/Repair path
    # must use this function. They previously disagreed: the preflight accepted only
    # `<SourceRoot>\runtime\python`, while the real install additionally fell back to
    # the Python recorded in the current install-state and then to the legacy state.
    # On a machine where the repository `runtime/python` tree is absent but a valid
    # installed Host has its own Python, the preflight therefore failed with
    # "The release package has no private Python runtime." even though the install
    # would have succeeded. Sharing one resolver removes that class of divergence.
    #
    # Priority is exactly the install path's historical order:
    #   1. repository        <RepoRoot>\runtime\python\python.exe
    #   2. current state     <StateRoot>\host\<version>\python\python.exe
    #   3. legacy state      <LegacyStateRoot>\host\<version>\runtime\python\python.exe
    #
    # Every candidate is a *trusted* location: a state file supplies only the version
    # segment, and the resolved directory must be canonically contained in the host
    # subtree of the state file that named it. A state file that points at an
    # executable elsewhere on the machine is refused rather than copied into the Host.
    $candidates = New-Object System.Collections.ArrayList
    # The repository runtime is a trusted location only when it is actually contained in
    # `<RepoRoot>\runtime\python`: the same chain and link classification applies, so a
    # junction planted there cannot redirect the staged Host's interpreter.
    $repoRuntimeDirectory = Join-Path $RepoRoot 'runtime\python'
    $repoRuntimeProbe = Join-Path $repoRuntimeDirectory 'python.exe'
    $repoRuntimeDecision = Test-PathContainedInDirectory -Candidate $repoRuntimeProbe -Root $repoRuntimeDirectory
    [void]$candidates.Add([pscustomobject]@{
            Kind        = 'repository-runtime'
            Directory   = $repoRuntimeDirectory
            Recorded    = $repoRuntimeProbe
            TrustedBy   = $repoRuntimeDirectory
            Uncontained = -not $repoRuntimeDecision.Contained
            Reason      = $repoRuntimeDecision.Reason
        })
    if ($CurrentState -and $CurrentState.python) {
        $recordedPython = [string]$CurrentState.python
        # The recorded path supplies the version segment only; the directory that is
        # actually used is rebuilt under the trusted host root.
        $versionSegment = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $recordedPython))
        $trustedDirectory = if ($versionSegment) { Join-Path (Join-Path $StateRoot 'host') (Join-Path $versionSegment 'python') } else { $null }
        $trustedBy = Join-Path $StateRoot 'host'
        $currentDecision = Test-PathContainedInDirectory -Candidate $recordedPython -Root $trustedBy
        # A state file only names a version; the version it *records* must agree with the
        # version segment of the path it points at, or the record is not trustworthy.
        $currentVersionAgrees = ($null -ne $CurrentState.PSObject.Properties['version']) -and
            ([string]$CurrentState.version) -ceq ([string]$versionSegment)
        $currentSchemaSupported = ([int]$CurrentState.schemaVersion -eq 4)
        $currentReason = if (-not $currentSchemaSupported) { "records schemaVersion $($CurrentState.schemaVersion), which is not the supported schema 4" }
        elseif (-not $currentVersionAgrees) { "records version '$($CurrentState.version)' but its python path names version '$versionSegment'" }
        elseif (-not $currentDecision.Contained) { $currentDecision.Reason }
        else { $null }
        [void]$candidates.Add([pscustomobject]@{
                Kind        = 'current-install-state'
                Directory   = $trustedDirectory
                Recorded    = $recordedPython
                TrustedBy   = $trustedBy
                Uncontained = ($null -ne $currentReason)
                Reason      = $currentReason
            })
    }
    if ($LegacyState -and $LegacyState.privatePython) {
        $recordedLegacyPython = [string]$LegacyState.privatePython
        $legacyVersionSegment = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $recordedLegacyPython)))
        $trustedLegacyDirectory = if ($legacyVersionSegment) { Join-Path (Join-Path (Join-Path $LegacyStateRoot 'host') $legacyVersionSegment) 'runtime\python' } else { $null }
        $trustedLegacyBy = Join-Path $LegacyStateRoot 'host'
        $legacyDecision = Test-PathContainedInDirectory -Candidate $recordedLegacyPython -Root $trustedLegacyBy
        # The legacy Install-AecCodex state used schema 3; schema 4 is accepted too so a
        # republished legacy Host is not refused for the schema alone.
        $legacySchemaSupported = ([int]$LegacyState.schemaVersion -eq 3) -or ([int]$LegacyState.schemaVersion -eq 4)
        $legacyVersionAgrees = ($null -ne $LegacyState.PSObject.Properties['version']) -and
            ([string]$LegacyState.version) -ceq ([string]$legacyVersionSegment)
        $legacyReason = if (-not $legacySchemaSupported) { "records schemaVersion $($LegacyState.schemaVersion), which is neither the legacy schema 3 nor schema 4" }
        elseif (-not $legacyVersionAgrees) { "records version '$($LegacyState.version)' but its privatePython path names version '$legacyVersionSegment'" }
        elseif (-not $legacyDecision.Contained) { $legacyDecision.Reason }
        else { $null }
        [void]$candidates.Add([pscustomobject]@{
                Kind        = 'legacy-install-state'
                Directory   = $trustedLegacyDirectory
                Recorded    = $recordedLegacyPython
                TrustedBy   = $trustedLegacyBy
                Uncontained = ($null -ne $legacyReason)
                Reason      = $legacyReason
            })
    }
    $refused = @($candidates | Where-Object { $_.Uncontained })
    if ($refused.Count -gt 0) {
        return [pscustomobject]@{
            Available  = $false
            Directory  = $null
            Executable = $null
            SourceKind = 'none'
            Refused    = @($refused | ForEach-Object { "$($_.Kind): $($_.Reason)" })
            Probed     = @($candidates | Where-Object { $_.Directory } | ForEach-Object { Join-Path ([string]$_.Directory) 'python.exe' })
        }
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Directory)) { continue }
        $executable = Join-Path ([string]$candidate.Directory) 'python.exe'
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            return [pscustomobject]@{
                Available = $true
                Directory = [string]$candidate.Directory
                Executable = $executable
                SourceKind = [string]$candidate.Kind
            }
        }
    }
    # Nothing is valid: report every location that was probed, in priority order, so
    # the caller can explain precisely what is missing instead of only the first path.
    return [pscustomobject]@{
        Available = $false
        Directory = $null
        Executable = $null
        SourceKind = 'none'
        Probed = @($candidates | ForEach-Object { Join-Path ([string]$_.Directory) 'python.exe' })
    }
}

function Stop-OwnedHostProcesses([string[]]$Roots) {
    $normalizedRoots = @($Roots | Where-Object { $_ } | ForEach-Object {
        [IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    })
    if ($normalizedRoots.Count -eq 0) { return }
    $candidateNames = @('powershell.exe','pwsh.exe','python.exe','node.exe')
    function Get-OwnedProcessIds {
        @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                if ($candidateNames -notcontains ([string]$_.Name).ToLowerInvariant()) { return $false }
                $executable = [string]$_.ExecutablePath
                $commandLine = [string]$_.CommandLine
                foreach ($root in $normalizedRoots) {
                    if (($executable -and $executable.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) -or
                        ($commandLine -and $commandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                        return $true
                    }
                }
                return $false
            } | ForEach-Object { [int]$_.ProcessId }
        )
    }
    $processIds = @(Get-OwnedProcessIds)
    if ($processIds.Count -eq 0) { return }
    foreach ($processId in $processIds) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 200
        $remaining = @(Get-OwnedProcessIds)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        throw ('BIM Bridge could not stop owned Host processes: ' + ($remaining -join ', '))
    }
}

function New-FileRecords([string[]]$Roots) {
    $records = New-Object System.Collections.ArrayList
    foreach ($root in $Roots) {
        if (Test-Path -LiteralPath $root -PathType Leaf) {
            [void]$records.Add([ordered]@{ path=$root; sha256=(Get-FileHash -LiteralPath $root -Algorithm SHA256).Hash.ToLowerInvariant() })
        } elseif (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {
                $_.Extension -ne '.pyc' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]'
            })) {
                [void]$records.Add([ordered]@{ path=$file.FullName; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
            }
        }
    }
    return @($records)
}

function Remove-StaleTransactionDirectories([string]$Root, [string[]]$Keep) {
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'staging-*' -or $_.Name -like 'rollback-*'
    })) {
        $resolved = [IO.Path]::GetFullPath($directory.FullName)
        if (-not $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $kept = @($Keep | Where-Object { $_ -and ([IO.Path]::GetFullPath($_) -eq $resolved) })
        if ($kept.Count -gt 0) { continue }
        Remove-DirectoryTree $resolved -BestEffort
    }
}

$pluginManifestPath = Join-Path $SourceRoot 'plugins\bim-bridge\.codex-plugin\plugin.json'
$releaseManifestPath = Join-Path $SourceRoot 'plugins\bim-bridge\release-manifest.json'
$matrixPath = Join-Path $SourceRoot 'eng\Autodesk.Versions.props'
$matrixHelperPath = Join-Path $SourceRoot 'eng\AutodeskVersionMatrix.ps1'
$productDiscoveryPath = Join-Path $SourceRoot 'plugins\bim-bridge\scripts\AutodeskProductDiscovery.ps1'
foreach ($required in @($pluginManifestPath, $releaseManifestPath, $matrixPath, $matrixHelperPath, $productDiscoveryPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required BIM Bridge source file is missing: $required" }
}

$pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw | ConvertFrom-Json
$releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
if ($pluginManifest.name -ne 'bim-bridge') { throw 'The source plugin is not BIM Bridge.' }
if ($releaseManifest.schemaVersion -ne 2) { throw 'Unsupported BIM Bridge release manifest.' }
$basePluginVersion = ([string]$pluginManifest.version) -replace '\+.*$',''
if ($basePluginVersion -ne [string]$releaseManifest.version) { throw 'Plugin and release manifest versions do not match.' }

$roaming = Get-UserPath ApplicationData
$local = Get-UserPath LocalApplicationData
$stateRoot = Join-Path $local 'BIM Bridge'
$statePath = Join-Path $stateRoot 'install-state.json'
if ($StatePathOverride) { $statePath = [IO.Path]::GetFullPath($StatePathOverride) }
$hostRoot = Join-Path $stateRoot ('host\' + $basePluginVersion)
$connectorRoot = Join-Path $stateRoot 'connectors'
$autoCADBundle = Join-Path $roaming 'Autodesk\ApplicationPlugins\BIM Bridge.bundle'
$legacyStateRoot = Join-Path $local 'AEC Codex'
$legacyRoamingRoot = Join-Path $roaming 'AEC Codex'
$legacyHostRoot = Join-Path $legacyStateRoot 'host'
$legacyMaintenanceRoot = Join-Path $legacyStateRoot 'maintenance'
$legacyInstallState = Join-Path $legacyStateRoot 'install-state.json'
if ($LegacyStatePathOverride) { $legacyInstallState = [IO.Path]::GetFullPath($LegacyStatePathOverride) }
$legacyProviderRoot = Join-Path $legacyStateRoot 'providers'
$legacyRoamingProviders = Join-Path $legacyRoamingRoot 'providers'
$legacyAutoCADBundle = Join-Path $roaming 'Autodesk\ApplicationPlugins\AEC Codex.bundle'
$legacyRevitDirectory = Join-Path $roaming 'Autodesk\Revit\Addins\2024\AEC Codex'
$legacyRevitManifest = Join-Path $roaming 'Autodesk\Revit\Addins\2024\AEC.Codex.addin'
$legacyProviderDirectory = Join-Path $roaming 'Autodesk\Revit\Addins\2024\AEC Codex Providers'
$legacyProviderManifest = Join-Path $roaming 'Autodesk\Revit\Addins\2024\AEC.Codex.Providers.addin'
$codexCli = $null
$newMcpName = [string]$releaseManifest.mcpRegistration
$legacyMcpName = [string]$releaseManifest.legacyMigration.mcpRegistration
# The pre-existing installation state is read here, before the read-only preflight can
# return, because the preflight must resolve the same private Python runtime the real
# install would. Reading it is pure I/O: nothing is created, written, moved or deleted,
# and no process is stopped.
$currentState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $currentState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { }
}
$legacyState = $null
if (Test-Path -LiteralPath $legacyInstallState -PathType Leaf) {
    try { $legacyState = Get-Content -LiteralPath $legacyInstallState -Raw | ConvertFrom-Json } catch { }
}

# -ValidateOnly is strictly read-only, so it must not discover the Codex CLI (which
# throws when the CLI is unavailable) nor read the MCP registration at all.
if (-not $ValidateOnly) {
    $codexCli = Find-CodexCli
}
$previousNewMcp = $null
$previousLegacyMcp = $null
if (-not $ValidateOnly) {
    # Recorded only so a failed install can restore what this machine had; the
    # preflight must not read or touch the Codex MCP registration at all.
    $previousNewMcp = Get-CodexMcp $codexCli $newMcpName
    $previousLegacyMcp = Get-CodexMcp $codexCli $legacyMcpName
}

$running = @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)
if ($running) {
    $details = @($running | ForEach-Object { "$($_.ProcessName) PID $($_.Id) [$($_.MainWindowTitle)]" }) -join '; '
    throw "Close every Revit and AutoCAD session before $Action. Running: $details"
}

if ($Action -eq 'Uninstall') {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        [ordered]@{ status='not_installed'; action='Uninstall'; changed=$false } | ConvertTo-Json
        return
    }
    if (-not $PSCmdlet.ShouldProcess('BIM Bridge current-user installation', 'Uninstall')) { return }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $uninstallRollbackRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-uninstall-' + [Guid]::NewGuid().ToString('N'))
    $uninstallRecords = New-Object System.Collections.ArrayList
    New-Item -ItemType Directory -Force -Path $uninstallRollbackRoot | Out-Null
    try {
        Remove-CodexMcp $codexCli $newMcpName
        Stop-OwnedHostProcesses @($stateRoot)
        $uninstallTargets = @(@($state.ownedPaths) + @($statePath) | Select-Object -Unique)
        foreach ($target in $uninstallTargets) {
            if ($target) { Backup-Path ([string]$target) $uninstallRollbackRoot $uninstallRecords }
        }
    } catch {
        $failure = $_.Exception.Message
        Restore-Backups $uninstallRecords
        try { Restore-CodexMcp $codexCli $newMcpName $previousNewMcp } catch { }
        if (Test-Path -LiteralPath $uninstallRollbackRoot) {
            Remove-DirectoryTree $uninstallRollbackRoot -BestEffort
        }
        throw "BIM Bridge uninstall failed and was rolled back: $failure"
    }
    Remove-DirectoryTree $uninstallRollbackRoot -BestEffort
    [ordered]@{ status='succeeded'; action='Uninstall'; changed=$true } | ConvertTo-Json
    return
}

. $matrixHelperPath
. $productDiscoveryPath
$skippedProducts = New-Object System.Collections.ArrayList
function Add-SkippedProduct([string]$Product, [string]$Version, [string]$Reason) {
    [void]$skippedProducts.Add([ordered]@{ product=$Product; version=$Version; reason=$Reason })
}
$revitEntries = @(Get-RevitMatrixEntries $matrixPath | Where-Object { $_.CertificationStatus -eq 'certified' })
$resolvedRevit = New-Object System.Collections.ArrayList
$registryInstallRecords = if ($PSBoundParameters.ContainsKey('RegistryInstallRecords')) { @($RegistryInstallRecords) } else { @(Get-AutodeskRegistryInstallRecords) }
$programFilesRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
foreach ($entry in $revitEntries) {
    $installation = Resolve-AutodeskProductInstallation -Product revit -Version ([string]$entry.Include) `
        -InstallSubdirectory ([string]$entry.InstallSubdirectory) -ProgramFilesRoots $programFilesRoots `
        -ProductInstallPathOverrides $ProductInstallPathOverrides -RegistryInstallRecords $registryInstallRecords
    if (-not $installation) { continue }
    try {
        $resolved = Resolve-RevitMatrixEntry $entry -InstallDirectory $installation.InstallDirectory -RequireCertified
        $resolved | Add-Member -NotePropertyName DetectionSource -NotePropertyValue ([string]$installation.Source)
        [void]$resolvedRevit.Add($resolved)
    } catch {
        Add-SkippedProduct 'revit' ([string]$entry.Include) $_.Exception.Message
    }
}
$autoCADEntries = @(Get-AutoCADMatrixEntries $matrixPath | Where-Object { $_.CertificationStatus -eq 'certified' })
$resolvedAutoCAD = New-Object System.Collections.ArrayList
foreach ($entry in $autoCADEntries) {
    $installation = Resolve-AutodeskProductInstallation -Product autocad -Version ([string]$entry.Include) `
        -InstallSubdirectory ([string]$entry.InstallSubdirectory) -ProgramFilesRoots $programFilesRoots `
        -ProductInstallPathOverrides $ProductInstallPathOverrides -RegistryInstallRecords $registryInstallRecords
    if (-not $installation) { continue }
    try {
        $resolved = Resolve-AutoCADMatrixEntry $entry -InstallDirectory $installation.InstallDirectory -RequireCertified
        $resolved | Add-Member -NotePropertyName DetectionSource -NotePropertyValue ([string]$installation.Source)
        [void]$resolvedAutoCAD.Add($resolved)
    } catch {
        Add-SkippedProduct 'autocad' ([string]$entry.Include) $_.Exception.Message
    }
}
$knownRevitManifestPaths = @($revitEntries | ForEach-Object {
    Join-Path $roaming ("Autodesk\Revit\Addins\$($_.Include)\BIM.Bridge.addin")
})

if (-not $SkipBuild) {
    if ($resolvedRevit.Count -gt 0) {
        & (Join-Path $SourceRoot 'eng\Build-RevitAdapters.ps1') -Version @($resolvedRevit | ForEach-Object { $_.Include }) -Configuration $Configuration
        if ($LASTEXITCODE -ne 0) { throw 'One or more Revit adapter builds failed.' }
    }
    if ($resolvedAutoCAD.Count -gt 0) {
        & (Join-Path $SourceRoot 'eng\Build-AutoCADAdapters.ps1') -Version @($resolvedAutoCAD | ForEach-Object { $_.Include }) -Configuration $Configuration
        if ($LASTEXITCODE -ne 0) { throw 'One or more AutoCAD adapter builds failed.' }
    }
}

if ($ValidateOnly) {
    # Same trusted resolver the real install uses, so the preflight cannot disagree with it.
    $resolvedPython = Resolve-PrivatePythonSource $SourceRoot $currentState $legacyState $effectiveStateRoot $effectiveLegacyStateRoot
    if (-not $resolvedPython.Available) {
        $probed = @($resolvedPython.Probed) -join '; '
        $refusedDetail = ''
        if ($resolvedPython.PSObject.Properties['Refused'] -and @($resolvedPython.Refused).Count -gt 0) {
            $refusedDetail = ' Refused because a recorded path is not contained in its own state root: ' + (@($resolvedPython.Refused) -join '; ') + '.'
        }
        throw "The release package has no private Python runtime, and no recorded installation supplies one.$refusedDetail Probed, in priority order: $probed"
    }
    foreach ($revit in $resolvedRevit) {
        $source = Join-Path $SourceRoot ("src\BimBridge.Revit\bin\$Configuration\$($revit.Include)\$($revit.TargetFramework)")
        foreach ($required in @("$($revit.AssemblyName).dll",[string]$revit.ManifestName)) {
            if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) { throw "Revit $($revit.Include) release artifact is missing: $required" }
        }
    }
    foreach ($autoCAD in $resolvedAutoCAD) {
        $source = Join-Path $SourceRoot ("src\BimBridge.AutoCAD\bin\$Configuration\$($autoCAD.Include)\$($autoCAD.TargetFramework)")
        if (-not (Test-Path -LiteralPath (Join-Path $source "$($autoCAD.AssemblyName).dll") -PathType Leaf)) {
            throw "AutoCAD $($autoCAD.Include) release artifact is missing."
        }
    }
    [ordered]@{
        status='validated'; version=$basePluginVersion
        revit=@($resolvedRevit | ForEach-Object { [string]$_.Include })
        autocad=@($resolvedAutoCAD | ForEach-Object { [string]$_.Include })
        skippedProducts=@($skippedProducts)
        # The pre-existing state this preflight is about to be judged against. Without
        # it a reader cannot tell whether the settings came from the repository or from
        # an already-installed Host.
        existingInstallState=[ordered]@{
            currentPresent = ($null -ne $currentState)
            currentVersion = if ($currentState) { [string]$currentState.version } else { $null }
            legacyPresent  = ($null -ne $legacyState)
            legacyVersion  = if ($legacyState) { [string]$legacyState.version } else { $null }
        }
        privatePythonSource=[string]$resolvedPython.Directory
        privatePythonExecutable=[string]$resolvedPython.Executable
        sourceKind=[string]$resolvedPython.SourceKind
        # Retained under its original name so existing consumers keep working.
        privatePython=[string]$resolvedPython.Executable
        readOnly=$true
    } | ConvertTo-Json -Depth 6
    return
}

New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$stagingRoot = Join-Path $stateRoot ('staging-' + [Guid]::NewGuid().ToString('N'))
$rollbackRoot = Join-Path $stateRoot ('rollback-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stagingRoot,$rollbackRoot | Out-Null
$backupRecords = New-Object System.Collections.ArrayList
# $currentState / $legacyState were already read above, before the read-only
# preflight could return, so the preflight and this install path share one resolution.

try {
    $stagedHost = Join-Path $stagingRoot 'host'
    New-Item -ItemType Directory -Force -Path $stagedHost | Out-Null
    Copy-Directory (Join-Path $SourceRoot 'plugins\aec-codex\mcp-server') (Join-Path $stagedHost 'mcp-server')
    Copy-Directory (Join-Path $SourceRoot 'runtime\aec_runtime') (Join-Path $stagedHost 'mcp-server\runtime\aec_runtime')
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'installer\Start-BimBridgeMcp.ps1') -Destination (Join-Path $stagedHost 'Start-BimBridgeMcp.ps1')

    $pythonSource = $null
    $resolvedPython = Resolve-PrivatePythonSource $SourceRoot $currentState $legacyState $effectiveStateRoot $effectiveLegacyStateRoot
    if (-not $resolvedPython.Available) {
        $probed = @($resolvedPython.Probed) -join '; '
        $refusedDetail = ''
        if ($resolvedPython.PSObject.Properties['Refused'] -and @($resolvedPython.Refused).Count -gt 0) {
            $refusedDetail = ' Refused because a recorded path is not contained in its own state root: ' + (@($resolvedPython.Refused) -join '; ') + '.'
        }
        throw "A packaged private Python runtime is required, and no recorded installation supplies one. Repair the legacy host or build a complete BIM Bridge release first.$refusedDetail Probed, in priority order: $probed"
    }
    $pythonSource = [string]$resolvedPython.Directory
    Copy-Directory $pythonSource (Join-Path $stagedHost 'python')

    $stagedConnectors = Join-Path $stagingRoot 'connectors'
    $stagedManifests = Join-Path $stagingRoot 'manifests'
    New-Item -ItemType Directory -Force -Path $stagedConnectors,$stagedManifests | Out-Null
    $manifestTargets = New-Object System.Collections.ArrayList
    foreach ($revit in $resolvedRevit) {
        $source = Join-Path $SourceRoot ("src\BimBridge.Revit\bin\$Configuration\$($revit.Include)\$($revit.TargetFramework)")
        $assemblyName = "$($revit.AssemblyName).dll"
        if (-not (Test-Path -LiteralPath (Join-Path $source $assemblyName) -PathType Leaf)) { throw "Revit adapter output is missing: $source" }
        $stagedVersion = Join-Path $stagedConnectors ("revit\$($revit.Include)\$($revit.TargetFramework)")
        Copy-Directory $source $stagedVersion
        $finalAssembly = Join-Path $connectorRoot ("revit\$($revit.Include)\$($revit.TargetFramework)\$assemblyName")
        $manifestSource = Join-Path $source $revit.ManifestName
        $manifestContent = Get-Content -LiteralPath $manifestSource -Raw
        $manifestContent = $manifestContent -replace '<Assembly>.*?</Assembly>', ('<Assembly>' + [Security.SecurityElement]::Escape($finalAssembly) + '</Assembly>')
        $stagedManifest = Join-Path $stagedManifests ("BIM.Bridge.$($revit.Include).addin")
        Write-Utf8NoBom $stagedManifest $manifestContent
        $finalManifest = Join-Path $roaming ("Autodesk\Revit\Addins\$($revit.Include)\BIM.Bridge.addin")
        [void]$manifestTargets.Add([pscustomobject]@{ Staged=$stagedManifest; Final=$finalManifest })
    }

    $stagedAutoCADBundle = $null
    if ($resolvedAutoCAD.Count -gt 0) {
        $stagedAutoCADBundle = Join-Path $stagingRoot 'BIM Bridge.bundle'
        foreach ($autoCAD in $resolvedAutoCAD) {
            $source = Join-Path $SourceRoot ("src\BimBridge.AutoCAD\bin\$Configuration\$($autoCAD.Include)\$($autoCAD.TargetFramework)")
            $assemblyPath = Join-Path $source "$($autoCAD.AssemblyName).dll"
            if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) { throw "AutoCAD adapter output is missing: $assemblyPath" }
            $stagedVersion = Join-Path $stagedAutoCADBundle ("Contents\Windows\$($autoCAD.Include)")
            New-Item -ItemType Directory -Force -Path $stagedVersion | Out-Null
            Copy-Item -Path (Join-Path $source '*') -Destination $stagedVersion -Recurse -Force
        }
        $packageTemplate = Join-Path $SourceRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml'
        $package = New-AutoCADPackageContents $resolvedAutoCAD '2.0.0' $packageTemplate
        Write-Utf8NoBom (Join-Path $stagedAutoCADBundle 'PackageContents.xml') $package
    }

    if (-not $PSCmdlet.ShouldProcess('BIM Bridge current-user installation', $Action)) {
        Remove-DirectoryTree $stagingRoot -BestEffort
        Remove-DirectoryTree $rollbackRoot -BestEffort
        return
    }

    Remove-CodexMcp $codexCli $newMcpName
    Stop-OwnedHostProcesses @($stateRoot)
    if ($MigrateLegacy) {
        Remove-CodexMcp $codexCli $legacyMcpName
        Stop-OwnedHostProcesses @($legacyStateRoot,$legacyRoamingRoot)
    }

    foreach ($target in @($hostRoot,$connectorRoot,$autoCADBundle,$statePath)) { Backup-Path $target $rollbackRoot $backupRecords }
    foreach ($manifestPath in $knownRevitManifestPaths) { Backup-Path $manifestPath $rollbackRoot $backupRecords }
    if ($MigrateLegacy) {
        foreach ($target in @($legacyHostRoot,$legacyMaintenanceRoot,$legacyInstallState,$legacyProviderRoot,$legacyRoamingProviders,$legacyAutoCADBundle,$legacyRevitDirectory,$legacyRevitManifest,$legacyProviderDirectory,$legacyProviderManifest)) {
            Backup-Path $target $rollbackRoot $backupRecords
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hostRoot),(Split-Path -Parent $connectorRoot) | Out-Null
    Move-Item -LiteralPath $stagedHost -Destination $hostRoot
    Move-Item -LiteralPath $stagedConnectors -Destination $connectorRoot
    foreach ($manifestTarget in $manifestTargets) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestTarget.Final) | Out-Null
        Move-Item -LiteralPath $manifestTarget.Staged -Destination $manifestTarget.Final
    }
    if ($stagedAutoCADBundle) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $autoCADBundle) | Out-Null
        Move-Item -LiteralPath $stagedAutoCADBundle -Destination $autoCADBundle
    }

    $launcher = Join-Path $hostRoot 'Start-BimBridgeMcp.ps1'
    $server = Join-Path $hostRoot 'mcp-server\aec_mcp_server.py'
    $python = Join-Path $hostRoot 'python\python.exe'
    $ownedPaths = @($hostRoot,$connectorRoot,$autoCADBundle) + @($manifestTargets | ForEach-Object { $_.Final })
    $integrityRoots = @(
        $launcher,
        $server,
        $python,
        (Join-Path $hostRoot 'python\python312.dll'),
        (Join-Path $hostRoot 'python\python312.zip'),
        (Join-Path $hostRoot 'python\python312._pth'),
        (Join-Path $hostRoot 'python\vcruntime140.dll'),
        (Join-Path $hostRoot 'python\vcruntime140_1.dll'),
        (Join-Path $hostRoot 'python\libcrypto-3.dll'),
        (Join-Path $hostRoot 'python\libssl-3.dll'),
        (Join-Path $hostRoot 'mcp-server'),
        $connectorRoot,
        $autoCADBundle
    ) + @($manifestTargets | ForEach-Object { $_.Final })
    $fileRecords = New-FileRecords $integrityRoots
    $migratedLegacy = [bool]$MigrateLegacy
    if ($currentState -and $currentState.PSObject.Properties['migratedLegacy'] -and [bool]$currentState.migratedLegacy) {
        $migratedLegacy = $true
    }
    $state = [ordered]@{
        schemaVersion=4; version=$basePluginVersion; installedAtUtc=[DateTime]::UtcNow.ToString('o')
        installMode='CodexBootstrap'; restartRequired=$true; mcpName=[string]$releaseManifest.mcpRegistration
        localMcpServer=$server; python=$python; launcher=$launcher
        products=[ordered]@{
            revit=@($resolvedRevit | ForEach-Object { [ordered]@{ version=$_.Include; targetFramework=$_.TargetFramework; runtimeFamily=$_.RuntimeFamily; installPath=$_.InstallDirectory; detectionSource=$_.DetectionSource } })
            autocad=@($resolvedAutoCAD | ForEach-Object { [ordered]@{ version=$_.Include; targetFramework=$_.TargetFramework; runtimeFamily=$_.RuntimeFamily; installPath=$_.InstallDirectory; detectionSource=$_.DetectionSource } })
        }
        skippedProducts=@($skippedProducts)
        structuredProvidersInstalled=$false; ownedPaths=$ownedPaths; files=$fileRecords
        integrityScope='critical-runtime-and-adapter-files'
        migratedLegacy=$migratedLegacy
    }
    Write-JsonAtomic $statePath $state
    Register-CodexMcp $codexCli $newMcpName $launcher

    Remove-DirectoryTree $rollbackRoot -BestEffort
    if (Test-Path -LiteralPath $stagingRoot) { Remove-DirectoryTree $stagingRoot -BestEffort }
    Remove-StaleTransactionDirectories $stateRoot @()
    [ordered]@{
        status='succeeded'; action=$Action; changed=$true; version=$basePluginVersion; restartRequired=$true
        products=$state.products; skippedProducts=@($skippedProducts); providersInstalled=$false; migratedLegacy=$migratedLegacy
    } | ConvertTo-Json -Depth 8
} catch {
    $failure = $_.Exception.Message
    Restore-Backups $backupRecords
    try { Restore-CodexMcp $codexCli $newMcpName $previousNewMcp } catch { }
    if ($MigrateLegacy) { try { Restore-CodexMcp $codexCli $legacyMcpName $previousLegacyMcp } catch { } }
    if (Test-Path -LiteralPath $stagingRoot) { Remove-DirectoryTree $stagingRoot -BestEffort }
    if (Test-Path -LiteralPath $rollbackRoot) { Remove-DirectoryTree $rollbackRoot -BestEffort }
    throw "BIM Bridge installation failed and was rolled back: $failure"
}
