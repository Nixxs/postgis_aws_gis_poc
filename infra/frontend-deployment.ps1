# Shared deployment for independent MapLibre and OpenLayers frontends.
# ConfigFile settings stay in a hashtable; only explicit VITE_* build values
# are temporarily exported. Generated runtime config never changes public/.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MapLibre', 'OpenLayers')][string]$Frontend,
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Deployment config not found: $Path" }
    $settings = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) {
            $settings[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
        }
    }
    return $settings
}

function Invoke-Aws([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $ErrorActionPreference = "Continue"
        $result = (& aws @Arguments --profile $settings.AWS_PROFILE --region $settings.AWS_REGION --no-cli-pager 2>$errorFile | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        $errorText = [System.IO.File]::ReadAllText($errorFile).Trim()
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item $errorFile -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) { throw "AWS command failed: aws $($Arguments -join ' ')`n$errorText`n$result" }
    return $result
}

function Get-AwsValue([string[]]$Arguments) {
    $json = Invoke-Aws -Arguments ($Arguments + @("--output", "json"))
    $value = ConvertFrom-Json -InputObject $json
    if ($null -eq $value) { return "" }
    if ($value -isnot [string] -and $value -isnot [ValueType]) {
        throw "AWS scalar lookup returned a collection instead of a single value."
    }
    if ([string]$value -match '[\r\n]') { throw "AWS scalar lookup returned a multiline value." }
    return [string]$value
}

function Invoke-FrontendNpm([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        # Vite sends non-fatal warnings to stderr. Only the exit code decides
        # whether a native command failed in Windows PowerShell 5.1.
        $ErrorActionPreference = "Continue"
        & npm.cmd @Arguments 2>&1 | ForEach-Object {
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host $text }
        }
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "Frontend npm command failed (exit $exitCode): $($Arguments -join ' '). Review build output above." }
}

function New-FrontendBucketConfiguration([string]$Region) {
    # Required tags must exist at creation time, not only in a later tagging call.
    $document = @{
        Tags = @(
            @{ Key = "lz:CostCenter"; Value = "PlanningSpatial" },
            @{ Key = "lz:BackupPlan"; Value = "Daily" }
        )
    }
    if ($Region -ne "us-east-1") { $document.LocationConstraint = $Region }
    return $document
}

# File-backed JSON avoids Windows PowerShell/native-command quote stripping.
function Invoke-AwsDocument([string[]]$Arguments, [string]$Parameter, [object]$Document) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-$([Guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        return Invoke-Aws -Arguments ($Arguments + @($Parameter, "file://$path"))
    }
    finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

function Get-FrontendDeploymentSettings(
    [ValidateSet('MapLibre', 'OpenLayers')][string]$Frontend,
    [hashtable]$Settings,
    [string]$Account
) {
    $prefix = "FRONTEND"
    $siblingPrefix = "FRONTEND_OL"
    $directory = "frontend"
    $siblingDirectory = "frontend-ol"
    if ($Frontend -eq 'OpenLayers') {
        $prefix = "FRONTEND_OL"
        $siblingPrefix = "FRONTEND"
        $directory = "frontend-ol"
        $siblingDirectory = "frontend"
    }
    $resources = @{}
    foreach ($resource in @('BUCKET', 'CLOUDFRONT_COMMENT', 'OAC_NAME')) {
        $default = switch ($resource) {
            'BUCKET' { "gis-postgis-$directory-$Account" }
            'CLOUDFRONT_COMMENT' { "gis-postgis-$directory" }
            'OAC_NAME' { "gis-postgis-$directory-oac" }
        }
        $siblingDefault = switch ($resource) {
            'BUCKET' { "gis-postgis-$siblingDirectory-$Account" }
            'CLOUDFRONT_COMMENT' { "gis-postgis-$siblingDirectory" }
            'OAC_NAME' { "gis-postgis-$siblingDirectory-oac" }
        }
        $configured = $Settings["${prefix}_$resource"]
        $value = if ($configured) { $configured } else { $default }
        if ($value -in @($Settings["${siblingPrefix}_$resource"], $siblingDefault)) {
            throw "$Frontend bucket, comment and OAC must differ from the sibling frontend's configured and default resources."
        }
        $resources[$resource] = $value
    }
    $apiUrl = $Settings["${prefix}_API_URL"]
    if ($Frontend -eq 'MapLibre' -and [string]::IsNullOrWhiteSpace($apiUrl)) {
        # Current legacy DTP configs only specify the shared API under OL.
        $apiUrl = $Settings.FRONTEND_OL_API_URL
    }
    return @{
        Directory = $directory
        Bucket = $resources.BUCKET
        Comment = $resources.CLOUDFRONT_COMMENT
        OacName = $resources.OAC_NAME
        ApiUrl = $apiUrl
        ApiSetting = "${prefix}_API_URL"
        UrlSetting = "${prefix}_URL"
        SiblingUrlSetting = "${siblingPrefix}_URL"
        CompletionLabel = $(if ($Frontend -eq 'MapLibre') { 'Frontend' } else { 'OpenLayers' })
    }
}

function Update-FrontendRuntimeConfig([object]$RuntimeConfig, [string]$CdnUrl) {
    # This exact bootstrap placeholder is not a deployed tile CDN. Retain the
    # historical source URL for discovery and allow dynamic API fallback.
    $hasCdn = -not [string]::IsNullOrWhiteSpace($CdnUrl) -and $CdnUrl.TrimEnd('/') -ne 'https://placeholder.invalid'
    if ($hasCdn) {
        $tileCacheUri = $null
        if (-not [Uri]::TryCreate($CdnUrl, [UriKind]::Absolute, [ref]$tileCacheUri) -or
            $tileCacheUri.Scheme -ne "https" -or $tileCacheUri.UserInfo -or $tileCacheUri.Query -or $tileCacheUri.Fragment) {
            throw "TILECACHE_CDN_URL must be an HTTPS origin without credentials, query or fragment."
        }
        if (-not $RuntimeConfig.tileCache) { throw "Frontend runtime config must contain tileCache settings." }
        $RuntimeConfig.tileCache | Add-Member -MemberType NoteProperty -Name baseUrl -Value $CdnUrl.TrimEnd('/') -Force
        Write-Host "Using tile CDN $($RuntimeConfig.tileCache.baseUrl) in the generated runtime config."
    }
    elseif ($RuntimeConfig.tileCache) {
        $RuntimeConfig.tileCache | Add-Member -MemberType NoteProperty -Name fallbackToApi -Value $true -Force
    }
}

$settings = Import-DotEnv $ConfigFile
foreach ($name in @("AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID")) {
    if ([string]::IsNullOrWhiteSpace($settings[$name]) -or $settings[$name].StartsWith("REPLACE_")) {
        throw "Set $name in the deployment config before deploying."
    }
}
if ($settings.AWS_ACCOUNT_ID -notmatch '^\d{12}$') { throw "AWS_ACCOUNT_ID must contain 12 digits." }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: aws" }

# Verify identity before building or changing resources; derive defaults from the verified account.
$account = Get-AwsValue -Arguments @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $settings.AWS_ACCOUNT_ID) { throw "AWS profile points to account $account; expected $($settings.AWS_ACCOUNT_ID)." }
$region = $settings.AWS_REGION
$deployment = Get-FrontendDeploymentSettings -Frontend $Frontend -Settings $settings -Account $account
$bucket = $deployment.Bucket
$comment = $deployment.Comment
$oacName = $deployment.OacName

$repoRoot = Split-Path $PSScriptRoot -Parent
$frontendRoot = Join-Path $repoRoot $deployment.Directory
if (-not $SkipBuild) {
    $apiUri = $null
    if (-not [Uri]::TryCreate($deployment.ApiUrl, [UriKind]::Absolute, [ref]$apiUri) -or
        $apiUri.Scheme -ne "https" -or $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment -or
        $deployment.ApiUrl -match "REPLACE_") {
        throw "Set $($deployment.ApiSetting) to the shared HTTPS API base URL (no credentials, query or fragment)."
    }
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: npm.cmd" }
    foreach ($path in @("package.json", "public/config.json")) {
        if (-not (Test-Path (Join-Path $frontendRoot $path))) {
            throw "$($deployment.Directory)/$path is required. Prepare the independent UI first."
        }
    }
    if ($Frontend -eq 'OpenLayers' -and -not (Test-Path (Join-Path $frontendRoot "node_modules"))) {
        throw "frontend-ol/node_modules is required. Prepare its dependencies first; this script does not install them."
    }
    $buildEnvironment = @{
        VITE_QUERY_API_URL = $deployment.ApiUrl.TrimEnd('/')
        VITE_TILE_API_URL = $deployment.ApiUrl.TrimEnd('/')
        VITE_CONFIG_URL = "/config.json"
    }
    $previousBuildEnvironment = @{}
    Write-Host "Building $($deployment.Directory)..."
    Push-Location $frontendRoot
    try {
        foreach ($name in $buildEnvironment.Keys) {
            $previousBuildEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            Set-Item -Path "Env:$name" -Value $buildEnvironment[$name]
        }
        if ($Frontend -eq 'MapLibre' -and -not (Test-Path (Join-Path $frontendRoot "node_modules"))) {
            Invoke-FrontendNpm @("ci")
        }
        Invoke-FrontendNpm @("run", "build")
    }
    finally {
        foreach ($name in $previousBuildEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousBuildEnvironment[$name])
        }
        Pop-Location
    }
}
$dist = Join-Path $frontendRoot "dist"
foreach ($file in @("index.html", "config.json")) {
    if (-not (Test-Path (Join-Path $dist $file))) { throw "$($deployment.Directory)/dist/$file is required. Run without -SkipBuild." }
}
try { $runtimeConfig = Get-Content -Raw (Join-Path $dist "config.json") | ConvertFrom-Json }
catch { throw "$($deployment.Directory)/dist/config.json must contain valid JSON." }
Update-FrontendRuntimeConfig -RuntimeConfig $runtimeConfig -CdnUrl $settings.TILECACHE_CDN_URL
[System.IO.File]::WriteAllText(
    (Join-Path $dist "config.json"),
    ($runtimeConfig | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding($false))
)
if ($SkipBuild) { Write-Warning "Using the existing $Frontend build; verify its API and config URLs before deployment." }

# Resolve resources locally rather than interpolating configurable names into JMESPath.
$distributions = (Invoke-Aws -Arguments @("cloudfront", "list-distributions", "--output", "json") | ConvertFrom-Json).DistributionList.Items
$matchingDistributions = @($distributions | Where-Object { $_.Comment -eq $comment })
if ($matchingDistributions.Count -gt 1) { throw "Multiple CloudFront distributions match the frontend comment; use a unique comment." }
$distributionId = ""
if ($matchingDistributions.Count -eq 1) { $distributionId = $matchingDistributions[0].Id }
$controls = (Invoke-Aws -Arguments @("cloudfront", "list-origin-access-controls", "--output", "json") | ConvertFrom-Json).OriginAccessControlList.Items
$matchingControls = @($controls | Where-Object { $_.Name -eq $oacName })
if ($matchingControls.Count -gt 1) { throw "Multiple OACs match the frontend name." }
$oacId = ""
if ($matchingControls.Count -eq 1) {
    $control = $matchingControls[0]
    if ($control.SigningProtocol -ne "sigv4" -or $control.SigningBehavior -ne "always" -or $control.OriginAccessControlOriginType -ne "s3") {
        throw "Existing frontend OAC must always sign S3 requests with sigv4."
    }
    $oacId = $control.Id
}
$originDomain = "$bucket.s3.$region.amazonaws.com"
foreach ($distribution in $distributions) {
    if ($distribution.Id -eq $distributionId) { continue }
    foreach ($origin in $distribution.Origins.Items) {
        if ($origin.DomainName -eq "$bucket.s3.amazonaws.com" -or $origin.DomainName -like "$bucket.s3.*" -or
            $origin.DomainName -like "$bucket.s3-*" -or ($oacId -and $origin.OriginAccessControlId -eq $oacId)) {
            throw "Another distribution uses the frontend bucket or OAC. Refusing to reuse shared frontend resources."
        }
    }
}
if ($distributionId) {
    $existing = Invoke-Aws -Arguments @("cloudfront", "get-distribution", "--id", $distributionId, "--query", "Distribution.DistributionConfig", "--output", "json") | ConvertFrom-Json
    $origin = @($existing.Origins.Items)[0]
    if ($existing.Origins.Quantity -ne 1 -or $origin.DomainName -ne $originDomain -or $origin.OriginPath -or
        $existing.DefaultCacheBehavior.TargetOriginId -ne $origin.Id -or $existing.CacheBehaviors.Quantity -gt 0 -or
        -not $oacId -or $origin.OriginAccessControlId -ne $oacId) {
        throw "Existing frontend distribution does not exclusively serve the configured bucket and OAC. Refusing deployment."
    }
}

Write-Host "Ensuring private $Frontend bucket $bucket..."
$bucketExists = $true
try { [void](Invoke-Aws -Arguments @("s3api", "head-bucket", "--bucket", $bucket, "--expected-bucket-owner", $account)) }
catch {
    # Access denied, wrong owner and network failures must not be treated as a missing bucket.
    if ($_.Exception.Message -notmatch '\(404\)|NoSuchBucket|Not Found') { throw }
    $bucketExists = $false
}
if (-not $bucketExists) {
    $arguments = @("s3api", "create-bucket", "--bucket", $bucket)
    [void](Invoke-AwsDocument -Arguments $arguments -Parameter "--create-bucket-configuration" -Document (New-FrontendBucketConfiguration $region))
}
$bucketArguments = @("--bucket", $bucket, "--expected-bucket-owner", $account)
[void](Invoke-AwsDocument -Arguments (@("s3api", "put-public-access-block") + $bucketArguments) -Parameter "--public-access-block-configuration" -Document @{
    BlockPublicAcls = $true; IgnorePublicAcls = $true; BlockPublicPolicy = $true; RestrictPublicBuckets = $true
})
[void](Invoke-AwsDocument -Arguments (@("s3api", "put-bucket-encryption") + $bucketArguments) -Parameter "--server-side-encryption-configuration" -Document @{
    Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "AES256" } })
})
[void](Invoke-AwsDocument -Arguments (@("s3api", "put-bucket-tagging") + $bucketArguments) -Parameter "--tagging" -Document @{
    TagSet = @(@{ Key = "lz:CostCenter"; Value = "PlanningSpatial" }, @{ Key = "lz:BackupPlan"; Value = "Daily" })
})

if (-not $oacId) {
    $oacId = Invoke-AwsDocument -Arguments @("cloudfront", "create-origin-access-control", "--query", "OriginAccessControl.Id", "--output", "text") -Parameter "--origin-access-control-config" -Document @{
        Name = $oacName
        Description = "Private S3 access for the independent $Frontend frontend"
        SigningProtocol = "sigv4"
        SigningBehavior = "always"
        OriginAccessControlOriginType = "s3"
    }
}
if (-not $distributionId) {
    $distributionConfig = @{
        CallerReference = "$comment-$([Guid]::NewGuid().ToString('N'))"
        Comment = $comment
        Enabled = $true
        HttpVersion = "http2and3"
        DefaultRootObject = "index.html"
        Origins = @{ Quantity = 1; Items = @(@{
            Id = "s3-$bucket"; DomainName = $originDomain; OriginPath = ""
            CustomHeaders = @{ Quantity = 0 }
            OriginAccessControlId = $oacId
            S3OriginConfig = @{ OriginAccessIdentity = "" }
            ConnectionAttempts = 3; ConnectionTimeout = 10
        }) }
        DefaultCacheBehavior = @{
            TargetOriginId = "s3-$bucket"
            ViewerProtocolPolicy = "redirect-to-https"
            CachePolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"
            Compress = $true; SmoothStreaming = $false
            TrustedSigners = @{ Enabled = $false; Quantity = 0 }
            TrustedKeyGroups = @{ Enabled = $false; Quantity = 0 }
            AllowedMethods = @{ Quantity = 2; Items = @("GET", "HEAD"); CachedMethods = @{ Quantity = 2; Items = @("GET", "HEAD") } }
            LambdaFunctionAssociations = @{ Quantity = 0 }
            FunctionAssociations = @{ Quantity = 0 }
        }
        CustomErrorResponses = @{ Quantity = 2; Items = @(
            @{ ErrorCode = 403; ResponseCode = "200"; ResponsePagePath = "/index.html"; ErrorCachingMinTTL = 0 },
            @{ ErrorCode = 404; ResponseCode = "200"; ResponsePagePath = "/index.html"; ErrorCachingMinTTL = 0 }
        ) }
        ViewerCertificate = @{ CloudFrontDefaultCertificate = $true; MinimumProtocolVersion = "TLSv1" }
        Restrictions = @{ GeoRestriction = @{ RestrictionType = "none"; Quantity = 0 } }
        PriceClass = "PriceClass_100"
        IsIPV6Enabled = $true
    }
    $distributionId = Invoke-AwsDocument -Arguments @("cloudfront", "create-distribution", "--query", "Distribution.Id", "--output", "text") -Parameter "--distribution-config" -Document $distributionConfig
}
$domain = Get-AwsValue -Arguments @("cloudfront", "get-distribution", "--id", $distributionId, "--query", "Distribution.DomainName")
$policy = @{
    Version = "2012-10-17"
    Statement = @(@{
        Sid = "AllowCloudFrontRead"; Effect = "Allow"
        Principal = @{ Service = "cloudfront.amazonaws.com" }
        Action = "s3:GetObject"; Resource = "arn:aws:s3:::$bucket/*"
        Condition = @{ StringEquals = @{ "AWS:SourceArn" = "arn:aws:cloudfront::${account}:distribution/$distributionId" } }
    })
}
[void](Invoke-AwsDocument -Arguments (@("s3api", "put-bucket-policy") + $bucketArguments) -Parameter "--policy" -Document $policy)

Write-Host "Uploading $Frontend frontend..."
[void](Invoke-Aws -Arguments @("s3", "sync", $dist, "s3://$bucket", "--delete"))
if (Test-Path (Join-Path $dist "assets")) {
    [void](Invoke-Aws -Arguments @("s3", "cp", (Join-Path $dist "assets"), "s3://$bucket/assets", "--recursive", "--cache-control", "public,max-age=31536000,immutable"))
}
foreach ($file in @("index.html", "config.json")) {
    [void](Invoke-Aws -Arguments @(
        "s3", "cp", (Join-Path $dist $file), "s3://$bucket/$file", "--cache-control", "no-cache,no-store,must-revalidate",
        "--content-type", $(if ($file.EndsWith(".json")) { "application/json" } else { "text/html" })
    ))
}
[void](Invoke-AwsDocument -Arguments @("cloudfront", "create-invalidation", "--distribution-id", $distributionId) -Parameter "--invalidation-batch" -Document @{
    CallerReference = "$($deployment.Directory)-$([Guid]::NewGuid().ToString('N'))"
    Paths = @{ Quantity = 1; Items = @("/*") }
})
Write-Host ""
Write-Host "$($deployment.CompletionLabel) deployment complete: https://$domain" -ForegroundColor Green
Write-Host "CloudFront deployment and cache invalidation may take several minutes."
Write-Host "Set $($deployment.UrlSetting)=https://$domain in your deployment config; preserve the existing $($deployment.SiblingUrlSetting) unchanged."
Write-Host "Then redeploy the shared API with infra/deploy-api.ps1 using the same -ConfigFile to allow both frontends."