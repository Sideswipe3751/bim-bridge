Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1')

function Convert-AutoCADRuntimeTfmToTargetFramework([string]$RuntimeTfm, [string]$RuntimeConfigPath) {
    switch -Regex ($RuntimeTfm) {
        '^net8(\.0)?$' { return 'net8.0-windows' }
        '^net10(\.0)?$' { return 'net10.0-windows' }
        default { throw "Unsupported installed AutoCAD API runtime '$RuntimeTfm' at $RuntimeConfigPath" }
    }
}

function Get-AutoCADMatrixEntries([string]$MatrixPath) {
    [xml]$matrix = Get-Content -LiteralPath $MatrixPath -Raw
    @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup } |
        Where-Object { $_.PSObject.Properties['AutoCADReleaseYear'] -and -not [string]::IsNullOrWhiteSpace([string]$_.AutoCADReleaseYear) } |
        ForEach-Object {
        [pscustomobject]@{
            Include = [string]$_.AutoCADReleaseYear
            AssemblyName = [string]$_.AutoCADAssemblyName
            TargetFramework = [string]$_.AutoCADTargetFramework
            SupportedTargetFrameworks = [string]$_.AutoCADSupportedTargetFrameworks
            CertifiedTargetFrameworks = [string]$_.AutoCADCertifiedTargetFrameworks
            RuntimeFamily = [string]$_.AutoCADRuntimeFamily
            RuntimeResolution = [string]$_.AutoCADRuntimeResolution
            DynamicCompiler = [string]$_.AutoCADDynamicCompiler
            Series = [string]$_.AutoCADSeries
            SupportStatus = [string]$_.AutoCADSupportStatus
            CertificationStatus = [string]$_.AutoCADCertificationStatus
            InstallSubdirectory = [string]$_.AutoCADInstallSubdirectory
        }
    })
}

function Resolve-AutoCADMatrixEntry(
    [object]$Release,
    [string]$ProgramFilesPath = $env:ProgramFiles,
    [string]$InstallDirectory,
    [switch]$RequireCertified
) {
    if (-not $InstallDirectory) { $InstallDirectory = Join-Path $ProgramFilesPath ([string]$Release.InstallSubdirectory) }
    $installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
    $runtimeConfigPath = Join-Path $installDirectory 'acdbmgd.runtimeconfig.json'
    $targetFramework = [string]$Release.TargetFramework
    $detectedRuntime = $null

    if ($Release.RuntimeResolution -eq 'installed-api-runtime') {
        if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
            throw "Installed AutoCAD API runtime metadata was not found: $runtimeConfigPath"
        }
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
        $detectedRuntime = [string]$runtimeConfig.runtimeOptions.tfm
        $targetFramework = Convert-AutoCADRuntimeTfmToTargetFramework $detectedRuntime $runtimeConfigPath
    } elseif ($Release.RuntimeResolution -ne 'fixed') {
        throw "Unknown AutoCAD runtime resolution policy '$($Release.RuntimeResolution)' for $($Release.Include)."
    } elseif ($Release.RuntimeFamily -eq 'modern') {
        if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
            throw "Installed AutoCAD API runtime metadata was not found: $runtimeConfigPath"
        }
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
        $detectedRuntime = [string]$runtimeConfig.runtimeOptions.tfm
        $installedTarget = Convert-AutoCADRuntimeTfmToTargetFramework $detectedRuntime $runtimeConfigPath
        if ($installedTarget -ne $targetFramework) {
            throw "AutoCAD $($Release.Include) declares $targetFramework but the installed API requires $installedTarget."
        }
    }

    $supported = @(([string]$Release.SupportedTargetFrameworks).Split(';', [StringSplitOptions]::RemoveEmptyEntries))
    if ($supported -notcontains $targetFramework) {
        throw "AutoCAD $($Release.Include) resolved to $targetFramework, which is outside its declared supported target frameworks."
    }
    $certifiedValue = if ($Release.PSObject.Properties['CertifiedTargetFrameworks']) { [string]$Release.CertifiedTargetFrameworks } else { '' }
    $certified = @($certifiedValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries))
    if ($RequireCertified -and
        ([string]$Release.CertificationStatus -ne 'certified' -or $certified -notcontains $targetFramework)) {
        $available = if ($certified.Count -gt 0) { $certified -join ', ' } else { 'none' }
        throw "AutoCAD $($Release.Include) target framework $targetFramework is not certified for this BIM Bridge release. Certified target frameworks: $available."
    }

    [pscustomobject]@{
        Include = [string]$Release.Include
        AssemblyName = [string]$Release.AssemblyName
        TargetFramework = $targetFramework
        DeclaredTargetFramework = [string]$Release.TargetFramework
        SupportedTargetFrameworks = $supported
        CertifiedTargetFrameworks = $certified
        DetectedRuntime = $detectedRuntime
        RuntimeFamily = [string]$Release.RuntimeFamily
        RuntimeResolution = [string]$Release.RuntimeResolution
        DynamicCompiler = [string]$Release.DynamicCompiler
        Series = [string]$Release.Series
        SupportStatus = [string]$Release.SupportStatus
        CertificationStatus = [string]$Release.CertificationStatus
        InstallDirectory = $installDirectory
        ApiPath = Join-Path $installDirectory 'AcCoreMgd.dll'
        Executable = Join-Path $installDirectory 'acad.exe'
    }
}

function New-AutoCADPackageContents(
    [object[]]$Releases,
    [string]$AppVersion = '2.0.0',
    [string]$TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\BimBridge.AutoCAD\PackageContents.template.xml'),
    [string]$ModuleDirectorySuffix = 'Contents\Windows'
) {
    if (-not $Releases -or $Releases.Count -eq 0) {
        throw 'At least one resolved AutoCAD matrix entry is required.'
    }
    # The module directory is a package-internal relative path. A rooted path, a
    # `..` segment, or an empty segment would move the declared module outside
    # the bundle the manifest describes, so anything but a plain relative
    # directory chain is refused before a single component is rendered.
    if ([string]::IsNullOrWhiteSpace($ModuleDirectorySuffix)) {
        throw 'The AutoCAD bundle module directory is required.'
    }
    if ([IO.Path]::IsPathRooted($ModuleDirectorySuffix)) {
        throw "The AutoCAD bundle module directory must be a relative path inside the bundle: $ModuleDirectorySuffix"
    }
    $segments = @([string]$ModuleDirectorySuffix -split '[\\/]' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) {
        throw "The AutoCAD bundle module directory must name at least one relative directory: $ModuleDirectorySuffix"
    }
    foreach ($segment in $segments) {
        if ($segment -eq '..') {
            throw "The AutoCAD bundle module directory must not escape the bundle with a '..' segment: $ModuleDirectorySuffix"
        }
        if ($segment -eq '.') {
            throw "The AutoCAD bundle module directory must not contain a '.' segment: $ModuleDirectorySuffix"
        }
    }
    $moduleRoot = ($segments -join '/')
    $components = @($Releases | ForEach-Object {
        $series = [Security.SecurityElement]::Escape([string]$_.Series)
        $year = [Security.SecurityElement]::Escape([string]$_.Include)
        $assembly = [Security.SecurityElement]::Escape([string]$_.AssemblyName)
        $modulePath = [Security.SecurityElement]::Escape("./$moduleRoot/$year/$assembly.dll")
@"
  <Components Description="AutoCAD $year">
    <RuntimeRequirements OS="Win64" Platform="AutoCAD*" SeriesMin="$series" SeriesMax="$series" />
    <ComponentEntry AppName="BIM Bridge" Version="$([Security.SecurityElement]::Escape($AppVersion))" ModuleName="$modulePath" AppDescription="BIM Bridge local AutoCAD connector" LoadReasons="LoadOnAutoCADStartup" />
  </Components>
"@
    }) -join [Environment]::NewLine
    (Get-Content -LiteralPath $TemplatePath -Raw).
        Replace('{{APP_VERSION}}', [Security.SecurityElement]::Escape($AppVersion)).
        Replace('{{COMPONENTS}}', $components.TrimEnd())
}
