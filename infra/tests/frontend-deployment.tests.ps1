# Offline helper tests; never execute AWS deployment or npm builds.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'frontend-deployment.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Frontend deployer contains syntax errors.' }
foreach ($name in @('Invoke-FrontendNpm', 'Get-AwsValue', 'New-FrontendBucketConfiguration', 'Get-FrontendDeploymentSettings', 'Update-FrontendRuntimeConfig')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing helper: $name" }
    Invoke-Expression $definition.Extent.Text
}
function npm.cmd {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Write-Output 'Simulated npm stdout'
    Write-Error 'Simulated Vite warning' -ErrorAction Continue
    $global:LASTEXITCODE = $script:npmExit
}
$script:npmExit = 0
Invoke-FrontendNpm @('run', 'build')
if ($ErrorActionPreference -ne 'Stop') { throw 'npm did not restore error preference.' }
$script:npmExit = 1
$caught = $false
try { Invoke-FrontendNpm @('run', 'build') } catch {
    if ($_.Exception.Message -notmatch 'npm command failed.*exit 1.*run build') { throw }
    $caught = $true
}
if (-not $caught -or $ErrorActionPreference -ne 'Stop') { throw 'npm failure handling failed.' }
function Invoke-Aws([string[]]$Arguments) {
    if ($Arguments[-1] -ne 'json') { throw 'Scalar output must be JSON.' }
    return $script:scalarJson
}
$script:scalarJson = '"example.cloudfront.net"'
if ((Get-AwsValue @('test')) -ne 'example.cloudfront.net') { throw 'Scalar parsing failed.' }
$script:scalarJson = 'null'
if ((Get-AwsValue @('test')) -ne '') { throw 'Null parsing failed.' }
foreach ($invalid in @('["None","example"]', '"None\nexample"')) {
    $script:scalarJson = $invalid
    $caught = $false
    try { Get-AwsValue @('test') | Out-Null } catch { $caught = $true }
    if (-not $caught) { throw 'Invalid scalar accepted.' }
}
foreach ($region in @('ap-southeast-2', 'us-east-1')) {
    $document = New-FrontendBucketConfiguration $region
    if ($document.Tags.Count -ne 2 -or
        $document.Tags[0].Key -cne 'lz:CostCenter' -or $document.Tags[0].Value -ne 'PlanningSpatial' -or
        $document.Tags[1].Key -cne 'lz:BackupPlan' -or $document.Tags[1].Value -ne 'Daily') { throw 'Creation tags missing.' }
    if ($region -eq 'us-east-1') {
        if ($document.ContainsKey('LocationConstraint')) { throw 'us-east-1 must omit LocationConstraint.' }
    } elseif ($document.LocationConstraint -ne $region) { throw 'Incorrect LocationConstraint.' }
}
Write-Host 'PASS: npm stderr/exit handling, JSON scalar lookups and mandatory S3 creation tags.'

$account = '123456789012'
$selectionCases = 0
$separationCases = 0
foreach ($frontend in @('MapLibre', 'OpenLayers')) {
    $prefix = if ($frontend -eq 'MapLibre') { 'FRONTEND' } else { 'FRONTEND_OL' }
    $siblingPrefix = if ($frontend -eq 'MapLibre') { 'FRONTEND_OL' } else { 'FRONTEND' }
    $directory = if ($frontend -eq 'MapLibre') { 'frontend' } else { 'frontend-ol' }
    $siblingDirectory = if ($frontend -eq 'MapLibre') { 'frontend-ol' } else { 'frontend' }
    $defaults = Get-FrontendDeploymentSettings -Frontend $frontend -Settings @{} -Account $account
    if ($defaults.Directory -ne $directory -or $defaults.Bucket -ne "gis-postgis-$directory-$account" -or
        $defaults.Comment -ne "gis-postgis-$directory" -or $defaults.OacName -ne "gis-postgis-$directory-oac" -or
        $defaults.UrlSetting -ne "${prefix}_URL" -or $defaults.SiblingUrlSetting -ne "${siblingPrefix}_URL" -or
        $defaults.CompletionLabel -ne $(if ($frontend -eq 'MapLibre') { 'Frontend' } else { 'OpenLayers' })) {
        throw "$frontend default selection failed."
    }
    $selectionCases++
    $config = @{
        "${prefix}_BUCKET" = 'custom-bucket'
        "${prefix}_CLOUDFRONT_COMMENT" = "custom comment's value"
        "${prefix}_OAC_NAME" = 'custom-oac'
        "${prefix}_API_URL" = 'https://api.example.test/'
    }
    $selected = Get-FrontendDeploymentSettings -Frontend $frontend -Settings $config -Account $account
    if ($selected.Bucket -ne 'custom-bucket' -or $selected.Comment -ne "custom comment's value" -or
        $selected.OacName -ne 'custom-oac' -or $selected.ApiUrl -ne 'https://api.example.test/') {
        throw "$frontend configured selection failed."
    }
    $selectionCases++
    foreach ($resource in @('BUCKET', 'CLOUDFRONT_COMMENT', 'OAC_NAME')) {
        foreach ($collision in @('Configured', 'Default')) {
            $siblingValue = switch ($resource) {
                'BUCKET' { "gis-postgis-$siblingDirectory-$account" }
                'CLOUDFRONT_COMMENT' { "gis-postgis-$siblingDirectory" }
                'OAC_NAME' { "gis-postgis-$siblingDirectory-oac" }
            }
            $config = @{}
            if ($collision -eq 'Configured') {
                $siblingValue = 'shared-resource'
                $config["${siblingPrefix}_$resource"] = $siblingValue
            }
            $config["${prefix}_$resource"] = $siblingValue
            $caught = $false
            try { Get-FrontendDeploymentSettings -Frontend $frontend -Settings $config -Account $account | Out-Null }
            catch {
                if ($_.Exception.Message -notmatch 'must differ') { throw }
                $caught = $true
            }
            if (-not $caught) { throw "$frontend accepted a $collision sibling $resource collision." }
            $separationCases++
        }
        # A sibling explicitly pointing at our default is also unsafe.
        $ownDefault = switch ($resource) {
            'BUCKET' { $defaults.Bucket }
            'CLOUDFRONT_COMMENT' { $defaults.Comment }
            'OAC_NAME' { $defaults.OacName }
        }
        $config = @{ "${siblingPrefix}_$resource" = $ownDefault }
        $caught = $false
        try { Get-FrontendDeploymentSettings -Frontend $frontend -Settings $config -Account $account | Out-Null }
        catch {
            if ($_.Exception.Message -notmatch 'must differ') { throw }
            $caught = $true
        }
        if (-not $caught) { throw "$frontend accepted its default being configured for the sibling." }
        $separationCases++
    }
}
$legacy = @{ FRONTEND_OL_API_URL = 'https://legacy-api.example.test' }
if ((Get-FrontendDeploymentSettings MapLibre $legacy $account).ApiUrl -ne $legacy.FRONTEND_OL_API_URL) {
    throw 'MapLibre legacy API fallback failed.'
}
$selectionCases++
$legacy.FRONTEND_API_URL = 'https://maplibre-api.example.test'
if ((Get-FrontendDeploymentSettings MapLibre $legacy $account).ApiUrl -ne $legacy.FRONTEND_API_URL) {
    throw 'MapLibre explicit API must take precedence.'
}
$selectionCases++
if ((Get-FrontendDeploymentSettings OpenLayers $legacy $account).ApiUrl -ne $legacy.FRONTEND_OL_API_URL) {
    throw 'OpenLayers must use its own API setting.'
}
$selectionCases++
if ((Get-FrontendDeploymentSettings OpenLayers @{ FRONTEND_API_URL = 'https://maplibre-api.example.test' } $account).ApiUrl) {
    throw 'OpenLayers must not inherit MapLibre API setting.'
}
$selectionCases++
Write-Host "PASS: $selectionCases frontend setting selections and $separationCases symmetric resource separation cases."

$runtimeCases = 0
foreach ($cdn in @('', 'https://placeholder.invalid', 'https://placeholder.invalid/')) {
    $config = '{"tileCache":{"baseUrl":"https://historical.example.test","fallbackToApi":false},"layers":[]}' | ConvertFrom-Json
    Update-FrontendRuntimeConfig $config $cdn
    if ($config.tileCache.baseUrl -ne 'https://historical.example.test' -or $config.tileCache.fallbackToApi -ne $true) {
        throw 'Bootstrap config must retain historical discovery URL and enable API fallback.'
    }
    $runtimeCases++
}
$config = '{"tileCache":{"baseUrl":"https://historical.example.test","fallbackToApi":false,"prefix":"tiles"},"layers":[]}' | ConvertFrom-Json
Update-FrontendRuntimeConfig $config 'https://tiles.example.test/'
if ($config.tileCache.baseUrl -ne 'https://tiles.example.test' -or $config.tileCache.fallbackToApi -ne $false -or
    $config.tileCache.prefix -ne 'tiles' -or $config.layers.Count -ne 0) { throw 'CDN override changed unrelated runtime settings.' }
$runtimeCases++
foreach ($invalid in @('http://tiles.example.test', 'https://user:password@tiles.example.test',
    'https://tiles.example.test/?query=value', 'https://tiles.example.test/#fragment', 'not-a-url')) {
    $caught = $false
    try { Update-FrontendRuntimeConfig $config $invalid } catch {
        if ($_.Exception.Message -notmatch 'TILECACHE_CDN_URL must be') { throw }
        $caught = $true
    }
    if (-not $caught) { throw "Invalid CDN accepted: $invalid" }
    $runtimeCases++
}
$caught = $false
try { Update-FrontendRuntimeConfig ([pscustomobject]@{ layers = @() }) 'https://tiles.example.test' }
catch {
    if ($_.Exception.Message -notmatch 'must contain tileCache') { throw }
    $caught = $true
}
if (-not $caught) { throw 'CDN override accepted missing tileCache settings.' }
$runtimeCases++
$config = '{"tileCache":{"baseUrl":"https://historical.example.test"}}' | ConvertFrom-Json
Update-FrontendRuntimeConfig $config ''
if ($config.tileCache.fallbackToApi -ne $true) { throw 'Missing fallback property was not added.' }
$runtimeCases++
Write-Host "PASS: $runtimeCases runtime CDN override, placeholder, fallback and validation cases."