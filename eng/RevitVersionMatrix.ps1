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
