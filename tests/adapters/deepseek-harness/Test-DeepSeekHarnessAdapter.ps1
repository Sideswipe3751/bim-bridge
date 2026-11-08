[CmdletBinding()]
param(
    [string]$SourceRoot,
    # Explicit, caller-supplied ownership baseline. See the shared-layer
    # footprint section below: without it no ownership gate runs at all, because
    # this suite shares one working tree with other members and a whole-tree scan
    # cannot tell their legitimate work from this adapter's footprint.
    [string]$OwnershipBaselinePath
)

# DeepSeek Harness adapter test suite.
#
# Every check runs against an isolated temporary state root and a fake Host. The
# real BIM Bridge installation is never written to: its install-state hash, the
# shared protocol baseline hash, and a hash snapshot of the shared layers this
# adapter must never touch are captured before and after to prove it.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDirectory))
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

$adapterRoot = Join-Path $SourceRoot 'adapters\deepseek-harness'
$skillRoot = Join-Path $adapterRoot 'skills\bim-bridge'
$statusScript = Join-Path $skillRoot 'scripts\Get-BimBridgeDshStatus.ps1'
$configScript = Join-Path $skillRoot 'scripts\Get-BimBridgeDshMcpConfig.ps1'
$launcherScript = Join-Path $skillRoot 'scripts\Start-BimBridgeDshMcp.ps1'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$templatePath = Join-Path $adapterRoot 'mcp.template.json'
$readmePath = Join-Path $adapterRoot 'README.md'
$docPath = Join-Path $SourceRoot 'docs\deepseek-harness-adapter.md'
$setupRefPath = Join-Path $skillRoot 'references\setup.md'
$acceptanceRefPath = Join-Path $skillRoot 'references\acceptance.md'

# Resolved once by absolute path: the PATH-less checks below empty this process's
# PATH on purpose, and a bare `powershell.exe` would then no longer resolve. The
# Windows directory is used rather than $PSHOME, which need not be the same
# PowerShell that cmd.exe would launch.
$windowsPowerShell = Join-Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0') 'powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw "Missing Windows PowerShell: $windowsPowerShell" }

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

function Invoke-LauncherRaw([string]$StateRoot, [string]$StdOutPath, [string]$StdErrPath) {
    # Windows PowerShell 5.1 promotes a redirected native stderr write to a
    # NativeCommandError while the surrounding scope uses Stop. The child exit
    # code and the captured streams are the assertions, not the host error record.
    #
    # Both capture files are removed first: `... | Set-Content` writes nothing when
    # the child produces no stdout, so a leftover file from an earlier invocation
    # would otherwise be mistaken for this invocation's output.
    foreach ($capture in @($StdOutPath, $StdErrPath)) {
        if (Test-Path -LiteralPath $capture) { Remove-Item -LiteralPath $capture -Force }
    }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        [void](& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -File $launcherScript -StateRoot $StateRoot 2> $StdErrPath | Set-Content -LiteralPath $StdOutPath -Encoding UTF8)
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        return $code
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Read-TextOrEmpty([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $content = Get-Content -LiteralPath $Path -Raw
        if ($null -eq $content) { return '' }
        return [string]$content
    }
    return ''
}

function Read-Trimmed([string]$Path) {
    return ([string](Read-TextOrEmpty $Path)).Trim()
}

function Read-ErrorText([string]$Path) {
    # Windows PowerShell 5.1 turns a native command's redirected stderr into
    # NativeCommandError records and re-wraps them at the host's console width,
    # so one diagnostic can be split across several lines with indentation.
    # Matching runs on the collapsed text so a wrap point cannot break a
    # substring; the stream itself is unaffected.
    return ([string](Read-TextOrEmpty $Path)) -replace '\s+', ' '
}

function New-FakeState {
    param(
        [string]$StateRoot,
        [string]$LauncherPath,
        [string[]]$ExtraFilePaths = @(),
        [switch]$OmitLauncherHash,
        [switch]$CorruptHash,
        [switch]$CorruptJson,
        [switch]$OmitFiles
    )

    $mcpRoot = Join-Path $StateRoot 'host\test\mcp-server'
    $pythonRoot = Join-Path $StateRoot 'host\test\python'
    New-Item -ItemType Directory -Force -Path $mcpRoot, $pythonRoot | Out-Null

    $additional = @()
    foreach ($extra in $ExtraFilePaths) {
        Set-Content -LiteralPath $extra -Value 'extra' -Encoding UTF8
        $additional += $extra
    }

    $fakePython = Join-Path $pythonRoot 'python.exe'
    $fakeServer = Join-Path $mcpRoot 'aec_mcp_server.py'
    Set-Content -LiteralPath $fakePython -Value 'test' -Encoding UTF8
    Set-Content -LiteralPath $fakeServer -Value 'test' -Encoding UTF8

    if ($CorruptJson) {
        Set-Content -LiteralPath (Join-Path $StateRoot 'install-state.json') -Value '{ not json' -Encoding UTF8
        return
    }

    $files = @()
    foreach ($path in (@($LauncherPath, $fakePython, $fakeServer) + $additional)) {
        if ($OmitLauncherHash -and [IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($LauncherPath)) {
            continue
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($CorruptHash -and [IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($LauncherPath)) {
            $hash = ('0' * 64)
        }
        $files += [ordered]@{ path = [IO.Path]::GetFullPath($path); sha256 = $hash }
    }

    $state = [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($LauncherPath)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
    }
    if (-not $OmitFiles) { $state['files'] = $files }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $StateRoot 'install-state.json') -Encoding UTF8
}

# ---------------------------------------------------------------- static checks

foreach ($path in @($statusScript, $configScript, $launcherScript, $skillPath, $templatePath, $readmePath, $docPath, $setupRefPath, $acceptanceRefPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing DeepSeek Harness adapter file: $path" }
}

foreach ($script in @($statusScript, $configScript, $launcherScript)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell parse failure in $script`: $($errors[0].Message)" }
}
Write-Host 'PASS DeepSeek Harness adapter scripts parse'

$skill = Get-Content -LiteralPath $skillPath -Raw
foreach ($required in @('name: bim-bridge', 'description:', 'whenToUse:', 'disable-model-invocation: false')) {
    Assert-True ($skill.Contains($required)) "Skill declares required frontmatter field: $required"
}
Assert-True ($skill.Contains('mcp__bim-bridge__')) 'Skill documents the DeepSeek Harness MCP tool name prefix'

# Invocation-policy spelling guard, verified against the real parser rather than
# against this repository's own documentation.
#
# @deepseek-ai/dsh-skill-filesystem 0.1.5-rc.2 parses SKILL frontmatter in
# lib\index.js: a canonical invocation key is only "disable-model-invocation" or
# "user-invocable", and the legacy camelCase spellings are rejected outright by
# rejectLegacyInvocationKey, which throws as soon as the key exists, whatever its
# value. parseSkillFile catches that throw, warns, and drops the whole Skill, so a
# legacy spelling does not merely misconfigure bim-bridge: the Skill disappears
# from the DeepSeek Harness catalog entirely while the model still sees no error.
# The guard below therefore asserts the accepted spelling positively and keeps the
# rejected spellings out.
foreach ($legacyKey in @('disableModelInvocation', 'modelInvocable', 'userInvocable')) {
    Assert-True (-not $skill.Contains($legacyKey)) "Skill frontmatter avoids the rejected camelCase key: $legacyKey"
}

# The accepted keys are read out of the frontmatter block itself, between the
# opening and the closing "---" delimiter, so prose anywhere else in the Skill
# cannot satisfy or defeat these assertions.
$script:skillFrontmatterLines = @()
$frontmatterDelimiter = [regex]::Match($skill, '(?s)\A---[ \t]*\r?\n')
if ($frontmatterDelimiter.Success) {
    foreach ($frontmatterLine in ($skill.Substring($frontmatterDelimiter.Length) -split "`r?`n")) {
        if ($frontmatterLine -match '^---[ \t]*$') { break }
        $script:skillFrontmatterLines += $frontmatterLine
    }
}
Assert-True ($script:skillFrontmatterLines.Count -gt 0) 'Skill starts with a delimited frontmatter block'

$frontmatterKeys = @()
$frontmatterBadLines = @()
foreach ($frontmatterLine in $script:skillFrontmatterLines) {
    if ([string]::IsNullOrWhiteSpace($frontmatterLine)) { continue }
    $frontmatterField = [regex]::Match($frontmatterLine, '^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(\S.*)$')
    if ($frontmatterField.Success) {
        $frontmatterKeys += $frontmatterField.Groups[1].Value
    } else {
        $frontmatterBadLines += $frontmatterLine
    }
}
Assert-True ($frontmatterBadLines.Count -eq 0) "Skill frontmatter declares only flat scalar keys (unparsed: $($frontmatterBadLines -join ' | '))"

# The whitelist holds the required keys plus the optional keys the DeepSeek
# Harness parser accepts (README.md: name and description mandatory; whenToUse,
# metadata, disable-model-invocation and user-invocable optional). "type" is
# carried for the other adapters and is silently ignored by this parser, so it is
# listed explicitly instead of being treated as an error.
$allowedFrontmatterKeys = @('name', 'description', 'type', 'whenToUse', 'disable-model-invocation', 'user-invocable', 'metadata')
$unknownFrontmatterKeys = @($frontmatterKeys | Where-Object { $allowedFrontmatterKeys -notcontains $_ })
Assert-True ($unknownFrontmatterKeys.Count -eq 0) "Skill frontmatter uses only accepted keys (unknown: $($unknownFrontmatterKeys -join ', '))"

# frontmatterBoolean (lib\index.js) also accepts 1/0 and the case-insensitive
# spellings true/false, yes/no and on/off; anything else throws a TypeError and
# drops the whole Skill with a warning.
$booleanFrontmatterValues = @()
$invocationKeyChecked = $false
foreach ($frontmatterLine in $script:skillFrontmatterLines) {
    $frontmatterField = [regex]::Match($frontmatterLine, '^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(\S.*)$')
    if (-not $frontmatterField.Success) { continue }
    $frontmatterKey = $frontmatterField.Groups[1].Value
    if ($frontmatterKey -ne 'disable-model-invocation' -and $frontmatterKey -ne 'user-invocable') { continue }
    $invocationKeyChecked = $true
    $booleanFrontmatterValues += $frontmatterField.Groups[2].Value.Trim()
}
Assert-True $invocationKeyChecked 'Skill frontmatter declares the invocation policy key disable-model-invocation'
$nonBooleanInvocationValues = @($booleanFrontmatterValues | Where-Object { $_ -notmatch '^(?i:true|false|yes|no|on|off|0|1)$' })
Assert-True ($nonBooleanInvocationValues.Count -eq 0) "Skill invocation keys carry boolean-compatible values (rejected: $($nonBooleanInvocationValues -join ', '))"

# Regression guard for the real DeepSeek Harness spawn environment, where
# Microsoft.PowerShell.Utility can load partially: Get-FileHash is absent while
# ConvertFrom-Json still resolves. Hashing must therefore not go through the
# cmdlet. Comments may mention it; an actual invocation must not exist.
foreach ($guardScript in @($launcherScript, $statusScript, $configScript)) {
    $guardBody = Get-Content -LiteralPath $guardScript -Raw
    $guardInvocations = @()
    foreach ($guardLine in ($guardBody -split "`r?`n")) {
        $guardCode = ($guardLine -split '#')[0]
        if ($guardCode -match 'Get-FileHash') { $guardInvocations += $guardLine.Trim() }
    }
    $guardName = Split-Path -Leaf $guardScript
    Assert-True ($guardInvocations.Count -eq 0) "$guardName does not invoke Get-FileHash in the MCP spawn environment"
    # The .NET hashing contract applies wherever a script hashes at all:
    # Get-BimBridgeDshMcpConfig.ps1 never hashes, so it is held to the invocation
    # ban above but is correctly not required to contain a hashing call.
    if ($guardBody -match 'ConvertFrom-Json' -or $guardBody -match 'SHA256') {
        Assert-True ($guardBody -match 'Security\.Cryptography\.SHA256') "$guardName hashes through .NET SHA-256"
    }
}

$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
Assert-True ([string]$template.mcpServers.'bim-bridge'.transport -eq 'stdio') 'Template declares a stdio server'
Assert-True ([string]@($template.mcpServers.'bim-bridge'.args)[-1] -match 'Start-BimBridgeDshMcp\.ps1$') 'Template targets the bundled launcher wrapper'
Assert-True ([string]$template.mcpServers.'bim-bridge'.command -eq 'powershell.exe') 'Template uses the PowerShell stdio host'

# ------------------------------------------------------- real install untouched

$realStateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
$realStatePath = Join-Path $realStateRoot 'install-state.json'
$realStateHashBefore = if (Test-Path -LiteralPath $realStatePath -PathType Leaf) { (Get-FileHash -LiteralPath $realStatePath -Algorithm SHA256).Hash } else { $null }

$baselinePath = Join-Path $SourceRoot 'protocol\v1\baseline.json'
$baselineHashBefore = if (Test-Path -LiteralPath $baselinePath -PathType Leaf) { (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash } else { $null }

# ------------------------------------------------- shared-layer footprint
#
# This repository is a single shared working tree with no worktree isolation, so
# other members legitimately modify eng/**, src/**, installer/** and
# tests/adapters/kimi/** while this suite runs. Two independent checks replace
# the old whole-tree scan, which could not tell their work from this adapter's
# footprint and reported a false failure for any delivery that touched a shared
# layer.
#
#   1. Adapter read-only surface snapshot (hard, always runs). This suite's own
#      adapter files are hashed before and after the run and must be identical.
#      No git state and no other member's cooperation is involved.
#
#   2. Shared-layer observation (always runs, reported). The read-only shared
#      files this adapter must never modify are hashed before and after the run.
#      A byte change is reported with attribution instead of failing, because
#      other members verifiably rewrite those exact files while this suite runs:
#      a concurrent change to an already-dirty path is expected, and a change to
#      a path that was clean at the start is called out as unattributed.
#
#   3. Ownership baseline gate (opt-in). It runs only when the caller supplies an
#      explicit baseline, either through -OwnershipBaselinePath or
#      BIM_BRIDGE_DSH_OWNERSHIP_BASELINE. The baseline lists the repository
#      paths already allowed to be dirty before the run
#      (tests/adapters/deepseek-harness/ownership-baseline.txt is that snapshot
#      for the current phase). A forbidden path that is dirty without being in
#      the baseline fails the gate. Nothing is inferred from the dirty worktree
#      by default, and the same baseline plus the same worktree always yields
#      the same verdict.
#
# The shared-layer scope, shared by both checks.
$sharedLayerPathPatterns = @(
    '^(runtime|protocol|src|eng|installer|providers|plugins)/'
    '^adapters/(kimi|workbuddy)/'
    '^tests/adapters/(kimi|workbuddy)/'
)

# The read-only files this adapter must never modify, split by who else may
# legitimately be writing them while this suite runs.
#
# `adapterAnchorPaths` is this adapter's own read-only surface. A hard assertion
# covers it: nothing in this suite may change those bytes.
#
# `sharedLayerAnchorPaths` is the shared layer the adapter must not touch. It is
# observed and reported, but a byte change is NOT a hard failure here, because
# this suite shares one working tree with other members who are, verifiably,
# rewriting those exact files while it runs: `tests/architecture/
# Test-AutoCADVersionArchitecture.ps1` changed hash during three consecutive
# runs of this suite. Failing on that would be the same false positive this
# suite is required to stop reporting, only with a different trigger. Attribution
# is reported instead, and the hard shared-layer statement is the opt-in
# ownership gate below, which compares against a caller-declared baseline.
$adapterAnchorPaths = @(
    'adapters/deepseek-harness/mcp.template.json'
    'adapters/deepseek-harness/README.md'
    'adapters/deepseek-harness/skills/bim-bridge/SKILL.md'
    'adapters/deepseek-harness/skills/bim-bridge/references/setup.md'
    'adapters/deepseek-harness/skills/bim-bridge/references/acceptance.md'
    'adapters/deepseek-harness/skills/bim-bridge/scripts/Get-BimBridgeDshStatus.ps1'
    'adapters/deepseek-harness/skills/bim-bridge/scripts/Get-BimBridgeDshMcpConfig.ps1'
    'adapters/deepseek-harness/skills/bim-bridge/scripts/Start-BimBridgeDshMcp.ps1'
)

$sharedLayerAnchorPaths = @(
    'eng/AutodeskVersionMatrix.ps1'
    'eng/Build-AutoCADAdapters.ps1'
    'eng/Build-RevitAdapters.ps1'
    'eng/RevitVersionMatrix.ps1'
    'eng/Autodesk.Versions.props'
    'installer/Install-BimBridge.ps1'
    'Directory.Build.props'
    '.github/workflows/ci.yml'
    'tests/adapters/kimi/Test-KimiAdapter.ps1'
    'tests/architecture/Test-AutoCADVersionArchitecture.ps1'
    'tests/architecture/Test-RevitVersionArchitecture.ps1'
    'tests/architecture/Test-RevitRuntimeResolution.ps1'
    'docs/architecture.md'
)

function Get-FileSha256([string]$Path) {
    # .NET instead of Get-FileHash: the delegated DeepSeek Harness spawn is
    # documented to leave Microsoft.PowerShell.Utility partially loaded, and this
    # suite is also started from hosts where the cmdlet may be absent.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '')
}

function Get-AnchoredFileHash([string[]]$RelativePaths) {
    # Fails closed: a missing anchor file is an error, not an empty hash, so the
    # check cannot silently degrade into "nothing was compared".
    $parts = New-Object System.Collections.ArrayList
    foreach ($relative in $RelativePaths) {
        $full = Join-Path $SourceRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Anchor file is missing: $relative ($full)"
        }
        [void]$parts.Add($relative + ':' + (Get-FileSha256 $full))
    }
    return @($parts)
}

function Get-AnchoredFileDelta([string[]]$Before, [string[]]$After) {
    # Compares two equally ordered snapshots and returns the paths whose bytes
    # differ, so a report can name exactly which anchored file moved.
    $delta = @()
    $count = [Math]::Min($Before.Count, $After.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($Before[$index] -ne $After[$index]) {
            # Entries are "<repo-relative/path>:<SHA256>"; the path holds no colon.
            $delta += ([string]$Before[$index]).Substring(0, ([string]$Before[$index]).IndexOf(':'))
        }
    }
    return @($delta)
}

function Get-OwnershipBaselinePath {
    if ($OwnershipBaselinePath) { return [IO.Path]::GetFullPath($OwnershipBaselinePath) }
    if ($env:BIM_BRIDGE_DSH_OWNERSHIP_BASELINE) { return [IO.Path]::GetFullPath([string]$env:BIM_BRIDGE_DSH_OWNERSHIP_BASELINE) }
    return $null
}

function Get-OwnershipBaselineEntry {
    param([string]$Text)
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        # Both plain path lists and raw `git status --porcelain` output are
        # accepted, so an operator can save the tool's own output as a baseline.
        if ($trimmed -match '^\s*[A-Z?!]{1,2}\s+(.+)$') {
            $trimmed = ($Matches[1] -split ' -> ')[-1].Trim().Trim('"')
        }
        if ($trimmed) { $trimmed.Replace('\', '/') }
    }
}

# git is not always resolvable by name in every execution context this suite runs
# in (spawned build/verification hosts inherit a narrower PATH), and a bare `& git`
# then throws a CommandNotFoundException that `2>&1` turns into an empty string -
# which silently degraded every git-backed gate here to "cannot tell -> empty
# list". The executable is therefore resolved once, by name and then by the
# standard installation locations, and every git call uses the absolute path.
function Resolve-GitCommand {
    $byName = Get-Command git -ErrorAction SilentlyContinue
    if ($byName) { return [string]$byName.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

# `--untracked-files=no` alone was not enough: `git status --porcelain` reports a
# *staged* addition as `A  <path>` even with untracked files excluded, so a new
# shared-layer file of this phase that had been `git add`-ed failed the gate as an
# "unexpected modification". That contradicts the policy this gate documents -
# untracked additions are, by construction, additions made by this development
# phase rather than modifications of an existing shared-layer file, and one of them
# (docs/integration-2.0.0-alpha.4.md) is inside the shared-layer scope. The status
# entry is therefore read from column X (the index/HEAD column) and an `A` there is
# skipped, which makes "staged" and "unstaged" additions behave identically.
# Comparing tracked *modifications* only keeps the verdict reproducible across
# reruns, which the whole-tree scan was not.
function Get-SharedLayerWorktreePaths([string]$TreeRoot) {
    <#
        Returns the forbidden shared-layer paths that `git status --porcelain`
        reports as modified, deleted, renamed, or typed-changed in $TreeRoot.
        A missing git or repository yields an empty list; callers compare the
        snapshot with itself, so "cannot tell" never becomes "modified".
    #>
    $gitCommand = Resolve-GitCommand
    if (-not $gitCommand) { return @() }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $statusOutput = & $gitCommand -C $TreeRoot status --porcelain --untracked-files=no 2>&1
        $statusCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($statusCode -ne 0) { return @() }
    $found = @()
    foreach ($line in @($statusOutput)) {
        $text = [string]$line
        if ($text -match '^([ MADRCU?!]{1,2})\s+(.+)$') {
            # Column X is the index/HEAD column, column Y is the worktree column.
            #   '??' -> untracked, '!!' -> ignored  : an addition, out of scope
            #   'A ' -> staged addition            : an addition, out of scope
            #   ' M' -> unstaged modification      : in scope
            $indexColumn = [string]$Matches[1][0]
            if ($indexColumn -eq '?' -or $indexColumn -eq '!') { continue }
            if ($indexColumn -eq 'A') { continue }
            # The path is split with the -split operator on purpose. The .NET
            # Split(char[]) overload is what a one-character argument binds to,
            # and Windows PowerShell 5.1 coerces the ' -> ' argument to the char
            # array ' ', '-', '>', which truncates "eng/Build-AutoCADAdapters.ps1"
            # to "AutoCADAdapters.ps1" and hides most of the forbidden set.
            $relative = ([string]$Matches[2] -split ' -> ')[-1].Trim().Trim('"').Replace('\', '/')
            if ($relative -and (@($sharedLayerPathPatterns | Where-Object { $relative -match $_ }).Count -gt 0)) {
                $found += $relative
            }
        }
    }
    return @($found | Sort-Object -Unique)
}

function Test-OwnershipBaseline {
    <#
        Opt-in ownership gate. Returns @{ Skipped; BaselinePath; AllowedCount;
        Unexpected; Current }.
        * No baseline supplied  -> Skipped; the caller reports SKIP, never FAIL,
          because without a caller-declared baseline there is no reproducible
          statement to make about a shared working tree.
        * Baseline supplied     -> every currently dirty shared-layer path must
          be listed in it; anything else is Unexpected and fails.
    #>
    $baselinePath = Get-OwnershipBaselinePath
    $result = @{ Skipped = $true; BaselinePath = $null; AllowedCount = 0; Unexpected = @(); Current = @() }
    if (-not $baselinePath) { return $result }
    $result.Skipped = $false
    $result.BaselinePath = $baselinePath
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        throw "Ownership baseline was requested but does not exist: $baselinePath"
    }
    $allowed = @(Get-OwnershipBaselineEntry (Get-Content -LiteralPath $baselinePath -Raw))
    $result.AllowedCount = $allowed.Count
    $current = @(Get-SharedLayerWorktreePaths $SourceRoot)
    $result.Current = $current
    $result.Unexpected = @($current | Where-Object { $allowed -notcontains $_ })
    return $result
}

$adapterAnchorPartsBefore = Get-AnchoredFileHash $adapterAnchorPaths
$sharedLayerAnchorPartsBefore = Get-AnchoredFileHash $sharedLayerAnchorPaths
$sharedLayerDirtyBefore = @(Get-SharedLayerWorktreePaths $SourceRoot)

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-dsh-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

try {
    # Space-in-path coverage is asserted by the relocation check later, which
    # copies the adapter into a directory whose name contains a space.

    # 1. healthy fixture
    $hostRoot = Join-Path $temporaryRoot 'host\test'
    New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
    $fakeLauncher = Join-Path $hostRoot 'Start-BimBridgeMcp.ps1'
    Set-Content -LiteralPath $fakeLauncher -Value '[Console]::Out.WriteLine("fake-dsh-mcp:" + $env:BIM_BRIDGE_AGENT_ADAPTER)' -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    $status = (& $statusScript -StateRoot $temporaryRoot -DshVersionOverride '0.1.5-rc.2') | ConvertFrom-Json
    Assert-True ([string]$status.status -eq 'healthy') 'Read-only status accepts a healthy neutral Host'
    Assert-True ([string]$status.adapter -eq 'deepseek-harness') 'Read-only status reports the deepseek-harness adapter identity'
    Assert-True ([string]$status.recommendedAction -eq 'none') 'Healthy status recommends no action'

    # 2. changed critical file
    Set-Content -LiteralPath (Join-Path $temporaryRoot 'host\test\mcp-server\aec_mcp_server.py') -Value 'changed' -Encoding UTF8
    $changed = (& $statusScript -StateRoot $temporaryRoot -DshVersionOverride '0.1.5-rc.2') | ConvertFrom-Json
    Assert-True ([string]$changed.status -eq 'needs_repair') 'Read-only status flags a changed critical Host file'
    Assert-True (@($changed.host.changedFiles).Count -eq 1) 'Read-only status lists exactly one changed file'

    # 3. incomplete state
    $invalidState = Get-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Raw | ConvertFrom-Json
    $invalidState.PSObject.Properties.Remove('files')
    $invalidState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $invalid = (& $statusScript -StateRoot $temporaryRoot -DshVersionOverride '0.1.5-rc.2') | ConvertFrom-Json
    Assert-True ([string]$invalid.status -eq 'needs_repair') 'Read-only status fails closed on incomplete Host state'
    Assert-True ([string]$invalid.host.stateError -match "missing 'files'") 'Read-only status names the missing state property'

    # 4. no state at all
    $emptyRoot = Join-Path $temporaryRoot 'empty-root'
    New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
    $absent = (& $statusScript -StateRoot $emptyRoot -DshVersionOverride '0.1.5-rc.2') | ConvertFrom-Json
    Assert-True ([string]$absent.status -eq 'not_installed') 'Read-only status reports not_installed without state'
    Assert-True ([string]$absent.recommendedAction -eq 'install_host') 'not_installed recommends installing the Host'

    # 5. DSH absent
    #
    # The adapter also discovers DeepSeek Harness at fixed per-user locations that
    # need no PATH entry, so an empty PATH alone no longer means "not found" -
    # discovery would legitimately succeed on a machine that has DSH installed.
    # The negative case therefore suppresses discovery explicitly through the two
    # documented override hooks, which are the same switches an operator uses to
    # pin a non-standard installation.
    $previousPath = $env:PATH
    $previousDshCommand = $env:BIM_BRIDGE_DSH_COMMAND
    $previousDshNode = $env:BIM_BRIDGE_DSH_NODE
    try {
        $env:PATH = ''
        $env:BIM_BRIDGE_DSH_COMMAND = Join-Path $temporaryRoot 'absent\dsh.cmd'
        $env:BIM_BRIDGE_DSH_NODE = Join-Path $temporaryRoot 'absent\node.exe'
        $noDsh = (& $statusScript -StateRoot $temporaryRoot) | ConvertFrom-Json
    } finally {
        $env:PATH = $previousPath
        $env:BIM_BRIDGE_DSH_COMMAND = $previousDshCommand
        $env:BIM_BRIDGE_DSH_NODE = $previousDshNode
    }
    Assert-True ([string]$noDsh.status -eq 'deepseek_harness_not_found') 'Read-only status detects a missing DeepSeek Harness'
    Assert-True ([string]$noDsh.recommendedAction -eq 'install_deepseek_harness') 'Missing DeepSeek Harness recommends installing it'
    Assert-True (-not [bool]$noDsh.deepSeekHarness.installed) 'Missing DeepSeek Harness is reported as not installed'

    # 5b. PATH-less discovery
    #
    # The requirement this covers: the adapter must resolve both the local `dsh`
    # shim and the bundled Node interpreter with no `dsh`/`node` on PATH and with
    # no global installation. Both hooks are pointed at disposable fixtures, and
    # the process PATH is emptied for the duration, so a pass cannot be produced
    # by the developer machine's own PATH.
    #
    # Every fixture is a .cmd shim, the same shape the real local `dsh` entry point
    # has, and it is invoked by absolute path: the process PATH is empty for the
    # duration, so nothing can be resolved through it. The `.cmd` is a thin wrapper
    # around a `.ps1` so the version string is emitted without a host banner; that
    # is also exactly how the real shim delegates to its JavaScript entry point.
    $discoveryRoot = Join-Path $temporaryRoot 'discovery'
    $fakeNodeDirectory = Join-Path $discoveryRoot 'node-v24.19.0-win-x64'
    $fakeNode = Join-Path $fakeNodeDirectory 'node.exe'
    $fakeShim = Join-Path $discoveryRoot 'checkout\node_modules\.bin\dsh.cmd'
    $fakeShimScript = Join-Path $discoveryRoot 'checkout\node_modules\.bin\dsh-version.ps1'
    New-Item -ItemType Directory -Force -Path $fakeNodeDirectory, (Split-Path -Parent $fakeShim) | Out-Null
    Set-Content -LiteralPath $fakeNode -Value 'placeholder' -Encoding ASCII
    Set-Content -LiteralPath $fakeShimScript -Value "Write-Output '9.9.9-test'" -Encoding UTF8
    Set-Content -LiteralPath $fakeShim -Encoding ASCII -Value @(
        '@echo off'
        '"' + $windowsPowerShell + '" -NoLogo -NoProfile -NonInteractive -File "' + $fakeShimScript + '" %*'
        ''
    )

    try {
        $env:PATH = ''
        $env:BIM_BRIDGE_DSH_COMMAND = $fakeShim
        $env:BIM_BRIDGE_DSH_NODE = $fakeNode
        $discovered = (& $statusScript -StateRoot $temporaryRoot) | ConvertFrom-Json
    } finally {
        $env:PATH = $previousPath
        $env:BIM_BRIDGE_DSH_COMMAND = $previousDshCommand
        $env:BIM_BRIDGE_DSH_NODE = $previousDshNode
    }
    Assert-True ([bool]$discovered.deepSeekHarness.installed) 'PATH-less discovery resolves DeepSeek Harness without a global PATH entry'
    Assert-True ([string]$discovered.deepSeekHarness.command -eq [IO.Path]::GetFullPath($fakeShim)) 'PATH-less discovery resolves the local dsh shim'
    Assert-True ([string]$discovered.deepSeekHarness.commandSource -eq 'BIM_BRIDGE_DSH_COMMAND') 'Discovered dsh shim reports the override hook it came from'
    Assert-True ([string]$discovered.deepSeekHarness.node -eq [IO.Path]::GetFullPath($fakeNode)) 'PATH-less discovery resolves the bundled Node interpreter'
    Assert-True ([string]$discovered.deepSeekHarness.nodeSource -eq 'BIM_BRIDGE_DSH_NODE') 'Discovered Node interpreter reports the override hook it came from'
    Assert-True ([string]$discovered.deepSeekHarness.version -eq '9.9.9-test') 'PATH-less discovery reports the version the resolved shim answers'

    # 5c. Discovery must not accept a path that does not exist, and must not leak
    #     a phantom `dsh` when only the interpreter is present.
    $missingShimOnly = Join-Path $temporaryRoot 'absent-only\dsh.cmd'
    try {
        $env:PATH = ''
        $env:BIM_BRIDGE_DSH_COMMAND = $missingShimOnly
        $env:BIM_BRIDGE_DSH_NODE = $fakeNode
        $phantom = (& $statusScript -StateRoot $temporaryRoot) | ConvertFrom-Json
    } finally {
        $env:PATH = $previousPath
        $env:BIM_BRIDGE_DSH_COMMAND = $previousDshCommand
        $env:BIM_BRIDGE_DSH_NODE = $previousDshNode
    }
    Assert-True ([string]$phantom.status -eq 'deepseek_harness_not_found') 'Discovery rejects a dsh candidate that does not exist on disk'

    # 5c-ii. The Node override is terminal in the same way: a named interpreter that
    #        does not exist is reported as no interpreter rather than being
    #        replaced by the bundled one.
    try {
        $env:PATH = ''
        $env:BIM_BRIDGE_DSH_COMMAND = $fakeShim
        $env:BIM_BRIDGE_DSH_NODE = Join-Path $temporaryRoot 'absent-only\node.exe'
        $phantomNode = (& $statusScript -StateRoot $temporaryRoot) | ConvertFrom-Json
    } finally {
        $env:PATH = $previousPath
        $env:BIM_BRIDGE_DSH_COMMAND = $previousDshCommand
        $env:BIM_BRIDGE_DSH_NODE = $previousDshNode
    }
    Assert-True ($null -eq $phantomNode.deepSeekHarness.node) 'Node override that does not exist is reported as unresolved'

    # 5d. On this machine, with both overrides cleared and PATH emptied, the real
    #     DSH installation must still resolve through the documented per-user
    #     locations alone. This is the environment the requirement describes: no
    #     dsh on PATH, no node on PATH, no global installation.
    #
    #     The check is skipped, not failed, on a machine without a per-user DSH
    #     installation: a missing installation is a legitimate
    #     `deepseek_harness_not_found`, not a discovery defect.
    #
    #     The environment is read and restored here and a final check below proves
    #     the persisted user PATH is never touched, so emptying the process PATH
    #     cannot leak into the developer's shell.
    $userPathBefore = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $realInstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\DeepSeekHarness'
    $realBundledNode = @(Get-ChildItem -LiteralPath $realInstallRoot -Directory -Filter 'node-*-win-*' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'node.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $realLauncher = Join-Path $realInstallRoot 'bin\dsh.cmd'
    if ($realBundledNode.Count -gt 0 -and (Test-Path -LiteralPath $realLauncher -PathType Leaf)) {
        # Check 3 and 5 above left this fixture with an incomplete install-state;
        # rebuild the healthy one so the assertion below is about discovery and
        # not about the residue of an earlier negative case.
        Set-Content -LiteralPath (Join-Path $temporaryRoot 'host\test\mcp-server\aec_mcp_server.py') -Value 'test' -Encoding UTF8
        New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher
        try {
            $env:PATH = ''
            $env:BIM_BRIDGE_DSH_COMMAND = $null
            $env:BIM_BRIDGE_DSH_NODE = $null
            $realDiscovery = (& $statusScript -StateRoot $temporaryRoot) | ConvertFrom-Json
        } finally {
            $env:PATH = $previousPath
            $env:BIM_BRIDGE_DSH_COMMAND = $previousDshCommand
            $env:BIM_BRIDGE_DSH_NODE = $previousDshNode
        }
        Assert-True ([string]$realDiscovery.deepSeekHarness.command -eq [IO.Path]::GetFullPath($realLauncher)) 'The per-user DSH launcher is discovered with an empty PATH'
        Assert-True ([string]$realDiscovery.deepSeekHarness.commandSource -eq 'dsh_install') 'Per-user DSH launcher discovery reports its own source'
        Assert-True ([string]$realDiscovery.deepSeekHarness.node -eq [IO.Path]::GetFullPath($realBundledNode[0])) 'Bundled Node is discovered with an empty PATH and no override'
        Assert-True ([string]$realDiscovery.deepSeekHarness.nodeSource -eq 'bundled_node') 'Bundled Node discovery reports its own source'
        Assert-True ([string]$realDiscovery.status -eq 'healthy') 'PATH-less discovery reaches a healthy status against the real Host and DSH installation'
    } else {
        Write-Host "SKIP real PATH-less discovery: no per-user DeepSeek Harness installation under $realInstallRoot"
    }

    $userPathAfter = [Environment]::GetEnvironmentVariable('PATH', 'User')
    Assert-True ($userPathBefore -eq $userPathAfter) 'Discovery leaves the persisted user PATH byte-identical'

    # restore the healthy fixture for the launcher checks
    Set-Content -LiteralPath (Join-Path $temporaryRoot 'host\test\mcp-server\aec_mcp_server.py') -Value 'test' -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    # 6. normal start, exit code, stream separation
    $outPath = Join-Path $temporaryRoot 'stdout.txt'
    $errPath = Join-Path $temporaryRoot 'stderr.txt'
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    $stdout = Read-Trimmed $outPath
    $stderr = Read-Trimmed $errPath
    Assert-True ($exitCode -eq 0) "Launcher exits 0 on a verified Host (got $exitCode)"
    Assert-True ($stdout -eq 'fake-dsh-mcp:deepseek-harness') 'Launcher delegates with the deepseek-harness adapter identity'
    Assert-True ([string]::IsNullOrWhiteSpace($stderr)) 'Launcher writes no diagnostics to stderr on success'
    Assert-True (-not $stdout.Contains('BIM Bridge DeepSeek Harness adapter')) 'Diagnostic banner never reaches stdout'

    # 6b. The wrapper must make the resolved Node interpreter reachable for the
    #     process it delegates to without a machine-wide installation. The child
    #     here reports the Node directory it can see; the process PATH is emptied
    #     and the interpreter is supplied through the documented override hook, so
    #     a pass cannot come from this developer machine's own PATH.
    $nodeProbeRoot = Join-Path $temporaryRoot 'node-probe'
    $nodeProbeDirectory = Join-Path $nodeProbeRoot 'node-v24.19.0-win-x64'
    New-Item -ItemType Directory -Force -Path $nodeProbeDirectory | Out-Null
    $nodeProbe = Join-Path $nodeProbeDirectory 'node.exe'
    Set-Content -LiteralPath $nodeProbe -Value 'placeholder' -Encoding ASCII
    Set-Content -LiteralPath $fakeLauncher -Encoding UTF8 -Value @(
        '[Console]::Out.WriteLine("node-dir:" + (Split-Path -Parent (Get-Command node.exe -ErrorAction SilentlyContinue).Source))'
    )
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    $previousNodeOverride = $env:BIM_BRIDGE_DSH_NODE
    try {
        $env:PATH = ''
        $env:BIM_BRIDGE_DSH_NODE = $nodeProbe
        $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
        $nodeStdout = Read-Trimmed $outPath
        $nodeStderr = Read-Trimmed $errPath
    } finally {
        $env:PATH = $previousPath
        $env:BIM_BRIDGE_DSH_NODE = $previousNodeOverride
    }
    Assert-True ($exitCode -eq 0) "Wrapper starts with an empty PATH (got $exitCode)"
    Assert-True ($nodeStdout -eq ('node-dir:' + $nodeProbeDirectory)) 'Wrapper exposes the resolved Node interpreter to the delegated process without a global PATH'
    Assert-True ([string]::IsNullOrWhiteSpace($nodeStderr)) 'Empty-PATH start writes no diagnostics to stderr'

    # Restore the reporting fixture used by the checks below.
    Set-Content -LiteralPath $fakeLauncher -Value '[Console]::Out.WriteLine("fake-dsh-mcp:" + $env:BIM_BRIDGE_AGENT_ADAPTER)' -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    # 7. state missing
    $missingStateRoot = Join-Path $temporaryRoot 'missing-state'
    New-Item -ItemType Directory -Force -Path $missingStateRoot | Out-Null
    $exitCode = Invoke-LauncherRaw -StateRoot $missingStateRoot -StdOutPath $outPath -StdErrPath $errPath
    $stdout = Read-Trimmed $outPath
    $stderr = Read-ErrorText $errPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses to start without install-state'
    Assert-True ($stderr -match 'Host state is missing') 'Missing install-state is reported on stderr'
    Assert-True ([string]::IsNullOrWhiteSpace($stdout)) 'Refused start writes nothing to stdout'

    # 8. corrupt state
    $corruptRoot = Join-Path $temporaryRoot 'corrupt-state'
    New-Item -ItemType Directory -Force -Path $corruptRoot | Out-Null
    New-FakeState -StateRoot $corruptRoot -LauncherPath $fakeLauncher -CorruptJson
    $exitCode = Invoke-LauncherRaw -StateRoot $corruptRoot -StdOutPath $outPath -StdErrPath $errPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses to start on unparseable install-state'
    Assert-True ((Read-Trimmed $errPath).Length -gt 0) 'Unparseable install-state is diagnosed on stderr'

    # 9. launcher missing: the state records a launcher under the Host root that
    # no longer exists on disk.
    $missingLauncherRoot = Join-Path $temporaryRoot 'missing-launcher'
    $missingLauncherPath = Join-Path $missingLauncherRoot 'host\test\Start-BimBridgeMcp.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $missingLauncherPath) | Out-Null
    Set-Content -LiteralPath $missingLauncherPath -Value 'exit 0' -Encoding UTF8
    New-FakeState -StateRoot $missingLauncherRoot -LauncherPath $missingLauncherPath
    Remove-Item -LiteralPath $missingLauncherPath -Force
    $exitCode = Invoke-LauncherRaw -StateRoot $missingLauncherRoot -StdOutPath $outPath -StdErrPath $errPath
    $stdout = Read-Trimmed $outPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses to start when the recorded launcher is missing'
    Assert-True ((Read-ErrorText $errPath) -match 'launcher is missing') 'Missing launcher is diagnosed on stderr'
    Assert-True ([string]::IsNullOrWhiteSpace($stdout)) 'Missing launcher writes nothing to stdout'

    # 10. launcher outside the Host root
    $outsideLauncher = Join-Path $temporaryRoot 'outside-host.ps1'
    Set-Content -LiteralPath $outsideLauncher -Value "Write-Output 'unsafe'" -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $outsideLauncher
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    $stdout = Read-Trimmed $outPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses a recorded launcher outside the Host root'
    Assert-True ((Read-ErrorText $errPath) -match 'outside the BIM Bridge Host root') 'Path escape is diagnosed on stderr'
    Assert-True ($stdout -ne 'unsafe') 'Escaped launcher is never executed'

    # 11. the containment control must survive file-system aliasing, not just
    #     path traversal. A recorded path can sit inside the Host root while the
    #     bytes or the directory it names live outside it; the prefix comparison
    #     alone passes and the installation hash matches the aliased bytes, so
    #     only resolving the real link target catches these.
    #
    #     A hard link has no canonical target path at all, so the recorded path is
    #     a full alias of data that may have been authored outside the root: a
    #     launcher reached through one is refused rather than trusted.
    $aliasPayload = Join-Path $temporaryRoot 'alias-payload.ps1'
    Set-Content -LiteralPath $aliasPayload -Value "Write-Output 'ESCAPED-OUTSIDE'" -Encoding UTF8
    $hardLinkHost = Join-Path $temporaryRoot 'hardlink-state\host\unit'
    New-Item -ItemType Directory -Force -Path $hardLinkHost | Out-Null
    $hardLinkLauncher = Join-Path $hardLinkHost 'Start-BimBridgeMcp.ps1'
    $hardLinkCreated = $true
    try {
        [void](New-Item -ItemType HardLink -Path $hardLinkLauncher -Target $aliasPayload -ErrorAction Stop)
    } catch {
        $hardLinkCreated = $false
    }
    if ($hardLinkCreated) {
        New-FakeState -StateRoot (Join-Path $temporaryRoot 'hardlink-state') -LauncherPath $hardLinkLauncher
        $exitCode = Invoke-LauncherRaw -StateRoot (Join-Path $temporaryRoot 'hardlink-state') -StdOutPath $outPath -StdErrPath $errPath
        $stdout = Read-Trimmed $outPath
        Assert-True ($exitCode -ne 0) 'Launcher refuses a recorded launcher reached through a hard link'
        Assert-True ((Read-ErrorText $errPath) -match 'hard link') 'Hard-link alias is diagnosed on stderr'
        Assert-True ($stdout -ne 'ESCAPED-OUTSIDE') 'Hard-link aliased launcher is never executed'
        Assert-True ([string]::IsNullOrWhiteSpace($stdout)) 'Hard-link refusal writes nothing to stdout'
    }

    #     A directory junction under the Host root redirects an in-root path to a
    #     directory outside it. This is the reparse-point half of the same control.
    $junctionTarget = Join-Path $temporaryRoot 'junction-target'
    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    $junctionPayload = Join-Path $junctionTarget 'Start-BimBridgeMcp.ps1'
    Set-Content -LiteralPath $junctionPayload -Value "Write-Output 'ESCAPED-VIA-JUNCTION'" -Encoding UTF8
    $junctionStateRoot = Join-Path $temporaryRoot 'junction-state'
    $junctionHost = Join-Path $junctionStateRoot 'host'
    New-Item -ItemType Directory -Force -Path $junctionHost | Out-Null
    $junctionCreated = $true
    try {
        [void](New-Item -ItemType Junction -Path (Join-Path $junctionHost 'junc') -Target $junctionTarget -ErrorAction Stop)
    } catch {
        $junctionCreated = $false
    }
    if ($junctionCreated) {
        $junctionLauncher = Join-Path $junctionHost 'junc\Start-BimBridgeMcp.ps1'
        New-FakeState -StateRoot $junctionStateRoot -LauncherPath $junctionLauncher
        $exitCode = Invoke-LauncherRaw -StateRoot $junctionStateRoot -StdOutPath $outPath -StdErrPath $errPath
        $stdout = Read-Trimmed $outPath
        Assert-True ($exitCode -ne 0) 'Launcher refuses a launcher reached through a directory junction out of the Host root'
        Assert-True ((Read-ErrorText $errPath) -match 'reparse point|resolves outside') 'Junction escape is diagnosed on stderr'
        Assert-True ($stdout -ne 'ESCAPED-VIA-JUNCTION') 'Junction aliased launcher is never executed'
        Assert-True ([string]::IsNullOrWhiteSpace($stdout)) 'Junction refusal writes nothing to stdout'
    }

    # 12. hash record missing
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher -OmitLauncherHash
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses a launcher with no recorded hash'
    Assert-True ((Read-ErrorText $errPath) -match 'valid installation hash') 'Missing hash record is diagnosed on stderr'

    # 13. hash mismatch
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher -CorruptHash
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses a launcher whose recorded hash does not match'
    Assert-True ((Read-ErrorText $errPath) -match 'hash mismatch') 'Hash mismatch is diagnosed on stderr'

    # 14. child exit code propagation
    Set-Content -LiteralPath $fakeLauncher -Value 'exit 7' -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    Assert-True ($exitCode -eq 7) "Launcher propagates the delegated child exit code (got $exitCode)"
    Set-Content -LiteralPath $fakeLauncher -Value '[Console]::Out.WriteLine("fake-dsh-mcp:" + $env:BIM_BRIDGE_AGENT_ADAPTER)' -Encoding UTF8
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    # 15. unsupported schema version
    $state = Get-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Raw | ConvertFrom-Json
    $state.schemaVersion = 3
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    Assert-True ($exitCode -ne 0) 'Launcher refuses an unsupported install-state schema version'
    Assert-True ((Read-ErrorText $errPath) -match 'Unsupported BIM Bridge install-state schema') 'Schema mismatch is diagnosed on stderr'

    # Restore a valid fixture before the stream-separation check below.
    New-FakeState -StateRoot $temporaryRoot -LauncherPath $fakeLauncher

    # 16. config generation
    $config = (& $configScript -Style mcp-servers) | ConvertFrom-Json
    $server = $config.mcpServers.'bim-bridge'
    Assert-True ([string]$server.command -eq 'powershell.exe') 'Generated configuration is a PowerShell stdio server'
    Assert-True (-not $server.PSObject.Properties['url']) 'Generated configuration declares no HTTP transport'
    $generatedLauncher = [string]@($server.args)[-1]
    Assert-True ([IO.Path]::IsPathRooted($generatedLauncher)) 'Generated configuration uses an absolute launcher path'
    Assert-True ([IO.Path]::GetFullPath($generatedLauncher) -eq [IO.Path]::GetFullPath($launcherScript)) 'Generated configuration targets the bundled launcher wrapper'
    Assert-True ([string]$server.transport -eq 'stdio') 'Generated configuration declares stdio transport'

    $patch = (& $configScript -Style cordis-patch) -join "`n"
    Assert-True ($patch -match "@deepseek-ai/dsh-mcp-client") 'Cordis overlay names the DeepSeek Harness MCP client package'
    Assert-True ($patch -match 'serverName: bim-bridge') 'Cordis overlay names the bim-bridge server namespace'
    Assert-True ($patch -match 'failOnStartupError: true') 'Cordis overlay fails loudly when the Host cannot start'
    Assert-True (-not ($patch -match "(?m)^\s*connectTimeout")) 'Cordis overlay invents no unsupported connection timeout field'
    Assert-True (-not ($patch -match "(?m)^\s*toolListTimeout")) 'Cordis overlay invents no unsupported tool-list timeout field'

    # 16. relocation: the wrapper resolves from its own location, not a fixed path
    $relocatedRoot = Join-Path $temporaryRoot 'relocated copy'
    New-Item -ItemType Directory -Force -Path $relocatedRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts') -Destination $relocatedRoot -Recurse -Force
    $relocatedLauncher = Join-Path $relocatedRoot 'scripts\Start-BimBridgeDshMcp.ps1'
    $relocatedConfig = (& (Join-Path $relocatedRoot 'scripts\Get-BimBridgeDshMcpConfig.ps1') -Style mcp-servers) | ConvertFrom-Json
    $relocatedLauncherArgument = [string]@($relocatedConfig.mcpServers.'bim-bridge'.args)[-1]
    Assert-True ([IO.Path]::GetFullPath($relocatedLauncherArgument) -eq [IO.Path]::GetFullPath($relocatedLauncher)) 'Relocated adapter resolves its own launcher path'
    Assert-True ($relocatedLauncherArgument.Contains(' ')) 'Relocated adapter handles a path containing spaces'

    # 17. the adapter never writes the real installation or the shared protocol
    $realStateHashAfter = if (Test-Path -LiteralPath $realStatePath -PathType Leaf) { (Get-FileHash -LiteralPath $realStatePath -Algorithm SHA256).Hash } else { $null }
    Assert-True ($realStateHashBefore -eq $realStateHashAfter) 'Real BIM Bridge install-state is byte-identical after tests'

    $baselineHashAfter = if (Test-Path -LiteralPath $baselinePath -PathType Leaf) { (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash } else { $null }
    Assert-True ($baselineHashBefore -eq $baselineHashAfter) 'Shared protocol baseline is byte-identical after tests'

    $otherAdapters = @(
        (Join-Path $SourceRoot 'adapters\kimi'),
        (Join-Path $SourceRoot 'adapters\workbuddy')
    )
    foreach ($other in $otherAdapters) {
        Assert-True (Test-Path -LiteralPath $other -PathType Container) "Existing adapter preserved: $(Split-Path -Leaf $other)"
    }

    # 18. the adapter modifies no other agent's behaviour and no shared layer
    #
    # 18a is a hard, always-on assertion about this suite's own read-only
    # surface: every adapter file must still hash to the same value. It needs no
    # baseline git state and no other member's cooperation.
    $adapterAnchorPartsAfter = Get-AnchoredFileHash $adapterAnchorPaths
    $adapterAnchorDelta = @(Get-AnchoredFileDelta $adapterAnchorPartsBefore $adapterAnchorPartsAfter)
    Assert-True ($adapterAnchorDelta.Count -eq 0) "DeepSeek Harness adapter files are byte-identical after the suite (changed: $($adapterAnchorDelta -join ', '))"

    # 18b observes the shared layer the adapter must not touch. A byte change
    # there is reported, not failed: other members hold those exact files dirty
    # in this shared working tree and are provably rewriting them mid-run, so a
    # change is not attributable to this adapter. Concurrent edits to paths that
    # were already dirty before the run are expected; a change to a path that was
    # clean before the run is called out explicitly as unattributed.
    $sharedLayerAnchorPartsAfter = Get-AnchoredFileHash $sharedLayerAnchorPaths
    $sharedLayerDelta = @(Get-AnchoredFileDelta $sharedLayerAnchorPartsBefore $sharedLayerAnchorPartsAfter)
    # A changed path that was already dirty when the run started has a known
    # concurrent writer (the other member holding it). A changed path that was
    # clean at the start has no such explanation, so it is named explicitly.
    $sharedLayerConcurrent = @($sharedLayerDelta | Where-Object { $sharedLayerDirtyBefore -contains $_ })
    $sharedLayerUnattributed = @($sharedLayerDelta | Where-Object { $sharedLayerDirtyBefore -notcontains $_ })
    Assert-True ($sharedLayerAnchorPaths.Count -ge 12) "Shared-layer observation covered $($sharedLayerAnchorPaths.Count) read-only files"
    Assert-True ($adapterAnchorPaths.Count -ge 8) "Adapter read-only surface observation covered $($adapterAnchorPaths.Count) files"
    if ($sharedLayerConcurrent.Count -gt 0) {
        Write-Host "NOTE concurrent shared-layer edits by another member during this run (not attributed to this adapter): $($sharedLayerConcurrent -join ', ')"
    }
    if ($sharedLayerUnattributed.Count -gt 0) {
        Write-Host "WARNING shared-layer paths that were clean before this run changed bytes during it: $($sharedLayerUnattributed -join ', ')"
    }
    # 18c is the hard shared-layer statement, and it is opt-in and reproducible:
    # it runs only against a caller-supplied baseline. In a shared working tree
    # without one the gate reports SKIP, which is honest - there is no
    # caller-declared expectation to check - and never a silent failure of
    # another member's legitimate work.
    $ownership = Test-OwnershipBaseline
    if ($ownership.Skipped) {
        Write-Host 'SKIP ownership baseline gate: no -OwnershipBaselinePath and no BIM_BRIDGE_DSH_OWNERSHIP_BASELINE provided'
    } else {
        if ($ownership.Current.Count -gt 0) {
            Write-Host "NOTE shared-layer paths dirty in this worktree: $($ownership.Current -join ', ')"
        }
        Assert-True ($ownership.Unexpected.Count -eq 0) "No shared-layer path outside the ownership baseline was modified (baseline: $($ownership.BaselinePath), allowed: $($ownership.AllowedCount), unexpected: $($ownership.Unexpected -join ', '))"
        # Same baseline plus same worktree must yield the same verdict: rerunning
        # the gate immediately must not change the answer.
        $ownershipAgain = Test-OwnershipBaseline
        Assert-True (@($ownershipAgain.Unexpected).Count -eq $ownership.Unexpected.Count) 'Ownership baseline gate is reproducible across repeated runs'
    }

    # Whitespace hygiene for the paths this suite owns. The scope is deliberately
    # this adapter's own tracked file instead of the whole worktree, so another
    # member's in-progress edit cannot fail this suite.
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            [void](& git -C $SourceRoot diff --check -- tests/adapters/deepseek-harness 2>&1)
            $diffCheckCode = $LASTEXITCODE
            $global:LASTEXITCODE = 0
        } finally {
            $ErrorActionPreference = $previous
        }
        Assert-True ($diffCheckCode -eq 0) 'git diff --check reports no whitespace errors in the DeepSeek Harness test paths'

        # The suite's own files must be tracked, not merely present: an untracked
        # adapter test is invisible to `diff --check` and would silently reduce
        # this gate to a no-op.
        try {
            $ErrorActionPreference = 'Continue'
            $trackedOutput = & git -C $SourceRoot ls-files -- tests/adapters/deepseek-harness 2>&1
            $global:LASTEXITCODE = 0
        } finally {
            $ErrorActionPreference = $previous
        }
        $trackedSelf = @($trackedOutput | Where-Object { [string]$_ -match 'Test-DeepSeekHarnessAdapter\.ps1$' })
        if ($trackedSelf.Count -eq 0) {
            Write-Host 'NOTE this suite is untracked in the current development phase, so its whitespace scope covers nothing yet'
        }
    } else {
        Write-Host 'SKIP git checks: git is unavailable'
    }

    # 18d. the shared-worktree decoupling itself is asserted, not assumed: with no
    # caller-supplied baseline the gate must SKIP rather than infer a verdict from
    # the dirty tree, so a future edit cannot quietly reintroduce the whole-tree
    # scan that failed for every delivery touching a shared layer.
    $baselineParameter = $OwnershipBaselinePath
    $baselineEnvironment = $env:BIM_BRIDGE_DSH_OWNERSHIP_BASELINE
    try {
        $OwnershipBaselinePath = $null
        $env:BIM_BRIDGE_DSH_OWNERSHIP_BASELINE = $null
        $defaultOwnership = Test-OwnershipBaseline
    } finally {
        $OwnershipBaselinePath = $baselineParameter
        $env:BIM_BRIDGE_DSH_OWNERSHIP_BASELINE = $baselineEnvironment
    }
    Assert-True ([bool]$defaultOwnership.Skipped) 'Ownership gate SKIPs by default instead of scanning the dirty worktree'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'tests\adapters\deepseek-harness\ownership-baseline-default.txt'))) 'No implicit default baseline file is consulted'

    # 18e. negative control for the index-column classification above. The staged
    # addition this gate used to fail on is an *addition*, so it must be ignored;
    # an unstaged modification of the same file must still be detected. Both halves
    # are asserted against a throwaway repository under the system temp directory,
    # so the real working tree, its history and its index are never touched.
    $negativeControl = Join-Path ([IO.Path]::GetTempPath()) ("dsh-ownership-negative-" + [Guid]::NewGuid().ToString('N'))
    try {
        $probeGit = Resolve-GitCommand
        Assert-True ([bool]$probeGit) 'git is resolvable for the ownership negative control'
        $probeRoot = Join-Path $negativeControl 'probe'
        New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
        # One path per call: `New-Item -Path A, B` binds the comma-separated value
        # as a single literal path and silently creates neither directory, which is
        # exactly how this probe first produced `fatal: not a git repository`.
        Set-Content -LiteralPath (Join-Path $negativeControl 'probe-marker.txt') -Value $negativeControl -Encoding ASCII
        $probeFile = Join-Path $probeRoot 'eng\Probe.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $probeFile) | Out-Null
        Set-Content -LiteralPath $probeFile -Value '# probe' -Encoding ASCII
        $probeSteps = @(
            @('init', @('-C', $probeRoot, 'init', '--quiet')),
            @('config-email', @('-C', $probeRoot, 'config', 'user.email', 'probe@example.invalid')),
            @('config-name', @('-C', $probeRoot, 'config', 'user.name', 'probe')),
            @('add', @('-C', $probeRoot, 'add', '--', 'eng/Probe.ps1')),
            @('commit', @('-C', $probeRoot, 'commit', '--quiet', '-m', 'probe baseline'))
        )
        foreach ($probeStep in $probeSteps) {
            $stepOutput = & $probeGit @($probeStep[1]) 2>&1
            $stepCode = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            Assert-True ($stepCode -eq 0) "Negative-control repository step '$($probeStep[0])' succeeded (exit $stepCode; output: $(@($stepOutput) -join ' | '))"
        }
        # (a) unstaged modification -> detected
        Set-Content -LiteralPath $probeFile -Value '# probe modified' -Encoding ASCII
        $detectedModified = @(Get-SharedLayerWorktreePaths $probeRoot)
        Assert-True ($detectedModified -contains 'eng/Probe.ps1') 'Ownership gate detects an unstaged modification of a shared-layer path'
        # (b) staged addition of a *different* shared-layer path -> ignored, exactly
        # like an untracked addition, so `git add`-ing this phase's own new files
        # cannot fail the gate.
        $stagedProbe = Join-Path $probeRoot 'eng\StagedProbe.ps1'
        Set-Content -LiteralPath $stagedProbe -Value '# staged probe' -Encoding ASCII
        $addOutput = & $probeGit -C $probeRoot add -- eng/StagedProbe.ps1 2>&1
        $addCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Assert-True ($addCode -eq 0) "Negative-control staged addition succeeded (exit $addCode; output: $(@($addOutput) -join ' | '))"
        $detectedStaged = @(Get-SharedLayerWorktreePaths $probeRoot)
        Assert-True (-not ($detectedStaged -contains 'eng/StagedProbe.ps1')) 'Ownership gate ignores a staged addition of a shared-layer path'
        Assert-True ($detectedStaged -contains 'eng/Probe.ps1') 'Ownership gate still detects the unstaged modification alongside a staged addition'
        # (c) the real working tree must be untouched by the probe
        $realStatus = @(Get-SharedLayerWorktreePaths $SourceRoot)
        Assert-True (-not ($realStatus -contains 'eng/Probe.ps1')) 'Negative-control probe left no trace in the real working tree'
    } finally {
        if (Test-Path -LiteralPath $negativeControl) {
            $resolvedNegative = [IO.Path]::GetFullPath($negativeControl)
            $resolvedTemp = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()).TrimEnd('\')) + [IO.Path]::DirectorySeparatorChar
            if ($resolvedNegative.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
                (Split-Path -Leaf $resolvedNegative) -like 'dsh-ownership-negative-*') {
                Remove-Item -LiteralPath $resolvedNegative -Recurse -Force
            }
        }
    }

    # 19. MCP protocol surface of the delegated server
    # The launcher must not interleave anything of its own into the MCP stream, and
    # the delegated Host is the only thing that may write to stdout.
    $outPath = Join-Path $temporaryRoot 'stream-stdout.txt'
    $errPath = Join-Path $temporaryRoot 'stream-stderr.txt'
    $exitCode = Invoke-LauncherRaw -StateRoot $temporaryRoot -StdOutPath $outPath -StdErrPath $errPath
    $lines = @((Read-TextOrEmpty $outPath) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    Assert-True ($lines.Count -eq 1) "Delegated Host stdout carries only the Host's own output (got $($lines.Count) lines)"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "DeepSeek Harness adapter: $passed passed, $($failed.Count) failed"
if ($failed.Count -gt 0) {
    foreach ($name in $failed) { Write-Host "  FAILED: $name" }
    exit 1
}
exit 0
