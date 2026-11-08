[CmdletBinding()]
param()

# Regression for the read-only preflight's private-Python resolution.
#
# The real-machine gate found a genuine blocker: `-ValidateOnly` accepted only
# `<SourceRoot>\runtime\python`, while the real Install/Repair path additionally fell
# back to the Python recorded in the current install-state and then to the legacy
# state. On a machine whose repository `runtime\python` tree is absent but whose
# installed Host carries its own Python, the preflight therefore failed with
# "The release package has no private Python runtime." although the install would have
# succeeded. Both paths now share `Resolve-PrivatePythonSource`.
#
# This test injects *controlled* state files through the installer's
# `-StatePathOverride` / `-LegacyStatePathOverride` seams, so it never reads, writes
# or depends on the real per-user installation, and it never installs anything:
# `-ValidateOnly` is contractually read-only.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installerPath = Join-Path $repositoryRoot 'installer\Install-BimBridge.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-preflight-python-' + [Guid]::NewGuid().ToString('N'))

$script:Passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}

function New-PythonFixture([string]$Directory) {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $executable = Join-Path $Directory 'python.exe'
    # A plain marker file is enough: the resolver only requires python.exe to exist as
    # a leaf. Nothing in this test ever executes it.
    Set-Content -LiteralPath $executable -Value 'python fixture' -Encoding ASCII
    $executable
}

function Get-TreeSnapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # Path, length, mtime *and* content hash: a path-and-length-only snapshot cannot
    # tell an in-place rewrite from an untouched file.
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $item = Get-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            if (-not $item) { return }
            $length = if ($item.PSObject.Properties['Length'] -and -not $item.PSIsContainer) { [long]$item.Length } else { 'dir' }
            $hash = if (-not $item.PSIsContainer) { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } else { 'dir' }
            "$($item.FullName)|$length|$($item.LastWriteTimeUtc.ToString('o'))|$hash"
        } | Sort-Object)
}

function Get-FileFingerprint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Hash   = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Mtime  = $item.LastWriteTimeUtc.ToString('o')
        Length = [long]$item.Length
    }
}

function Invoke-Preflight([string]$StatePath, [string]$LegacyStatePath) {
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath,
        '-Action', 'Install', '-Configuration', 'Release', '-SkipBuild', '-ValidateOnly',
        '-SourceRoot', $repositoryRoot,
        '-StatePathOverride', $StatePath,
        '-LegacyStatePathOverride', $LegacyStatePath
    )
    # Windows PowerShell promotes a native command's stderr to a terminating error
    # under $ErrorActionPreference = 'Stop'. The installer reports its refusal on
    # stderr, so the preference is relaxed for the duration of the call and the text
    # is captured rather than thrown. This changes nothing about the installer.
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe @arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    [pscustomobject]@{ ExitCode = $code; Text = (@($output) -join [Environment]::NewLine) }
}

try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

    # The repository tree used by this audit has no runtime\python, which is exactly
    # the condition that exposed the blocker. Assert it rather than assume it, so the
    # test fails loudly if the fixture premise ever stops holding.
    $repoRuntime = Join-Path $repositoryRoot 'runtime\python\python.exe'
    Assert-True (-not (Test-Path -LiteralPath $repoRuntime -PathType Leaf)) "The repository unexpectedly provides runtime\python\python.exe, so this regression no longer exercises the fallback: $repoRuntime"

    # Two distinguishable controlled runtimes, so the priority order is observable.
    # The path shapes match the production ones:
    #   current  <stateRoot>\host\<version>\python\python.exe
    #   legacy   <legacyStateRoot>\host\<version>\runtime\python\python.exe
    $currentPython = New-PythonFixture (Join-Path $temporaryRoot 'current-state\host\2.0.0-alpha.1\python')
    $legacyPython = New-PythonFixture (Join-Path $temporaryRoot 'legacy-state\host\1.9.0\runtime\python')
    $currentHashBefore = (Get-FileHash -LiteralPath $currentPython -Algorithm SHA256).Hash
    $legacyHashBefore = (Get-FileHash -LiteralPath $legacyPython -Algorithm SHA256).Hash

    $currentStatePath = Join-Path $temporaryRoot 'current-state\install-state.json'
    [IO.File]::WriteAllText($currentStatePath, (([ordered]@{
                    schemaVersion = 4
                    version       = '2.0.0-alpha.1'
                    python        = $currentPython
                } | ConvertTo-Json -Depth 4)), [Text.UTF8Encoding]::new($false))
    $legacyStatePath = Join-Path $temporaryRoot 'legacy-state\install-state.json'
    [IO.File]::WriteAllText($legacyStatePath, (([ordered]@{
                    # Schema 3 is the legacy Install-AecCodex schema; the resolver must
                    # still accept it while the current schema stays limited to 4.
                    schemaVersion = 3
                    version       = '1.9.0'
                    privatePython = $legacyPython
                } | ConvertTo-Json -Depth 4)), [Text.UTF8Encoding]::new($false))

    # Frozen before either preflight runs, and compared after both.
    $currentStateFingerprintBefore = Get-FileFingerprint $currentStatePath
    $legacyStateFingerprintBefore = Get-FileFingerprint $legacyStatePath

    $realStatePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BIM Bridge\install-state.json'
    $realStateFingerprintBefore = Get-FileFingerprint $realStatePath
    $realStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BIM Bridge'
    $realStateDirectoryBefore = @()
    if (Test-Path -LiteralPath $realStateRoot) {
        $realStateDirectoryBefore = Get-TreeSnapshot $realStateRoot
    }

    # Every fixture exists once the guard cases are built, so this snapshot changes
    # only if one of the preflights below mutates the controlled tree.
    $missingDir = Join-Path $temporaryRoot 'no-state'
    New-Item -ItemType Directory -Force -Path $missingDir | Out-Null
    $absentState = Join-Path $missingDir 'install-state.json'
    $absentLegacy = Join-Path $missingDir 'legacy-install-state.json'

    # All remaining fixtures are declared and created here - before any run and before
    # the mutation snapshot - so the snapshot below is a true baseline: any difference
    # afterwards is caused by a preflight, not by this test's own setup.
    $outsideGuid = ([guid]::NewGuid()).ToString('N')
    $outsideRoot = Join-Path ([IO.Path]::GetTempPath()) ("bim-bridge-preflight-outside-$outsideGuid")
    $outsideHost = Join-Path $outsideRoot 'host\2.0.0-alpha.1\python'
    $outsidePython = New-PythonFixture $outsideHost
    $outsideWitness = Join-Path $outsideRoot 'outside-witness.txt'
    Set-Content -LiteralPath $outsideWitness -Value 'outside witness must survive' -Encoding ASCII
    $outsideWitnessHash = (Get-FileHash -LiteralPath $outsideWitness -Algorithm SHA256).Hash
    $outsidePythonHashBefore = (Get-FileHash -LiteralPath $outsidePython -Algorithm SHA256).Hash
    $outsideStateRoot = Join-Path $temporaryRoot 'untrusted-state'
    New-Item -ItemType Directory -Force -Path $outsideStateRoot | Out-Null
    $outsideStatePath = Join-Path $outsideStateRoot 'install-state.json'
    [IO.File]::WriteAllText($outsideStatePath, (([ordered]@{
                    schemaVersion = 4
                    version       = '2.0.0-alpha.1'
                    # Points above its own state root: the containment check must refuse it.
                    python        = $outsidePython
                } | ConvertTo-Json -Depth 4)), [Text.UTF8Encoding]::new($false))
    $guardCases = @(
        @{ Argument = @('-Action', 'Uninstall', '-ValidateOnly', '-StatePathOverride', $absentState); Label = 'Uninstall + ValidateOnly' },
        @{ Argument = @('-Action', 'Uninstall', '-StatePathOverride', $absentState); Label = 'Uninstall + override' },
        @{ Argument = @('-Action', 'Install', '-StatePathOverride', $absentState); Label = 'Install + override without ValidateOnly' }
    )

    # Baseline: every fixture exists and no run has happened yet.
    $stateSnapshotBefore = Get-TreeSnapshot $temporaryRoot

    # ---------------------------------------------------------------------------
    # 1. repository runtime absent, controlled current-state Python present -> exit 0
    # ---------------------------------------------------------------------------
    $successRun = Invoke-Preflight $currentStatePath $legacyStatePath
    Assert-True ($successRun.ExitCode -eq 0) "The preflight still fails when a recorded installation supplies the private Python runtime (exit $($successRun.ExitCode)): $($successRun.Text)"
    $result = $null
    try { $result = $successRun.Text | ConvertFrom-Json } catch { throw "The preflight did not emit parseable JSON: $($successRun.Text)" }
    Assert-True ([string]$result.status -eq 'validated') 'The preflight did not report the validated status.'
    Assert-True ([string]$result.sourceKind -eq 'current-install-state') "The preflight resolved the private Python from '$($result.sourceKind)' instead of the current install-state."
    Assert-True ([IO.Path]::GetFullPath([string]$result.privatePythonSource) -eq [IO.Path]::GetFullPath((Split-Path -Parent $currentPython))) 'The preflight reported a private Python directory that is not the current-state runtime.'
    Assert-True ([IO.Path]::GetFullPath([string]$result.privatePythonExecutable) -eq [IO.Path]::GetFullPath($currentPython)) 'The preflight reported a private Python executable that is not the current-state runtime.'
    Assert-True ([IO.Path]::GetFullPath([string]$result.privatePython) -eq [IO.Path]::GetFullPath($currentPython)) 'The legacy privatePython field is not the resolved executable.'
    Assert-True ($result.existingInstallState.currentPresent -eq $true) 'The preflight did not report the current install-state it resolved against.'
    Assert-True ([string]$result.existingInstallState.currentVersion -eq '2.0.0-alpha.1') 'The preflight reported the wrong current install-state version.'
    Assert-True ($result.existingInstallState.legacyPresent -eq $true) 'The preflight did not report the legacy install-state it was given.'
    Assert-True ($result.readOnly -eq $true) 'The preflight does not declare itself read-only.'
    # Only the presence of the product-matrix fields is asserted here. The exact
    # seven-version matrix depends on what is installed on the host, so asserting it
    # would make this regression a machine-specific test; the precise matrix is proven
    # by the real `-ValidateOnly` evidence recorded in the readiness report.
    Assert-True ($null -ne $result.PSObject.Properties['revit']) 'The preflight JSON has no revit product field.'
    Assert-True ($null -ne $result.PSObject.Properties['autocad']) 'The preflight JSON has no autocad product field.'
    Assert-True ($null -ne $result.PSObject.Properties['skippedProducts']) 'The preflight JSON has no skippedProducts field.'
    Assert-True ([string]$result.version -match '^\d+\.\d+\.\d+') "The preflight reported a version that is not a release version: $($result.version)"

    # ---------------------------------------------------------------------------
    # 2. no source at all -> non-zero, and every probed location is named
    # ---------------------------------------------------------------------------
    $failureRun = Invoke-Preflight $absentState $absentLegacy
    Assert-True ($failureRun.ExitCode -ne 0) 'The preflight succeeded even though no private Python runtime exists anywhere.'
    Assert-True ($failureRun.Text -match 'no private Python runtime') "The failure does not name the missing private Python runtime: $($failureRun.Text)"
    Assert-True ($failureRun.Text -match 'Probed, in priority order') "The failure does not enumerate the probed locations: $($failureRun.Text)"

    # ---------------------------------------------------------------------------
    # 2b. a state file that points at a Python *outside* its own state root is not
    # trusted. The witness outside the root must survive, and the run must fail.
    # Fixture created above, before the baseline snapshot.
    # ---------------------------------------------------------------------------
    $outsideRun = Invoke-Preflight $outsideStatePath $absentLegacy
    Assert-True ($outsideRun.ExitCode -ne 0) 'The preflight trusted a state file that points at a Python outside its own state root.'
    Assert-True ($outsideRun.Text -match 'not contained in') "The untrusted path was not refused for containment: $($outsideRun.Text)"
    Assert-True (Test-Path -LiteralPath $outsideWitness) 'The untrusted-path refusal deleted the external witness.'
    Assert-True ((Get-FileHash -LiteralPath $outsideWitness -Algorithm SHA256).Hash -eq $outsideWitnessHash) 'The untrusted-path refusal changed the external witness content.'
    Assert-True ((Get-FileHash -LiteralPath $outsidePython -Algorithm SHA256).Hash -eq $outsidePythonHashBefore) 'The untrusted-path refusal changed the external fixture executable.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $outsideStateRoot 'host'))) 'The untrusted-path refusal created a host tree under the state root.'

    # ---------------------------------------------------------------------------
    # 2c. the read-only preflight contract: -ValidateOnly cannot mean Uninstall, and
    # the test-seam overrides cannot be used outside a permitted read-only preflight.
    # Both must fail before any read or write; each case uses a non-existent state
    # override so no real uninstall or install can be reached even if the guard were
    # missing (the command still must not touch the real installation).
    # ---------------------------------------------------------------------------
    foreach ($guardCase in $guardCases) {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath, '-Configuration', 'Release', '-SkipBuild') + @($guardCase.Argument)
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $guardOutput = & powershell.exe @arguments 2>&1
            $guardCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $guardText = (@($guardOutput) -join [Environment]::NewLine)
        Assert-True ($guardCode -ne 0) "The installer accepted the forbidden combination $($guardCase.Label) (exit $guardCode)."
        Assert-True ($guardText -match 'read-only preflight') "The refusal for $($guardCase.Label) is not the preflight-contract refusal: $guardText"
    }

    # ---------------------------------------------------------------------------
    # 3. the preflight mutated nothing
    # ---------------------------------------------------------------------------
    Assert-True ((Get-FileHash -LiteralPath $currentPython -Algorithm SHA256).Hash -eq $currentHashBefore) 'The preflight modified the controlled current-state Python fixture.'
    Assert-True ((Get-FileHash -LiteralPath $legacyPython -Algorithm SHA256).Hash -eq $legacyHashBefore) 'The preflight modified the controlled legacy-state Python fixture.'
    # Frozen before either run, compared after both: hash, length and mtime of the two
    # controlled state files.
    $currentStateFingerprintAfter = Get-FileFingerprint $currentStatePath
    $legacyStateFingerprintAfter = Get-FileFingerprint $legacyStatePath
    Assert-True ($currentStateFingerprintAfter.Hash -eq $currentStateFingerprintBefore.Hash) 'The controlled current state file content changed.'
    Assert-True ($currentStateFingerprintAfter.Mtime -eq $currentStateFingerprintBefore.Mtime) 'The controlled current state file mtime changed.'
    Assert-True ($currentStateFingerprintAfter.Length -eq $currentStateFingerprintBefore.Length) 'The controlled current state file length changed.'
    Assert-True ($legacyStateFingerprintAfter.Hash -eq $legacyStateFingerprintBefore.Hash) 'The controlled legacy state file content changed.'
    Assert-True ($legacyStateFingerprintAfter.Mtime -eq $legacyStateFingerprintBefore.Mtime) 'The controlled legacy state file mtime changed.'
    Assert-True ($legacyStateFingerprintAfter.Length -eq $legacyStateFingerprintBefore.Length) 'The controlled legacy state file length changed.'
    $stateSnapshotAfter = Get-TreeSnapshot $temporaryRoot
    Assert-True (($stateSnapshotBefore -join '|') -eq ($stateSnapshotAfter -join '|')) 'The preflight changed the controlled state tree (path, length, mtime or content).'

    if ($realStateFingerprintBefore) {
        $realStateFingerprintAfter = Get-FileFingerprint $realStatePath
        Assert-True ($realStateFingerprintAfter.Hash -eq $realStateFingerprintBefore.Hash) 'The preflight changed the real install-state hash.'
        Assert-True ($realStateFingerprintAfter.Mtime -eq $realStateFingerprintBefore.Mtime) 'The preflight changed the real install-state mtime.'
        Assert-True ($realStateFingerprintAfter.Length -eq $realStateFingerprintBefore.Length) 'The preflight changed the real install-state length.'
    }
    if ($realStateDirectoryBefore.Count -gt 0) {
        $realStateDirectoryAfter = Get-TreeSnapshot $realStateRoot
        Assert-True (($realStateDirectoryAfter -join '|') -eq ($realStateDirectoryBefore -join '|')) 'The preflight changed the real BIM Bridge state directory tree.'
    }
    Assert-True (@(Get-Process -Name Revit, acad -ErrorAction SilentlyContinue).Count -eq 0) 'A Revit or AutoCAD process is running; this test must not be run with Autodesk products open.'

    $hostDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BIM Bridge'
    $stagingLeftovers = @(Get-ChildItem -LiteralPath $hostDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'staging-*' -or $_.Name -like 'rollback-*' })
    Assert-True (@($stagingLeftovers).Count -eq 0) "The read-only preflight left transaction directories behind: $(@($stagingLeftovers | ForEach-Object { $_.Name }) -join ', ')"

    [ordered]@{
        status                = 'passed'
        checks                = $script:Passed
        fallbackSourceKind    = [string]$result.sourceKind
        fallbackPython        = [string]$result.privatePythonExecutable
        missingSourceExitCode = $failureRun.ExitCode
        untrustedSourceExitCode = $outsideRun.ExitCode
        forbiddenCombinations = @($guardCases | ForEach-Object { $_.Label })
    } | ConvertTo-Json -Depth 6
} finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    # The untrusted-source fixture deliberately lives *outside* the controlled state
    # root, so it needs its own cleanup. It is identified by its exact GUID-qualified
    # leaf name and re-checked against the temp prefix before removal.
    if ($outsideRoot -and (Test-Path -LiteralPath $outsideRoot)) {
        $resolvedOutside = [IO.Path]::GetFullPath($outsideRoot)
        if ($resolvedOutside.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedOutside) -ceq "bim-bridge-preflight-outside-$outsideGuid") {
            Remove-Item -LiteralPath $resolvedOutside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith('bim-bridge-preflight-python-', [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
