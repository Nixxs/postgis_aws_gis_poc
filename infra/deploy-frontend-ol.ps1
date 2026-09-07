# Independent OpenLayers UI; shares only the API with the original frontend.
# FRONTEND_OL_* settings are read from ConfigFile, not inherited shell values.
# Build contract: frontend-ol/package.json builds dist/, public/config.json is
# copied to dist/config.json, and the UI consumes VITE_QUERY_API_URL,
# VITE_TILE_API_URL and VITE_CONFIG_URL (same-origin /config.json).
[CmdletBinding()]
param(
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
    try {
        $ErrorActionPreference = "Continue"
        $result = (& aws @Arguments --profile $settings.AWS_PROFILE --region $settings.AWS_REGION --no-cli-pager 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "AWS command failed: aws $($Arguments -join ' ')`n$result" }
    return $result
}

function Get-AwsValue([string[]]$Arguments) {
    $value = Invoke-Aws -Arguments ($Arguments + @("--output", "text"))
    if ($value -eq "None") { return "" }
    return $value
}

# File-backed JSON avoids Windows PowerShell/native-command quote stripping.
function Invoke-AwsDocument([string[]]$Arguments, [string]$Parameter, [object]$Document) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-ol-$([Guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        return Invoke-Aws -Arguments ($Arguments + @($Parameter, "file://$path"))
    }
    finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
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
$bucket = if ($settings.FRONTEND_OL_BUCKET) { $settings.FRONTEND_OL_BUCKET } else { "gis-postgis-frontend-ol-$account" }
$comment = if ($settings.FRONTEND_OL_CLOUDFRONT_COMMENT) { $settings.FRONTEND_OL_CLOUDFRONT_COMMENT } else { "gis-postgis-frontend-ol" }
$oacName = if ($settings.FRONTEND_OL_OAC_NAME) { $settings.FRONTEND_OL_OAC_NAME } else { "gis-postgis-frontend-ol-oac" }
if ($bucket -in @($settings.FRONTEND_BUCKET, "gis-postgis-frontend-$account") -or
    $comment -in @($settings.FRONTEND_CLOUDFRONT_COMMENT, "gis-postgis-frontend") -or
    $oacName -in @($settings.FRONTEND_OAC_NAME, "gis-postgis-frontend-oac")) {
    throw "OpenLayers bucket, comment and OAC must differ from the original frontend's configured and default resources."
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$frontendRoot = Join-Path $repoRoot "frontend-ol"
if (-not $SkipBuild) {
    $apiUri = $null
    if (-not [Uri]::TryCreate($settings.FRONTEND_OL_API_URL, [UriKind]::Absolute, [ref]$apiUri) -or
        $apiUri.Scheme -ne "https" -or $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment -or
        $settings.FRONTEND_OL_API_URL -match "REPLACE_") {
        throw "Set FRONTEND_OL_API_URL to the shared HTTPS API base URL (no credentials, query or fragment)."
    }
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: npm.cmd" }
    foreach ($path in @("package.json", "public/config.json", "node_modules")) {
        if (-not (Test-Path (Join-Path $frontendRoot $path))) {
            throw "frontend-ol/$path is required. Prepare the independent UI and its dependencies first; this script does not install them."
        }
    }
    $buildEnvironment = @{
        VITE_QUERY_API_URL = $settings.FRONTEND_OL_API_URL.TrimEnd('/')
        VITE_TILE_API_URL = $settings.FRONTEND_OL_API_URL.TrimEnd('/')
        VITE_CONFIG_URL = "/config.json"
    }
    $previousBuildEnvironment = @{}
    Write-Host "Building frontend-ol..."
    Push-Location $frontendRoot
    try {
        foreach ($name in $buildEnvironment.Keys) {
            $previousBuildEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            Set-Item -Path "Env:$name" -Value $buildEnvironment[$name]
        }
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw "OpenLayers frontend build failed." }
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
    if (-not (Test-Path (Join-Path $dist $file))) { throw "frontend-ol/dist/$file is required. Run without -SkipBuild." }
}
try { $null = Get-Content -Raw (Join-Path $dist "config.json") | ConvertFrom-Json }
catch { throw "frontend-ol/dist/config.json must contain valid JSON." }
if ($SkipBuild) { Write-Warning "Using the existing OL build; verify its API and config URLs before deployment." }

# Resolve resources locally rather than interpolating configurable names into JMESPath.
$distributions = (Invoke-Aws -Arguments @("cloudfront", "list-distributions", "--output", "json") | ConvertFrom-Json).DistributionList.Items
$matchingDistributions = @($distributions | Where-Object { $_.Comment -eq $comment })
if ($matchingDistributions.Count -gt 1) { throw "Multiple CloudFront distributions match the OL comment; use a unique comment." }
$distributionId = ""
if ($matchingDistributions.Count -eq 1) { $distributionId = $matchingDistributions[0].Id }
$controls = (Invoke-Aws -Arguments @("cloudfront", "list-origin-access-controls", "--output", "json") | ConvertFrom-Json).OriginAccessControlList.Items
$matchingControls = @($controls | Where-Object { $_.Name -eq $oacName })
if ($matchingControls.Count -gt 1) { throw "Multiple OACs match the OL name." }
$oacId = ""
if ($matchingControls.Count -eq 1) {
    $control = $matchingControls[0]
    if ($control.SigningProtocol -ne "sigv4" -or $control.SigningBehavior -ne "always" -or $control.OriginAccessControlOriginType -ne "s3") {
        throw "Existing OL OAC must always sign S3 requests with sigv4."
    }
    $oacId = $control.Id
}
$originDomain = "$bucket.s3.$region.amazonaws.com"
foreach ($distribution in $distributions) {
    if ($distribution.Id -eq $distributionId) { continue }
    foreach ($origin in $distribution.Origins.Items) {
        if ($origin.DomainName -eq "$bucket.s3.amazonaws.com" -or $origin.DomainName -like "$bucket.s3.*" -or
            $origin.DomainName -like "$bucket.s3-*" -or ($oacId -and $origin.OriginAccessControlId -eq $oacId)) {
            throw "Another distribution uses the OL bucket or OAC. Refusing to reuse shared frontend resources."
        }
    }
}
if ($distributionId) {
    $existing = Invoke-Aws -Arguments @("cloudfront", "get-distribution", "--id", $distributionId, "--query", "Distribution.DistributionConfig", "--output", "json") | ConvertFrom-Json
    $origin = @($existing.Origins.Items)[0]
    if ($existing.Origins.Quantity -ne 1 -or $origin.DomainName -ne $originDomain -or $origin.OriginPath -or
        $existing.DefaultCacheBehavior.TargetOriginId -ne $origin.Id -or $existing.CacheBehaviors.Quantity -gt 0 -or
        -not $oacId -or $origin.OriginAccessControlId -ne $oacId) {
        throw "Existing OL distribution does not exclusively serve the configured bucket and OAC. Refusing deployment."
    }
}

Write-Host "Ensuring private OpenLayers bucket $bucket..."
$bucketExists = $true
try { [void](Invoke-Aws -Arguments @("s3api", "head-bucket", "--bucket", $bucket, "--expected-bucket-owner", $account)) }
catch {
    # Access denied, wrong owner and network failures must not be treated as a missing bucket.
    if ($_.Exception.Message -notmatch '\(404\)|NoSuchBucket|Not Found') { throw }
    $bucketExists = $false
}
if (-not $bucketExists) {
    $arguments = @("s3api", "create-bucket", "--bucket", $bucket)
    if ($region -eq "us-east-1") { [void](Invoke-Aws -Arguments $arguments) }
    else { [void](Invoke-AwsDocument -Arguments $arguments -Parameter "--create-bucket-configuration" -Document @{ LocationConstraint = $region }) }
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
        Description = "Private S3 access for the independent OpenLayers frontend"
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
        Sid = "AllowOpenLayersCloudFrontRead"; Effect = "Allow"
        Principal = @{ Service = "cloudfront.amazonaws.com" }
        Action = "s3:GetObject"; Resource = "arn:aws:s3:::$bucket/*"
        Condition = @{ StringEquals = @{ "AWS:SourceArn" = "arn:aws:cloudfront::${account}:distribution/$distributionId" } }
    })
}
[void](Invoke-AwsDocument -Arguments (@("s3api", "put-bucket-policy") + $bucketArguments) -Parameter "--policy" -Document $policy)

Write-Host "Uploading OpenLayers frontend..."
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
    CallerReference = "frontend-ol-$([Guid]::NewGuid().ToString('N'))"
    Paths = @{ Quantity = 1; Items = @("/*") }
})
Write-Host ""
Write-Host "OpenLayers deployment complete: https://$domain" -ForegroundColor Green
Write-Host "CloudFront deployment and cache invalidation may take several minutes."
Write-Host "Set FRONTEND_OL_URL=https://$domain in your deployment config; preserve the existing FRONTEND_URL unchanged."
Write-Host "Then redeploy the shared API with infra/deploy-api.ps1 using the same -ConfigFile to allow both frontends."