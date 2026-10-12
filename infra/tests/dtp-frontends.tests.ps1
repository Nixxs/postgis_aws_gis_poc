# Offline orchestration tests: no AWS, config writes, builds or HTTP requests.
$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $infraRoot 'deploy-dtp.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'DTP orchestrator contains syntax errors.' }
$rootLiteral = "'" + $infraRoot.Replace("'", "''") + "'"
foreach ($name in @('Assert-Configured', 'Get-OutputUrl', 'Get-FrontendRuntimeConfigPaths', 'Invoke-ApplicationPhase', 'Invoke-TileCachePhase', 'Invoke-VerifyPhase')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression ($definition.Extent.Text.Replace('$PSScriptRoot', $rootLiteral))
}
$ConfigFile = 'offline-config'
$Phase = 'Application'
$SkipTileBuild = $false
$script:settings = @{
    AWS_PROFILE = 'offline'; AWS_ACCOUNT_ID = '376640768813'
    DB_HOST = 'offline'; DB_PASSWORD = 'offline'; DB_NAME = 'gis'
    API_EXECUTION_ROLE_ARN = 'offline'; API_TASK_ROLE_ARN = 'offline'
    TILECACHE_EXECUTION_ROLE_ARN = 'offline'; TILECACHE_JOB_ROLE_ARN = 'offline'
    FRONTEND_URL = 'https://ol.example.test'; FRONTEND_OL_URL = 'https://ol.example.test'
    FRONTEND_OL_API_URL = 'https://api.example.test'
}
$script:calls = [System.Collections.Generic.List[object]]::new()
function Import-DotEnv([string]$Path) { return $script:settings }
function Set-DotEnvValue([string]$Path, [string]$Name, [string]$Value) { $script:settings[$Name] = $Value }
function Test-Api([hashtable]$Settings, [switch]$RequireLayers) { return $script:databaseLayers }
function Invoke-Deployment([string]$Script, [hashtable]$Parameters = @{}) {
    $name = Split-Path $Script -Leaf
    $script:calls.Add(@{ Name = $name; Parameters = $Parameters.Clone(); Origins = @($script:settings.FRONTEND_URL, $script:settings.FRONTEND_OL_URL) })
    switch ($name) {
        'deploy-api.ps1' { return 'Deployment complete: https://api.example.test' }
        'deploy-frontend.ps1' { return 'Frontend deployment complete: https://maplibre.example.test' }
        'deploy-frontend-ol.ps1' { return 'OpenLayers deployment complete: https://ol.example.test' }
        'deploy-tilecache-cdn.ps1' { return 'Tile CDN deployment complete: https://tiles.example.test' }
        default { return 'Offline deployment completed' }
    }
}
Invoke-ApplicationPhase
if (($script:calls.Name -join ',') -ne 'deploy-api.ps1,deploy-frontend.ps1,deploy-frontend-ol.ps1,deploy-api.ps1') { throw 'Application deployment order is incorrect.' }
if ($script:settings.FRONTEND_URL -ne 'https://maplibre.example.test' -or $script:settings.FRONTEND_OL_URL -ne 'https://ol.example.test') { throw 'Frontend origins were mixed or overwritten.' }
if ($script:settings.FRONTEND_API_URL -ne 'https://api.example.test' -or $script:settings.FRONTEND_OL_API_URL -ne 'https://api.example.test') { throw 'Both frontends must receive the shared API URL.' }
$initialApi = $script:calls[0]
$finalApi = $script:calls[3]
if (-not $finalApi.Parameters.SkipBuild -or $finalApi.Parameters.ImageTag -ne $initialApi.Parameters.ImageTag) { throw 'CORS redeployment must reuse the same API image.' }
if ($finalApi.Origins[0] -ne 'https://maplibre.example.test' -or $finalApi.Origins[1] -ne 'https://ol.example.test') { throw 'CORS redeployment ran before both origins were saved.' }
foreach ($call in $script:calls) { if ($call.Parameters.ConfigFile -ne $ConfigFile) { throw 'Deployment lost the private configuration path.' } }

$runtimePaths = @(Get-FrontendRuntimeConfigPaths)
if ($runtimePaths.Count -ne 2 -or $runtimePaths[0] -ne (Join-Path (Split-Path $infraRoot -Parent) 'frontend\public\config.json') -or $runtimePaths[1] -ne (Join-Path (Split-Path $infraRoot -Parent) 'frontend-ol\public\config.json')) { throw 'Both frontend runtime config paths are required.' }
function Get-Content([switch]$Raw, [string]$Path) {
    if ($Path -eq $runtimePaths[0]) { return '{"layers":[{"id":"maplibre_only","cache":{"enabled":true}}]}' }
    if ($Path -eq $runtimePaths[1]) { return '{"layers":[{"id":"ol_only","cache":{"enabled":true}}]}' }
    throw "Unexpected offline config path: $Path"
}
$script:databaseLayers = @('maplibre_only', 'ol_only')
$script:calls.Clear()
Invoke-TileCachePhase
if (($script:calls.Name -join ',') -ne 'deploy-tilecache.ps1,deploy-tilecache-cdn.ps1,deploy-frontend.ps1,deploy-frontend-ol.ps1,build-configured-tilecache.ps1') { throw 'TileCache must redeploy both frontends and submit both grids.' }
$build = $script:calls[4].Parameters
if (($build.ConfigPath -join ',') -ne ($runtimePaths -join ',') -or $build.AwsConfigFile -ne $ConfigFile) { throw 'Tile builds lost a frontend configuration or AWS settings.' }
if ($script:settings.TILECACHE_CDN_URL -ne 'https://tiles.example.test') { throw 'CDN URL was not saved.' }
$script:databaseLayers = @('ol_only')
$script:calls.Clear()
$caught = $false
try { Invoke-TileCachePhase } catch {
    if ($_.Exception.Message -notmatch 'Missing cache-enabled layers: maplibre_only') { throw }
    $caught = $true
}
if (-not $caught -or $script:calls.Count) { throw 'Missing MapLibre layers must stop provisioning.' }
$script:databaseLayers = @('maplibre_only', 'ol_only')
$SkipTileBuild = $true
Invoke-TileCachePhase
if ($script:calls.Name -contains 'build-configured-tilecache.ps1') { throw 'SkipTileBuild still submitted jobs.' }

$script:httpCalls = [System.Collections.Generic.List[string]]::new()
$script:httpStatus = 200
function Invoke-WebRequest([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec) {
    $script:httpCalls.Add($Uri)
    if (-not $UseBasicParsing) { throw 'Windows PowerShell verification requires basic parsing.' }
    return @{ StatusCode = $script:httpStatus }
}
Invoke-VerifyPhase
if (($script:httpCalls -join ',') -ne 'https://maplibre.example.test,https://ol.example.test') { throw 'Verification must check both frontends.' }
$script:settings.FRONTEND_URL = $script:settings.FRONTEND_OL_URL + '/'
$caught = $false
try { Invoke-VerifyPhase } catch {
    if ($_.Exception.Message -notmatch 'URLs must be distinct') { throw }
    $caught = $true
}
if (-not $caught) { throw 'Duplicate frontend URLs were accepted.' }
$script:settings.FRONTEND_URL = 'https://maplibre.example.test'
$script:httpStatus = 503
$caught = $false
try { Invoke-VerifyPhase } catch {
    if ($_.Exception.Message -notmatch 'FRONTEND_URL returned HTTP 503') { throw }
    $caught = $true
}
if (-not $caught) { throw 'Frontend HTTP failures were accepted.' }
Write-Host 'PASS: distinct frontend origins, shared API image/CORS, both tile projections, import completeness, SkipTileBuild and dual-site verification.'