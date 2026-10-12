# Orchestrate the DTP deployment in safe, restartable phases.
[CmdletBinding()]
param(
    [ValidateSet("Database", "Import", "Application", "TileCache", "Verify", "All")]
    [string]$Phase = "All",
    [string]$ConfigFile = (Join-Path $PSScriptRoot "dtp.env"),
    [string]$ManifestFile = (Join-Path $PSScriptRoot "import-manifest.json"),
    [switch]$SourceUploaded,
    [switch]$SkipTileBuild
)

$ErrorActionPreference = "Stop"

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "DTP config not found: $Path. Copy infra/dtp.env.example to infra/dtp.env first."
    }
    $result = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) { $result[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'") }
    }
    return $result
}

function Set-DotEnvValue([string]$Path, [string]$Name, [string]$Value) {
    if ($Value -match "[`r`n]") { throw "$Name must be a single-line value." }
    $lines = [System.Collections.Generic.List[string]]@(Get-Content $Path)
    $replacement = "$Name=$Value"
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^\s*$([regex]::Escape($Name))\s*=") {
            $lines[$index] = $replacement
            $found = $true
            break
        }
    }
    if (-not $found) { $lines.Add($replacement) }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-Configured([hashtable]$Settings, [string[]]$Names) {
    foreach ($name in $Names) {
        $value = [string]$Settings[$name]
        if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith("REPLACE_")) {
            throw "Set $name in $ConfigFile before running phase $Phase."
        }
    }
}

function Invoke-Deployment([string]$Script, [hashtable]$Parameters = @{}) {
    Write-Host ""
    Write-Host "Running $([System.IO.Path]::GetFileName($Script))..." -ForegroundColor Cyan
    $output = [System.Collections.Generic.List[string]]::new()
    # Write-Host uses the information stream (6), not stdout. Capture it as
    # well as errors so completion URLs are available to the phase orchestrator.
    & $Script @Parameters 2>&1 6>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
        $text = $_.ToString()
        Write-Host $text
        $output.Add($text)
    }
    $succeeded = $?
    if (-not $succeeded) { throw "$([System.IO.Path]::GetFileName($Script)) failed." }
    return @($output | ForEach-Object { $_.ToString() })
}

function Get-OutputUrl([string[]]$Output, [string]$Label) {
    foreach ($line in $Output) {
        $match = [regex]::Match($line, [regex]::Escape($Label) + '\s*(https://\S+)')
        if ($match.Success) { return $match.Groups[1].Value.TrimEnd('/') }
    }
    throw "Could not find '$Label https://...' in deployment output."
}

function Test-Api([hashtable]$Settings, [switch]$RequireLayers) {
    Assert-Configured $Settings @("FRONTEND_OL_API_URL")
    $apiUrl = $Settings.FRONTEND_OL_API_URL.TrimEnd('/')
    $health = Invoke-RestMethod "$apiUrl/health" -TimeoutSec 30
    if ($health.status -ne "ok") { throw "API health check failed." }
    $ready = Invoke-RestMethod "$apiUrl/ready" -TimeoutSec 30
    if ($ready.status -ne "ready") { throw "API database readiness check failed." }
    $layerResponse = Invoke-RestMethod "$apiUrl/list-layers" -TimeoutSec 60
    $layers = @($layerResponse.layers)
    if ($RequireLayers -and $layers.Count -eq 0) { throw "No PostGIS layers were discovered. Import data before tile-cache deployment." }
    Write-Host "API ready; discovered $($layers.Count) PostGIS layer(s)." -ForegroundColor Green
    return $layers
}

function Invoke-DatabasePhase {
    Invoke-Deployment (Join-Path $PSScriptRoot "provision-rds.ps1") @{ ConfigFile = $ConfigFile } | Out-Null
    Invoke-Deployment (Join-Path $PSScriptRoot "prepare-import-bucket.ps1") @{ ConfigFile = $ConfigFile } | Out-Null
    Write-Host ""
    Write-Host "SOURCE UPLOAD CHECKPOINT" -ForegroundColor Yellow
    Write-Host "1. Copy infra/import-manifest.example.json to infra/import-manifest.json and set the S3 key/layers."
    Write-Host "2. Upload the source archive to the private IMPORT_BUCKET."
    Write-Host "3. Continue with: .\infra\deploy-dtp.ps1 -Phase Import"
    Write-Host "Guide: infra/S3-DATA-IMPORT.md"
}

function Invoke-ImportPhase {
    Invoke-Deployment (Join-Path $PSScriptRoot "import-s3-to-postgis.ps1") @{
        ConfigFile = $ConfigFile
        ManifestFile = $ManifestFile
    } | Out-Null
}

function Invoke-ApplicationPhase {
    $settings = Import-DotEnv $ConfigFile
    Assert-Configured $settings @(
        "AWS_PROFILE", "AWS_ACCOUNT_ID", "DB_HOST", "DB_PASSWORD", "DB_NAME",
        "API_EXECUTION_ROLE_ARN", "API_TASK_ROLE_ARN"
    )
    $imageTag = Get-Date -Format "yyyyMMdd-HHmmss"
    $apiOutput = Invoke-Deployment (Join-Path $PSScriptRoot "deploy-api.ps1") @{
        ConfigFile = $ConfigFile
        ImageTag = $imageTag
    }
    $apiUrl = Get-OutputUrl $apiOutput "Deployment complete:"
    Set-DotEnvValue $ConfigFile "FRONTEND_API_URL" $apiUrl
    Set-DotEnvValue $ConfigFile "FRONTEND_OL_API_URL" $apiUrl

    $mapLibreOutput = Invoke-Deployment (Join-Path $PSScriptRoot "deploy-frontend.ps1") @{
        ConfigFile = $ConfigFile
    }
    $mapLibreUrl = Get-OutputUrl $mapLibreOutput "Frontend deployment complete:"
    Set-DotEnvValue $ConfigFile "FRONTEND_URL" $mapLibreUrl

    $frontendOutput = Invoke-Deployment (Join-Path $PSScriptRoot "deploy-frontend-ol.ps1") @{
        ConfigFile = $ConfigFile
    }
    $frontendUrl = Get-OutputUrl $frontendOutput "OpenLayers deployment complete:"
    Set-DotEnvValue $ConfigFile "FRONTEND_OL_URL" $frontendUrl

    Invoke-Deployment (Join-Path $PSScriptRoot "deploy-api.ps1") @{
        ConfigFile = $ConfigFile
        ImageTag = $imageTag
        SkipBuild = $true
    } | Out-Null

    $settings = Import-DotEnv $ConfigFile
    Test-Api $settings | Out-Null
    Write-Host "MapLibre deployed: $mapLibreUrl" -ForegroundColor Green
    Write-Host "OpenLayers deployed: $frontendUrl" -ForegroundColor Green
}

function Get-FrontendRuntimeConfigPaths {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    return @(
        (Join-Path $repoRoot "frontend\public\config.json"),
        (Join-Path $repoRoot "frontend-ol\public\config.json")
    )
}

function Invoke-TileCachePhase {
    $settings = Import-DotEnv $ConfigFile
    Assert-Configured $settings @(
        "TILECACHE_EXECUTION_ROLE_ARN", "TILECACHE_JOB_ROLE_ARN", "FRONTEND_OL_API_URL"
    )
    $databaseLayers = Test-Api $settings -RequireLayers
    $runtimeConfigPaths = @(Get-FrontendRuntimeConfigPaths)
    $requiredLayers = @(foreach ($runtimeConfigPath in $runtimeConfigPaths) {
        $runtimeConfig = Get-Content -Raw $runtimeConfigPath | ConvertFrom-Json
        $runtimeConfig.layers | Where-Object { $_.cache.enabled -eq $true } | ForEach-Object id
    }) | Select-Object -Unique
    $missingLayers = @($requiredLayers | Where-Object { $_ -notin $databaseLayers })
    if ($missingLayers.Count -gt 0) {
        throw "Database import is incomplete. Missing cache-enabled layers: $($missingLayers -join ', ')"
    }

    Invoke-Deployment (Join-Path $PSScriptRoot "deploy-tilecache.ps1") @{ ConfigFile = $ConfigFile } | Out-Null
    $cdnOutput = Invoke-Deployment (Join-Path $PSScriptRoot "deploy-tilecache-cdn.ps1") @{ ConfigFile = $ConfigFile }
    $cdnUrl = Get-OutputUrl $cdnOutput "Tile CDN deployment complete:"
    Set-DotEnvValue $ConfigFile "TILECACHE_CDN_URL" $cdnUrl

    Invoke-Deployment (Join-Path $PSScriptRoot "deploy-frontend.ps1") @{ ConfigFile = $ConfigFile } | Out-Null
    Invoke-Deployment (Join-Path $PSScriptRoot "deploy-frontend-ol.ps1") @{ ConfigFile = $ConfigFile } | Out-Null
    if (-not $SkipTileBuild) {
        Invoke-Deployment (Join-Path $PSScriptRoot "build-configured-tilecache.ps1") @{
            ConfigPath = $runtimeConfigPaths
            AwsConfigFile = $ConfigFile
        } | Out-Null
        Write-Host "Tile-cache jobs submitted. Monitor AWS Batch until every job succeeds." -ForegroundColor Yellow
    }
    else {
        Write-Host "Tile-cache infrastructure deployed; job submission skipped."
    }
}

function Invoke-VerifyPhase {
    $settings = Import-DotEnv $ConfigFile
    $layers = Test-Api $settings -RequireLayers
    Assert-Configured $settings @("FRONTEND_URL", "FRONTEND_OL_URL")
    if ($settings.FRONTEND_URL.TrimEnd('/') -eq $settings.FRONTEND_OL_URL.TrimEnd('/')) {
        throw "MapLibre and OpenLayers URLs must be distinct. Run the Application phase to deploy both frontends."
    }
    foreach ($name in @("FRONTEND_URL", "FRONTEND_OL_URL")) {
        $frontendResponse = Invoke-WebRequest $settings[$name] -UseBasicParsing -TimeoutSec 60
        if ($frontendResponse.StatusCode -ne 200) { throw "$name returned HTTP $($frontendResponse.StatusCode)." }
        Write-Host "$name HTTP 200: $($settings[$name])" -ForegroundColor Green
    }
    Write-Host "Both frontends HTTP 200; API ready; layers: $($layers -join ', ')" -ForegroundColor Green
}

if ($Phase -in @("Database", "All")) {
    Invoke-DatabasePhase
    if ($Phase -eq "All" -and -not $SourceUploaded) {
        Write-Host ""
        Write-Host "Stopped safely before import/application deployment because -SourceUploaded was not supplied." -ForegroundColor Yellow
        Write-Host "After uploading the manifest object, rerun: .\infra\deploy-dtp.ps1 -Phase All -SourceUploaded"
        return
    }
}
if ($Phase -in @("Import", "All")) { Invoke-ImportPhase }
if ($Phase -in @("Application", "All")) { Invoke-ApplicationPhase }
if ($Phase -in @("TileCache", "All")) { Invoke-TileCachePhase }
if ($Phase -in @("Verify", "All")) { Invoke-VerifyPhase }
