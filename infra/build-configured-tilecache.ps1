# Submit tile-cache jobs from the main MapLibre frontend's runtime config.
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "frontend\public\config.json"),
    [string]$AwsConfigFile = (Join-Path $PSScriptRoot ".env"),
    [string[]]$Layer = @(),
    [string]$Version = "",
    [switch]$DryRun,
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) { throw "Frontend config not found: $ConfigPath" }
if (-not (Test-Path $AwsConfigFile) -and -not $ListOnly) { throw "AWS deployment config not found: $AwsConfigFile" }
if ($Version -and $Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    throw "Version may contain only letters, digits, dots, underscores, and hyphens."
}

try { $config = Get-Content -Raw $ConfigPath | ConvertFrom-Json }
catch { throw "Frontend config must contain valid JSON: $ConfigPath`n$($_.Exception.Message)" }

if (-not $config.layers -or @($config.layers).Count -eq 0) {
    throw "Frontend config must contain a non-empty layers array."
}
$duplicateIds = @($config.layers | Group-Object id | Where-Object Count -gt 1 | ForEach-Object Name)
if ($duplicateIds.Count -gt 0) { throw "Frontend config contains duplicate layer IDs: $($duplicateIds -join ', ')" }

$schema = if ($config.tileCache.schema) { [string]$config.tileCache.schema } else { "public" }
if ($schema -notmatch '^[A-Za-z_][A-Za-z0-9_$]*$') { throw "tileCache.schema must be a simple PostgreSQL identifier." }
$prefix = if ($config.tileCache.prefix) { ([string]$config.tileCache.prefix).Trim('/') } else { "tiles" }
if ($prefix -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$') { throw "tileCache.prefix must contain valid path segments." }
if ($config.tileCache.baseUrl) {
    $cacheUri = $null
    if (-not [Uri]::TryCreate([string]$config.tileCache.baseUrl, [UriKind]::Absolute, [ref]$cacheUri) -or
        $cacheUri.Scheme -ne "https" -or $cacheUri.UserInfo -or $cacheUri.Query -or $cacheUri.Fragment) {
        throw "tileCache.baseUrl must be an HTTPS origin without credentials, query, or fragment."
    }
}

$enabledLayers = @($config.layers | Where-Object { $_.cache -and $_.cache.enabled -eq $true })
if ($Layer.Count -gt 0) {
    $unknown = @($Layer | Where-Object { $_ -notin @($config.layers.id) })
    if ($unknown.Count -gt 0) { throw "Requested layers are not present in frontend config: $($unknown -join ', ')" }
    $disabled = @($Layer | Where-Object { $_ -notin @($enabledLayers.id) })
    if ($disabled.Count -gt 0) { throw "Requested layers are not cache-enabled in frontend config: $($disabled -join ', ')" }
    $enabledLayers = @($enabledLayers | Where-Object { $_.id -in $Layer })
}
if ($enabledLayers.Count -eq 0) { throw "No cache-enabled layers were selected from frontend config." }

$builds = @(foreach ($item in $enabledLayers) {
    if ([string]$item.id -notmatch '^[A-Za-z_][A-Za-z0-9_$]*$') {
        throw "Layer ID '$($item.id)' must be a simple PostgreSQL identifier."
    }
    $grid = if ($item.cache.grid) { [string]$item.cache.grid } else { "webmercator" }
    if ($grid -ne "webmercator") { throw "Main MapLibre layer '$($item.id)' cache grid must be webmercator." }
    $minZoom = if ($null -ne $item.cache.minZoom) { [int]$item.cache.minZoom } else { 0 }
    $maxZoom = if ($null -ne $item.cache.maxZoom) { [int]$item.cache.maxZoom } else { 12 }
    $gridMaximum = if ($grid -eq "vicgrid") { 13 } else { 22 }
    if ($minZoom -lt 0 -or $maxZoom -lt $minZoom -or $maxZoom -gt $gridMaximum) {
        throw "Layer '$($item.id)' cache zooms must satisfy 0 <= minZoom <= maxZoom <= $gridMaximum."
    }
    $fields = if ($item.cache.fields) { [string]$item.cache.fields } else { "*" }
    if ($fields -notmatch '^\*$|^[A-Za-z_][A-Za-z0-9_$]*(,[A-Za-z_][A-Za-z0-9_$]*)*$') {
        throw "Layer '$($item.id)' cache fields must be '*' or comma-separated simple column names."
    }
    [PSCustomObject]@{
        Layer = [string]$item.id
        Schema = $schema
        Prefix = $prefix
        Grid = $grid
        MinZoom = $minZoom
        MaxZoom = $maxZoom
        Fields = $fields
    }
})

Write-Host "Cache-enabled builds from $ConfigPath"
$builds | Format-Table Layer, Schema, Prefix, Grid, MinZoom, MaxZoom, Fields -AutoSize
if ($ListOnly) { return }

$submitScript = Join-Path $PSScriptRoot "submit-tilecache.ps1"
if (-not (Test-Path $submitScript)) { throw "Submission helper not found: $submitScript" }
Write-Host "Submitting $($builds.Count) AWS Batch job(s)..."
foreach ($build in $builds) {
    $arguments = @{
        Layer = $build.Layer
        Schema = $build.Schema
        Prefix = $build.Prefix
        Grid = $build.Grid
        MinZoom = $build.MinZoom
        MaxZoom = $build.MaxZoom
        Fields = $build.Fields
        ConfigFile = $AwsConfigFile
        DryRun = $DryRun
    }
    if ($Version) { $arguments.Version = $Version }
    & $submitScript @arguments
    if (-not $?) { throw "Failed to submit cache build for '$($build.Layer)'." }
}
