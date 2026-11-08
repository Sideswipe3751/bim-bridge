Set-StrictMode -Version 2.0

# The BIM Bridge add-in identity is one constant for every supported Revit
# release. Revit keeps a distinct add-in registry per release year, and the live
# acceptance entry point locates the production manifest of the year under test
# by this ID, so it deliberately is not a per-year matrix value.
$script:RevitAddInId = '66E6F0BE-A5B5-49D8-A543-EBF53885A58D'
$script:RevitContextName = 'BIM.Bridge'

function Get-RevitAddInId { return $script:RevitAddInId }

function Convert-RevitRuntimeTfmToTargetFramework([string]$RuntimeTfm, [string]$RuntimeConfigPath) {
    switch -Regex ($RuntimeTfm) {
        '^net8(\.0)?$' { return 'net8.0-windows' }
        '^net10(\.0)?$' { return 'net10.0-windows' }
        default { throw "Unsupported installed Revit API runtime '$RuntimeTfm' at $RuntimeConfigPath" }
    }
}

function Get-RevitMatrixEntries([string]$MatrixPath) {
    [xml]$matrix = Get-Content -LiteralPath $MatrixPath -Raw
    @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup } |
        Where-Object { $_.PSObject.Properties['ReleaseYear'] -and -not [string]::IsNullOrWhiteSpace([string]$_.ReleaseYear) } |
        ForEach-Object {
        $properties = $_
        [pscustomobject]@{
            Include = [string]$properties.ReleaseYear
            AssemblyName = [string]$properties.RevitAssemblyName
            ManifestName = [string]$properties.RevitManifestName
            TargetFramework = [string]$properties.RevitTargetFramework
            SupportedTargetFrameworks = [string]$properties.RevitSupportedTargetFrameworks
            CertifiedTargetFrameworks = [string]$properties.RevitCertifiedTargetFrameworks
            RuntimeFamily = [string]$properties.RevitRuntimeFamily
            RuntimeResolution = [string]$properties.RevitRuntimeResolution
            DynamicCompiler = [string]$properties.RevitDynamicCompiler
            UseRevitContext = [string]$properties.RevitUseRevitContext
            ProviderAvailable = [string]$properties.RevitProviderAvailable
            SupportStatus = [string]$properties.RevitSupportStatus
            CertificationStatus = [string]$properties.RevitCertificationStatus
            InstallSubdirectory = [string]$properties.RevitInstallSubdirectory
            DefaultTemplateSubdirectory = [string]$properties.RevitDefaultTemplateSubdirectory
        }
    })
}

function Get-RevitRequestedYears([string[]]$RequestedVersion) {
    # `-Version 2024,2025` reaches a `-File` invocation as one comma-separated
    # token, so every requested value is tokenized before matrix lookup. The
    # release list itself is never hard-coded here; it is validated against
    # eng/Autodesk.Versions.props by the caller.
    $years = New-Object System.Collections.ArrayList
    foreach ($value in @($RequestedVersion)) {
        foreach ($token in ([string]$value -split '[,;]')) {
            $trimmed = $token.Trim()
            if ($trimmed) { [void]$years.Add($trimmed) }
        }
    }
    @($years)
}

function Resolve-RevitMatrixEntry(
    [object]$Release,
    [string]$ProgramFilesPath = $env:ProgramFiles,
    [string]$ProgramDataPath = $env:ProgramData,
    [string]$InstallDirectory,
    [switch]$RequireCertified
) {
    if (-not $InstallDirectory) { $InstallDirectory = Join-Path $ProgramFilesPath $Release.InstallSubdirectory }
    $installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
    $apiPath = Join-Path $installDirectory 'RevitAPI.dll'
    $runtimeConfigPath = Join-Path $installDirectory 'RevitAPI.runtimeconfig.json'
    $targetFramework = [string]$Release.TargetFramework
    $detectedRuntime = $null

    if ($Release.RuntimeResolution -eq 'installed-api-runtime') {
        if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
            throw "Installed Revit API runtime metadata was not found: $runtimeConfigPath"
        }
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
        $detectedRuntime = [string]$runtimeConfig.runtimeOptions.tfm
        $targetFramework = Convert-RevitRuntimeTfmToTargetFramework $detectedRuntime $runtimeConfigPath
    } elseif ($Release.RuntimeResolution -ne 'fixed') {
        throw "Unknown Revit runtime resolution policy '$($Release.RuntimeResolution)' for $($Release.Include)."
    } elseif ($Release.RuntimeFamily -eq 'modern') {
        if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
            throw "Installed Revit API runtime metadata was not found: $runtimeConfigPath"
        }
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
        $detectedRuntime = [string]$runtimeConfig.runtimeOptions.tfm
        $installedTarget = Convert-RevitRuntimeTfmToTargetFramework $detectedRuntime $runtimeConfigPath
        if ($installedTarget -ne $targetFramework) {
            throw "Revit $($Release.Include) declares $targetFramework but the installed API requires $installedTarget."
        }
    }

    $supported = @(([string]$Release.SupportedTargetFrameworks).Split(';', [StringSplitOptions]::RemoveEmptyEntries))
    if ($supported -notcontains $targetFramework) {
        throw "Revit $($Release.Include) resolved to $targetFramework, which is outside its declared supported target frameworks."
    }
    $certifiedValue = if ($Release.PSObject.Properties['CertifiedTargetFrameworks']) { [string]$Release.CertifiedTargetFrameworks } else { '' }
    $certified = @($certifiedValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries))
    if ($RequireCertified -and
        ([string]$Release.CertificationStatus -ne 'certified' -or $certified -notcontains $targetFramework)) {
        $available = if ($certified.Count -gt 0) { $certified -join ', ' } else { 'none' }
        throw "Revit $($Release.Include) target framework $targetFramework is not certified for this BIM Bridge release. Certified target frameworks: $available."
    }

    [pscustomobject]@{
        Include = [string]$Release.Include
        AssemblyName = [string]$Release.AssemblyName
        ManifestName = [string]$Release.ManifestName
        TargetFramework = $targetFramework
        DeclaredTargetFramework = [string]$Release.TargetFramework
        SupportedTargetFrameworks = $supported
        CertifiedTargetFrameworks = $certified
        DetectedRuntime = $detectedRuntime
        RuntimeFamily = [string]$Release.RuntimeFamily
        RuntimeResolution = [string]$Release.RuntimeResolution
        DynamicCompiler = [string]$Release.DynamicCompiler
        UseRevitContext = [string]$Release.UseRevitContext
        ProviderAvailable = [string]$Release.ProviderAvailable
        SupportStatus = [string]$Release.SupportStatus
        CertificationStatus = [string]$Release.CertificationStatus
        InstallDirectory = $installDirectory
        ApiPath = $apiPath
        RevitExecutable = Join-Path $installDirectory 'Revit.exe'
        DefaultTemplate = Join-Path $ProgramDataPath $Release.DefaultTemplateSubdirectory
    }
}

function Get-RevitInstalledApiEvidence([object]$ResolvedRelease) {
    # Probes exactly the installed inputs a Revit adapter build needs. A missing
    # product is reported as evidence, never as a silently skipped year.
    $probes = New-Object System.Collections.ArrayList
    foreach ($required in @($ResolvedRelease.ApiPath, (Join-Path $ResolvedRelease.InstallDirectory 'RevitAPIUI.dll'), $ResolvedRelease.RevitExecutable)) {
        [void]$probes.Add([ordered]@{
            path = $required
            exists = [bool](Test-Path -LiteralPath $required -PathType Leaf)
        })
    }
    $runtimeConfig = Join-Path $ResolvedRelease.InstallDirectory 'RevitAPI.runtimeconfig.json'
    if ([string]$ResolvedRelease.RuntimeResolution -eq 'installed-api-runtime' -or [string]$ResolvedRelease.RuntimeFamily -eq 'modern') {
        [void]$probes.Add([ordered]@{
            path = $runtimeConfig
            exists = [bool](Test-Path -LiteralPath $runtimeConfig -PathType Leaf)
        })
    }
    [ordered]@{
        installDirectory = $ResolvedRelease.InstallDirectory
        installDirectoryExists = [bool](Test-Path -LiteralPath $ResolvedRelease.InstallDirectory -PathType Container)
        probes = @($probes)
        installed = -not [bool](@($probes | Where-Object { -not $_.exists }).Count -gt 0)
    }
}

function New-RevitUnavailableGap([object]$ResolvedRelease, [string]$Reason, [string]$BlockedTask) {
    $evidence = Get-RevitInstalledApiEvidence $ResolvedRelease
    $firstMissing = @($evidence.probes | Where-Object { -not $_.exists } | Select-Object -First 1)
    $missing = if ($firstMissing.Count -gt 0) { [string]$firstMissing[0].path } else { [string]$ResolvedRelease.InstallDirectory }
    [ordered]@{
        id = 'revit-' + [string]$ResolvedRelease.Include + '-not-installed'
        year = [string]$ResolvedRelease.Include
        product = 'revit'
        missing = $missing
        expectedPath = $missing
        probeCommand = "Test-Path -LiteralPath '$missing' -PathType Leaf"
        probeEvidence = $evidence
        observed = $Reason
        blockedTask = $BlockedTask
        impact = @([string]$ResolvedRelease.AssemblyName + '.dll', [string]$ResolvedRelease.ManifestName)
        severity = 'blocking'
        fakeSuccess = $false
    }
}

function Get-RevitManifestSettings([object]$ResolvedRelease) {
    # Matrix-declared isolation is rendered for every runtime family that can
    # honour it. Revit 2024 keeps the default .NET Framework load context, which
    # has no add-in dependency isolation, so it receives no ManifestSettings.
    if ([string]$ResolvedRelease.UseRevitContext -ne 'false' -or [string]$ResolvedRelease.RuntimeFamily -eq 'netfx') {
        return ''
    }
    @"
  <ManifestSettings>
    <UseRevitContext>False</UseRevitContext>
    <ContextName>$([Security.SecurityElement]::Escape($script:RevitContextName))</ContextName>
  </ManifestSettings>
"@
}

function New-RevitAddInManifest([object]$ResolvedRelease, [string]$AssemblyPath, [string]$TemplatePath) {
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "The shared Revit add-in template was not found: $TemplatePath"
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($token in @('{{ASSEMBLY_PATH}}', '{{MANIFEST_SETTINGS}}')) {
        if (-not $template.Contains($token)) { throw "The shared Revit add-in template is missing $token." }
    }
    $settings = (Get-RevitManifestSettings $ResolvedRelease).TrimEnd()
    # XML escaping happens only at the interpolation boundary: the assembly path
    # is an absolute path and may legitimately contain `&`, `<`, `>`, or a quote,
    # which would otherwise produce a manifest Revit cannot load.
    ($template.
        Replace('{{ASSEMBLY_PATH}}', [Security.SecurityElement]::Escape([string]$AssemblyPath)).
        Replace('{{MANIFEST_SETTINGS}}', $settings))
}

function Test-RevitAddInManifest([object]$ResolvedRelease, [string]$ManifestPath) {
    # One validation rule set covers built manifests and render-only manifests,
    # so a model-driven render can be checked on a machine that has no Revit.
    $errors = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$errors.Add("Generated manifest is missing: $ManifestPath")
        return [pscustomobject]@{ valid = $false; errors = @($errors) }
    }
    $text = Get-Content -LiteralPath $ManifestPath -Raw
    try { [xml]$manifest = $text } catch {
        [void]$errors.Add("Generated manifest is not well-formed XML: $($_.Exception.Message)")
        return [pscustomobject]@{ valid = $false; errors = @($errors) }
    }
    # XPath is used instead of property access because StrictMode rejects
    # reading a manifest element that is legitimately absent, such as the
    # ManifestSettings block of a default-context release.
    $addIns = @($manifest.SelectNodes('/RevitAddIns/AddIn'))
    if ($addIns.Count -ne 1) { [void]$errors.Add("Expected exactly one AddIn element, found $($addIns.Count).") }
    if ($addIns.Count -ge 1) {
        $addIn = $addIns[0]
        if ([string]$addIn.Type -ne 'Application') { [void]$errors.Add("AddIn Type must be Application, found '$($addIn.Type)'.") }
        if ([string]$addIn.AddInId -ne $script:RevitAddInId) { [void]$errors.Add("AddInId must remain $($script:RevitAddInId), found '$($addIn.AddInId)'.") }
        if ([string]$addIn.FullClassName -ne 'BimBridge.Revit.BimBridgeApplication') { [void]$errors.Add("FullClassName must remain BimBridge.Revit.BimBridgeApplication, found '$($addIn.FullClassName)'.") }
        if ([string]::IsNullOrWhiteSpace([string]$addIn.Assembly)) { [void]$errors.Add('AddIn Assembly must not be empty.') }
        if ([string]$addIn.Name -ne 'BIM Bridge') { [void]$errors.Add("AddIn Name must remain BIM Bridge, found '$($addIn.Name)'.") }
        if ([string]$addIn.VendorId -ne 'BMBR') { [void]$errors.Add("VendorId must remain BMBR, found '$($addIn.VendorId)'.") }
    }
    $settingsTokens = @($manifest.SelectNodes('/RevitAddIns/ManifestSettings'))
    $useRevitContext = $null
    $contextName = $null
    if ($settingsTokens.Count -gt 1) {
        [void]$errors.Add("Expected at most one ManifestSettings element, found $($settingsTokens.Count).")
    } elseif ($settingsTokens.Count -eq 1) {
        $settings = $settingsTokens[0]
        $useRevitContext = [string]$settings.UseRevitContext
        $contextName = [string]$settings.ContextName
        if ($useRevitContext -ne 'False') { [void]$errors.Add("ManifestSettings UseRevitContext must be False, found '$useRevitContext'.") }
        if ($contextName -ne $script:RevitContextName) { [void]$errors.Add("ManifestSettings ContextName must be $($script:RevitContextName), found '$contextName'.") }
    }
    $expectsIsolation = ([string]$ResolvedRelease.UseRevitContext -eq 'false' -and [string]$ResolvedRelease.RuntimeFamily -ne 'netfx')
    if ($expectsIsolation -and $settingsTokens.Count -eq 0) {
        [void]$errors.Add("Revit $($ResolvedRelease.Include) declares UseRevitContext=false but the generated manifest has no ManifestSettings.")
    }
    if (-not $expectsIsolation -and $settingsTokens.Count -gt 0) {
        [void]$errors.Add("Revit $($ResolvedRelease.Include) must not declare add-in dependency isolation but the generated manifest does.")
    }
    [pscustomobject]@{
        valid = ($errors.Count -eq 0)
        errors = @($errors)
        addInId = if ($addIns.Count -ge 1) { [string]$addIns[0].AddInId } else { '' }
        useRevitContext = $useRevitContext
        contextName = $contextName
    }
}
