[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdapterDirectory,
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$adapter = [IO.Path]::GetFullPath($AdapterDirectory)
$allowed = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src')).TrimEnd('\') + '\'
if (-not $adapter.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Composer destination must be a repository-local adapter build directory.'
}
$project = Join-Path $repositoryRoot 'src\BimBridge.LayeredPdf.Composer\BimBridge.LayeredPdf.Composer.csproj'
$arguments = @('publish', $project, '-c', $Configuration, '-r', 'win-x64', '--self-contained', 'true',
    '-o', (Join-Path $adapter 'Composer'), '-m:1', '-nodeReuse:false', '--nologo', '-v:q')
if ($Offline) { $arguments += '-p:NuGetAudit=false' }
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw 'BIM Bridge PDF composer publish failed.' }
