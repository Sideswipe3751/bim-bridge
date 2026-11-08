[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pluginRoot = Join-Path $repoRoot 'plugins\bim-bridge'
$statusScript = Join-Path $pluginRoot 'scripts\Get-BimBridgeHostStatus.ps1'
$hostInstaller = Join-Path $pluginRoot 'scripts\Install-BimBridgeHost.ps1'
$releaseVerifier = Join-Path $pluginRoot 'scripts\Test-BimBridgeReleaseManifest.ps1'
$productDiscovery = Join-Path $pluginRoot 'scripts\AutodeskProductDiscovery.ps1'
$mainInstaller = Join-Path $repoRoot 'installer\Install-BimBridge.ps1'
$launcher = Join-Path $repoRoot 'installer\Start-BimBridgeMcp.ps1'
$matrixPath = Join-Path $repoRoot 'eng\Autodesk.Versions.props'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-installer-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    & $Body
    Write-Output "PASS $Name"
}

function Invoke-Status(
    [string]$CaseRoot,
    [string]$CodexStart,
    [bool]$McpRegistered = $false,
    [object[]]$RegistryRecords = @(),
    [hashtable]$ProductInstallPathOverrides
) {
    $stateRoot = Join-Path $CaseRoot 'local\BIM Bridge'
    $roaming = Join-Path $CaseRoot 'roaming'
    $local = Join-Path $CaseRoot 'local'
    $programFiles = Join-Path $CaseRoot 'program-files'
    $programFilesX86 = Join-Path $CaseRoot 'program-files-x86'
    New-Item -ItemType Directory -Force -Path $roaming,$local,$programFiles,$programFilesX86 | Out-Null
    $arguments = @{
        StateRoot = $stateRoot
        RoamingRoot = $roaming
        LocalRoot = $local
        ProgramFilesRoot = $programFiles
        ProgramFilesX86Root = $programFilesX86
        CodexMcpRegisteredOverride = $McpRegistered
        RegistryInstallRecords = $RegistryRecords
    }
    if ($CodexStart) { $arguments.CodexStartedAtUtc = $CodexStart }
    if ($ProductInstallPathOverrides) { $arguments.ProductInstallPathOverrides = $ProductInstallPathOverrides }
    (& $statusScript @arguments) | ConvertFrom-Json
}

try {
    Invoke-Test 'new installer scripts parse on Windows PowerShell' {
        foreach ($script in @($statusScript,$hostInstaller,$releaseVerifier,$productDiscovery,$mainInstaller,$launcher)) {
            [void][scriptblock]::Create((Get-Content -LiteralPath $script -Raw))
        }
    }

    Invoke-Test 'plugin and release versions agree' {
        $plugin = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
        $release = Get-Content -LiteralPath (Join-Path $pluginRoot 'release-manifest.json') -Raw | ConvertFrom-Json
        Assert ($plugin.name -eq 'bim-bridge') 'Plugin ID is not bim-bridge.'
        Assert (([string]$plugin.version -replace '\+.*$','') -eq [string]$release.version) 'Plugin and release versions differ.'
        Assert (-not $plugin.PSObject.Properties['mcpServers']) 'The lightweight bootstrap plugin must not own an MCP server.'
    }

    Invoke-Test 'release manifest has a valid detached signature and rejects tampering' {
        . $releaseVerifier
        $manifestPath = Join-Path $pluginRoot 'release-manifest.json'
        $signaturePath = $manifestPath + '.sig'
        $verified = Read-VerifiedBimBridgeReleaseManifest $manifestPath $signaturePath
        Assert ([bool]$verified.published) 'The verified preview release is not published.'
        $tamperedPath = Join-Path $temporaryRoot 'tampered-release-manifest.json'
        $tamperedText = (Get-Content -LiteralPath $manifestPath -Raw).Replace('"channel": "preview"','"channel": "tampered"')
        [IO.File]::WriteAllText($tamperedPath,$tamperedText,[Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { Read-VerifiedBimBridgeReleaseManifest $tamperedPath $signaturePath | Out-Null } catch { $rejected = $true }
        Assert $rejected 'A tampered release manifest passed detached-signature verification.'
    }

    Invoke-Test 'fresh machine reports not_installed' {
        $status = Invoke-Status (Join-Path $temporaryRoot 'fresh')
        Assert ($status.status -eq 'not_installed') "Expected not_installed, received $($status.status)."
    }

    Invoke-Test 'preflight skips an incompatible runtime without blocking compatible products' {
        $caseRoot = Join-Path $temporaryRoot 'uncertified-revit-runtime'
        $install = Join-Path $caseRoot 'program-files\Autodesk\Revit 2026'
        $compatibleInstall = Join-Path $caseRoot 'program-files\Autodesk\Revit 2027'
        New-Item -ItemType Directory -Force -Path $install,$compatibleInstall | Out-Null
        foreach ($path in @(
            (Join-Path $install 'Revit.exe'), (Join-Path $install 'RevitAPI.dll'),
            (Join-Path $compatibleInstall 'Revit.exe'), (Join-Path $compatibleInstall 'RevitAPI.dll')
        )) { New-Item -ItemType File -Force -Path $path | Out-Null }
        [IO.File]::WriteAllText(
            (Join-Path $install 'RevitAPI.runtimeconfig.json'),
            '{"runtimeOptions":{"tfm":"net8.0"}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            (Join-Path $compatibleInstall 'RevitAPI.runtimeconfig.json'),
            '{"runtimeOptions":{"tfm":"net10.0"}}',
            [Text.UTF8Encoding]::new($false))
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'not_installed' -and $status.recommendedAction -eq 'install') "Expected install to remain available, received $($status.status)."
        Assert (@($status.prerequisiteIssues).Count -eq 0) 'An incompatible product was treated as a global prerequisite failure.'
        Assert (@($status.compatibilityIssues | Where-Object { $_ -like '*revit 2026*net8.0-windows*not certified*net10.0-windows*' }).Count -eq 1) 'Preflight did not explain the exact skipped Revit runtime.'
        Assert (@($status.skippedProducts | Where-Object { $_.product -eq 'revit' -and $_.version -eq '2026' }).Count -eq 1) 'Preflight did not return the skipped Revit product.'
        $revit = @($status.products.revit | Where-Object version -eq '2026')[0]
        $compatibleRevit = @($status.products.revit | Where-Object version -eq '2027')[0]
        Assert ($revit.targetFramework -eq 'net8.0-windows' -and -not [bool]$revit.certified) 'Preflight did not return exact runtime certification evidence.'
        Assert ([bool]$compatibleRevit.certified) 'The compatible Revit version was not allowed to continue.'
    }

    Invoke-Test 'shared discovery finds registered Autodesk products at custom paths' {
        . $productDiscovery
        $customInstall = Join-Path $temporaryRoot 'custom-products\Revit 2024'
        New-Item -ItemType Directory -Force -Path $customInstall | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $customInstall 'Revit.exe'),(Join-Path $customInstall 'RevitAPI.dll') | Out-Null
        $records = @([pscustomobject]@{ DisplayName='Revit 2024'; InstallLocation=$customInstall })
        $resolved = Resolve-AutodeskProductInstallation -Product revit -Version 2024 `
            -InstallSubdirectory 'Autodesk\Revit 2024' -ProgramFilesRoots @() -RegistryInstallRecords $records
        Assert ($resolved.InstallDirectory -eq [IO.Path]::GetFullPath($customInstall)) 'The registered custom Revit path was not selected.'
        Assert ($resolved.Source -eq 'registry') 'Custom Revit discovery did not retain registry evidence.'

        $caseRoot = Join-Path $temporaryRoot 'custom-status'
        $status = Invoke-Status $caseRoot $null $false $records
        $revit = @($status.products.revit | Where-Object version -eq '2024')[0]
        Assert ([bool]$revit.installed -and [bool]$revit.certified) 'Status did not recognize certified Revit 2024 at its registered custom path.'
        Assert ($revit.installPath -eq [IO.Path]::GetFullPath($customInstall) -and $revit.detectionSource -eq 'registry') 'Status omitted custom-path discovery evidence.'
    }

    Invoke-Test 'explicit custom product path is validated' {
        . $productDiscovery
        $invalid = Join-Path $temporaryRoot 'invalid-custom-product'
        New-Item -ItemType Directory -Force -Path $invalid | Out-Null
        $rejected = $false
        try {
            Resolve-AutodeskProductInstallation -Product revit -Version 2024 `
                -InstallSubdirectory 'Autodesk\Revit 2024' -ProgramFilesRoots @() `
                -ProductInstallPathOverrides @{ 'revit:2024'=$invalid } -RegistryInstallRecords @() | Out-Null
        } catch { $rejected = $_.Exception.Message -like '*explicit revit 2024 installation path is invalid*' }
        Assert $rejected 'An explicit custom product path without Revit.exe and RevitAPI.dll was accepted.'
    }

    Invoke-Test 'status reports current and legacy descriptor file evidence without credentials' {
        $caseRoot = Join-Path $temporaryRoot 'descriptor-evidence'
        $currentDirectory = Join-Path $caseRoot 'roaming\BIM Bridge\instances'
        $legacyDirectory = Join-Path $caseRoot 'roaming\AEC Codex\instances'
        New-Item -ItemType Directory -Force -Path $currentDirectory,$legacyDirectory | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $currentDirectory 'revit-2024-10588.json'),
            '{"instanceId":"revit-2024-10588","token":"must-not-leak"}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            (Join-Path $legacyDirectory 'revit-2024-legacy.json'),
            '{"token":"legacy-must-not-leak"}',
            [Text.UTF8Encoding]::new($false))

        $status = Invoke-Status $caseRoot
        Assert ($status.connectorDiscovery.current.directory -eq $currentDirectory) 'Status reported the wrong BIM Bridge 2.x descriptor directory.'
        Assert (@($status.connectorDiscovery.current.files | Where-Object name -eq 'revit-2024-10588.json').Count -eq 1) 'Status omitted the current descriptor filename.'
        Assert (@($status.connectorDiscovery.legacy.files | Where-Object name -eq 'revit-2024-legacy.json').Count -eq 1) 'Status omitted legacy fallback evidence.'
        $serialized = $status | ConvertTo-Json -Depth 12
        Assert ($serialized -notmatch 'must-not-leak') 'Status exposed a connector bearer token while reporting descriptor evidence.'
    }

    Invoke-Test 'audit-only state directory is not a partial installation' {
        $caseRoot = Join-Path $temporaryRoot 'audit-only'
        $journal = Join-Path $caseRoot 'local\BIM Bridge\journal'
        New-Item -ItemType Directory -Force -Path $journal | Out-Null
        Set-Content -LiteralPath (Join-Path $journal 'events.jsonl') -Value '{}' -Encoding UTF8
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'not_installed') 'An audit-only directory was treated as a broken install.'
    }

    Invoke-Test 'partial host reports needs_repair' {
        $caseRoot = Join-Path $temporaryRoot 'partial'
        New-Item -ItemType Directory -Force -Path (Join-Path $caseRoot 'local\BIM Bridge\host') | Out-Null
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'needs_repair') 'A partial host did not require repair.'
    }

    Invoke-Test 'unsupported state schema reports needs_repair' {
        $caseRoot = Join-Path $temporaryRoot 'old-schema'
        $stateRoot = Join-Path $caseRoot 'local\BIM Bridge'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        @{ schemaVersion=3; version='2.0.0-alpha.4' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'needs_repair') 'An unsupported state schema was accepted.'
    }

    Invoke-Test 'restart comparison preserves UTC JSON timestamps' {
        $caseRoot = Join-Path $temporaryRoot 'restart-time'
        $stateRoot = Join-Path $caseRoot 'local\BIM Bridge'
        $installedFile = Join-Path $stateRoot 'host\2.0.0-alpha.4\mcp-server\aec_mcp_server.py'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedFile) | Out-Null
        Set-Content -LiteralPath $installedFile -Value 'healthy' -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            schemaVersion=4; version='2.0.0-alpha.4'; installedAtUtc='2026-08-11T20:00:00Z'
            restartRequired=$true; localMcpServer=$installedFile; python=$installedFile; launcher=$installedFile
            ownedPaths=@($installedFile); files=@([ordered]@{ path=$installedFile; sha256=$hash })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8

        $restarted = Invoke-Status $caseRoot '2026-08-11T20:01:00Z' $true
        Assert ($restarted.status -eq 'healthy') "Expected healthy after restart, received $($restarted.status)."

        $notRestarted = Invoke-Status $caseRoot '2026-08-11T19:59:00Z' $true
        Assert ($notRestarted.status -eq 'restart_required') "Expected restart_required, received $($notRestarted.status)."
    }

    Invoke-Test 'host installer refuses mutation without approval' {
        $message = $null
        try { & $hostInstaller } catch { $message = $_.Exception.Message }
        Assert ($message -like '*explicit approval*') 'Installer did not enforce explicit approval.'
    }

    Invoke-Test 'matrix exposes only certified current baselines' {
        [xml]$matrix = Get-Content -LiteralPath $matrixPath -Raw
        $revit = @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup } |
            Where-Object { $_.PSObject.Properties['RevitCertificationStatus'] -and $_.RevitCertificationStatus -eq 'certified' })
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $autoCADEntries = @(Get-AutoCADMatrixEntries $matrixPath)
        $autocad = @($autoCADEntries | Where-Object { $_.CertificationStatus -eq 'certified' })
        Assert ($revit.Count -eq 4) "Expected four certified Revit entries, received $($revit.Count)."
        Assert ($autocad.Count -eq 4) "Expected four certified AutoCAD entries, received $($autocad.Count)."
        Assert ($autoCADEntries.Count -eq 4) "Expected four AutoCAD matrix entries, received $($autoCADEntries.Count)."
        foreach ($entry in $revit) {
            Assert ([string]$entry.RevitAssemblyName -eq "BimBridge.Revit$([string]$entry.ReleaseYear)") "Revit $([string]$entry.ReleaseYear) DLL is not BIM Bridge branded."
            Assert (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitCertifiedTargetFrameworks)) "Revit $([string]$entry.ReleaseYear) has no certified target framework."
        }
        foreach ($entry in $autocad) {
            Assert ([string]$entry.AssemblyName -eq "BimBridge.AutoCAD$([string]$entry.Include)") "AutoCAD $([string]$entry.Include) DLL is not BIM Bridge branded."
            Assert (-not [string]::IsNullOrWhiteSpace([string]$entry.CertifiedTargetFrameworks)) "AutoCAD $([string]$entry.Include) has no certified target framework."
        }
        $revit2026 = @($revit | Where-Object ReleaseYear -eq '2026')[0]
        Assert ([string]$revit2026.RevitCertifiedTargetFrameworks -eq 'net10.0-windows') 'Revit 2026 certification is not scoped to its tested .NET 10 runtime.'
    }

    Invoke-Test 'new Autodesk payload contains no AEC Codex assembly identities' {
        $revitProperties = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.Revit\BimBridge.Revit.Adapter.props') -Raw
        $hostProject = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.Host\BimBridge.Host.csproj') -Raw
        $autoCADProject = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.Adapter.props') -Raw
        $autoCADPackage = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml') -Raw
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($revitProperties -match '<AssemblyName>\$\(RevitAssemblyName\)</AssemblyName>') 'Revit assembly identity does not come from the BIM Bridge matrix.'
        Assert ($hostProject -match '<AssemblyName>BimBridge\.Host</AssemblyName>') 'Host bridge DLL is not BIM Bridge branded.'
        Assert ($autoCADProject -match '<AssemblyName>\$\(AutoCADAssemblyName\)</AssemblyName>') 'AutoCAD assembly identity does not come from the BIM Bridge matrix.'
        Assert ($autoCADPackage -match '\{\{COMPONENTS\}\}') 'AutoCAD package is not generated from matrix components.'
        Assert ($installerText -notmatch '"Aec\.Codex\.Revit\$\(\$revit\.Include\)\.dll"') 'BIM Bridge installer still expects an AEC Codex Revit DLL.'
    }

    Invoke-Test 'generic Autodesk matrix helper resolves AutoCAD 2024' {
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $entry = @(Get-AutoCADMatrixEntries $matrixPath | Where-Object { $_.Include -eq '2024' })[0]
        $resolved = Resolve-AutoCADMatrixEntry $entry (Join-Path $temporaryRoot 'matrix-program-files')
        Assert ($resolved.TargetFramework -eq 'net48') 'AutoCAD 2024 target framework was not resolved from the matrix.'
        Assert ($resolved.Executable -like '*Autodesk\AutoCAD 2024\acad.exe') 'AutoCAD executable path was not derived from the matrix.'
    }

    Invoke-Test 'AutoCAD runtime resolver follows installed API metadata' {
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $programFiles = Join-Path $temporaryRoot 'autocad-runtime-program-files'
        $install = Join-Path $programFiles 'Autodesk\AutoCAD 2026'
        New-Item -ItemType Directory -Force -Path $install | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'acdbmgd.runtimeconfig.json'), '{"runtimeOptions":{"tfm":"net10.0"}}', [Text.UTF8Encoding]::new($false))
        $entry = @(Get-AutoCADMatrixEntries $matrixPath | Where-Object { $_.Include -eq '2026' })[0]
        $resolved = Resolve-AutoCADMatrixEntry $entry $programFiles
        Assert ($resolved.TargetFramework -eq 'net10.0-windows') 'AutoCAD 2026 installed .NET 10 runtime was not resolved.'
        Assert ($resolved.DetectedRuntime -eq 'net10.0') 'AutoCAD 2026 runtime evidence was not retained.'
    }

    Invoke-Test 'installer detects installed Autodesk products before runtime resolution' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -match 'Resolve-AutodeskProductInstallation\s+-Product\s+revit') 'Installer does not use shared Revit discovery.'
        Assert ($installerText -match 'Resolve-AutodeskProductInstallation\s+-Product\s+autocad') 'Installer does not use shared AutoCAD discovery.'
        Assert ($installerText -match 'Resolve-RevitMatrixEntry\s+\$entry\s+-InstallDirectory.*-RequireCertified') 'Installer does not resolve the discovered Revit directory through certification.'
        Assert ($installerText -match 'Resolve-AutoCADMatrixEntry\s+\$entry\s+-InstallDirectory.*-RequireCertified') 'Installer does not resolve the discovered AutoCAD directory through certification.'
        Assert ($installerText -match 'Add-SkippedProduct') 'Installer does not record incompatible installed products as skipped.'
        Assert ($installerText -match 'skippedProducts=@\(\$skippedProducts\)') 'Installer result does not expose skipped products.'
        Assert ($installerText -match 'knownRevitManifestPaths') 'Installer does not transactionally remove stale manifests for skipped Revit versions.'
    }

    Invoke-Test 'migration preserves the legacy state root itself' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -notmatch 'Backup-Path\s+\$legacyStateRoot') 'Migration targets the entire legacy state root.'
        Assert ($installerText -match '\$legacyInstallState') 'Migration does not target the known legacy install-state file.'
    }

    Invoke-Test 'MCP registrations participate in rollback' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -match 'previousNewMcp\s*=\s*Get-CodexMcp') 'The previous BIM Bridge MCP registration is not captured.'
        Assert ($installerText -match 'Restore-CodexMcp\s+\$codexCli\s+\$newMcpName\s+\$previousNewMcp') 'The previous BIM Bridge MCP registration is not restored on failure.'
        Assert ($installerText -match 'previousLegacyMcp\s*=\s*Get-CodexMcp') 'The previous legacy MCP registration is not captured.'
    }

    Invoke-Test 'read-only preflight contract is enforced before any read or write' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($mainInstaller, [ref]$null, [ref]$null)

        # Static order: the two guards must be the first statements that can throw, and
        # must precede every CLI/MCP/state/process/ShouldProcess/write statement.
        $guardValidateOnly = $installerText.IndexOf('-ValidateOnly is a read-only preflight')
        $guardOverrides = $installerText.IndexOf('read-only preflight test seams')
        Assert ($guardValidateOnly -gt 0) 'The installer has no ValidateOnly action restriction.'
        Assert ($guardOverrides -gt 0) 'The installer has no override test-seam restriction.'
        foreach ($later in @(
                @{ Pattern = 'Find-CodexCli\r?$'; Name = 'CLI discovery' },
                @{ Pattern = 'previousNewMcp = Get-CodexMcp'; Name = 'MCP read' },
                @{ Pattern = 'Get-Content -LiteralPath \$statePath'; Name = 'install-state read' },
                @{ Pattern = 'Get-Process -Name Revit,acad'; Name = 'running-Autodesk check' },
                @{ Pattern = 'New-Item -ItemType Directory -Force -Path \$stateRoot'; Name = 'state-root write' },
                @{ Pattern = 'Remove-CodexMcp \$codexCli \$newMcpName\r?$'; Name = 'MCP mutation' },
                @{ Pattern = 'Stop-OwnedHostProcesses @\(\$stateRoot\)'; Name = 'process stop' })) {
            $match = [regex]::Match($installerText, $later.Pattern, 'Multiline')
            Assert $match.Success "The installer contract test could not locate $($later.Name)."
            Assert ($guardValidateOnly -lt $match.Index) "The ValidateOnly action restriction is not enforced before $($later.Name)."
            Assert ($guardOverrides -lt $match.Index) "The override restriction is not enforced before $($later.Name)."
        }

        # The preflight must not be reachable for Uninstall at all: the uninstall branch
        # has to come after the guard, and the guard must reject the combination.
        Assert ($installerText -match "if \(\`$ValidateOnly -and \`$Action -notin @\('Install', 'Repair'\)\)") 'The installer does not restrict which actions -ValidateOnly may be combined with.'
        Assert ($installerText -match "\`$overrideSupplied -and \(-not \`$ValidateOnly -or \`$Action -notin @\('Install', 'Repair'\)\)") 'The override seam is not restricted to a permitted read-only preflight.'

        # Both resolutions - preflight and real install - must go through the one helper
        # that applies the trusted-source containment rules.
        Assert ($installerText -match 'function Resolve-PrivatePythonSource') 'The shared private Python resolver is missing.'
        Assert ($installerText -match 'function Test-PathContainedInDirectory') 'The trusted-source containment helper is missing.'
        $resolverCalls = @([regex]::Matches($installerText, 'Resolve-PrivatePythonSource \$SourceRoot \$currentState \$legacyState \$effectiveStateRoot \$effectiveLegacyStateRoot'))
        Assert ($resolverCalls.Count -eq 2) "Expected the preflight and the install path to share the resolver, found $($resolverCalls.Count) call sites."
        Assert (@($installerAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Resolve-PrivatePythonSource'
                    }, $true)).Count -eq 2) 'The resolver is not invoked from exactly two places in the parsed script.'
    }

    Invoke-Test 'repair can reuse the installed private runtime' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        # The install path no longer inlines the fallback chain: it consumes the shared
        # resolver, which is what makes the preflight and the install agree. The check
        # therefore asserts that the current install-state still feeds the resolver,
        # rather than that a specific inline `if` survived.
        Assert ($installerText -match '\$CurrentState\.python') 'The shared resolver does not consume the current install-state private Python.'
        Assert ($installerText -match 'Resolve-PrivatePythonSource \$SourceRoot \$currentState \$legacyState') 'The install path does not resolve the private Python through the shared resolver.'
        Assert ($installerText -match 'Copy-Directory \$pythonSource') 'The installer no longer stages the resolved private Python runtime.'
        Assert ($installerText -match "integrityScope='critical-runtime-and-adapter-files'") 'The installer does not declare its bounded integrity scope.'
        Assert ($installerText -notmatch 'New-FileRecords\s+\$ownedPaths') 'Integrity checks still hash every private runtime file.'
        Assert ($installerText -match 'Remove-StaleTransactionDirectories\s+\$stateRoot') 'Successful repair does not clean safely scoped stale transaction directories.'
        Assert ($installerText -match '\[IO\.Directory\]::EnumerateFiles\(\$extended') 'Transaction cleanup does not support Windows extended-length paths.'
        Assert ($installerText -match "Extension -ne '\.pyc'") 'Mutable Python bytecode is still included in install-state integrity records.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
