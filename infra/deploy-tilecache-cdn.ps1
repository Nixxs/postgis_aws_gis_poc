# Publish the private tile-cache bucket through a dedicated CloudFront OAC.
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [switch]$SkipWait
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

# File-backed JSON prevents Windows PowerShell from stripping quotes.
function Invoke-AwsDocument([string[]]$Arguments, [string]$Parameter, [object]$Document) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "gis-tilecache-cdn-$([Guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText(
            $path,
            ($Document | ConvertTo-Json -Depth 20),
            (New-Object System.Text.UTF8Encoding($false))
        )
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

$account = Get-AwsValue @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $settings.AWS_ACCOUNT_ID) {
    throw "AWS profile points to account $account; expected $($settings.AWS_ACCOUNT_ID)."
}
$region = $settings.AWS_REGION
$bucket = if ($settings.TILECACHE_BUCKET) { $settings.TILECACHE_BUCKET } else { "gis-postgis-tilecache-$account" }
$comment = if ($settings.TILECACHE_CLOUDFRONT_COMMENT) { $settings.TILECACHE_CLOUDFRONT_COMMENT } else { "gis-postgis-tilecache" }
$oacName = if ($settings.TILECACHE_OAC_NAME) { $settings.TILECACHE_OAC_NAME } else { "gis-postgis-tilecache-oac" }
$responsePolicyName = if ($settings.TILECACHE_RESPONSE_HEADERS_POLICY) { $settings.TILECACHE_RESPONSE_HEADERS_POLICY } else { "gis-postgis-tilecache-cors" }
$originDomain = "$bucket.s3.$region.amazonaws.com"

[void](Invoke-Aws @("s3api", "head-bucket", "--bucket", $bucket, "--expected-bucket-owner", $account))

$distributions = (Invoke-Aws @("cloudfront", "list-distributions", "--output", "json") | ConvertFrom-Json).DistributionList.Items
$matchingDistributions = @($distributions | Where-Object { $_.Comment -eq $comment })
if ($matchingDistributions.Count -gt 1) { throw "Multiple CloudFront distributions use comment '$comment'." }
$distributionId = if ($matchingDistributions.Count -eq 1) { $matchingDistributions[0].Id } else { "" }

$controls = (Invoke-Aws @("cloudfront", "list-origin-access-controls", "--output", "json") | ConvertFrom-Json).OriginAccessControlList.Items
$matchingControls = @($controls | Where-Object { $_.Name -eq $oacName })
if ($matchingControls.Count -gt 1) { throw "Multiple CloudFront OACs use name '$oacName'." }
$oacId = if ($matchingControls.Count -eq 1) { $matchingControls[0].Id } else { "" }
if ($oacId) {
    $control = $matchingControls[0]
    if ($control.SigningProtocol -ne "sigv4" -or $control.SigningBehavior -ne "always" -or $control.OriginAccessControlOriginType -ne "s3") {
        throw "Existing tile-cache OAC must always sign S3 requests with sigv4."
    }
}

$responsePolicies = (Invoke-Aws @("cloudfront", "list-response-headers-policies", "--type", "custom", "--output", "json") | ConvertFrom-Json).ResponseHeadersPolicyList.Items
$matchingPolicies = @($responsePolicies | Where-Object { $_.ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name -eq $responsePolicyName })
if ($matchingPolicies.Count -gt 1) { throw "Multiple response-header policies use name '$responsePolicyName'." }
$responsePolicyId = if ($matchingPolicies.Count -eq 1) { $matchingPolicies[0].ResponseHeadersPolicy.Id } else { "" }

foreach ($distribution in $distributions) {
    if ($distribution.Id -eq $distributionId) { continue }
    foreach ($origin in $distribution.Origins.Items) {
        if ($origin.DomainName -eq $originDomain -or ($oacId -and $origin.OriginAccessControlId -eq $oacId)) {
            throw "Another CloudFront distribution already uses the tile bucket or OAC."
        }
    }
}

if (-not $oacId) {
    Write-Host "Creating CloudFront origin access control..."
    $oacId = Invoke-AwsDocument @(
        "cloudfront", "create-origin-access-control", "--query", "OriginAccessControl.Id", "--output", "text"
    ) "--origin-access-control-config" @{
        Name = $oacName
        Description = "Private S3 access for pregenerated PostGIS vector tiles"
        SigningProtocol = "sigv4"
        SigningBehavior = "always"
        OriginAccessControlOriginType = "s3"
    }
}

if (-not $responsePolicyId) {
    Write-Host "Creating tile CORS response policy..."
    $responsePolicyId = Invoke-AwsDocument @(
        "cloudfront", "create-response-headers-policy", "--query", "ResponseHeadersPolicy.Id", "--output", "text"
    ) "--response-headers-policy-config" @{
        Name = $responsePolicyName
        Comment = "Cross-origin access and safe content headers for public vector tiles"
        CorsConfig = @{
            AccessControlAllowCredentials = $false
            AccessControlAllowHeaders = @{ Quantity = 1; Items = @("*") }
            AccessControlAllowMethods = @{ Quantity = 3; Items = @("GET", "HEAD", "OPTIONS") }
            AccessControlAllowOrigins = @{ Quantity = 1; Items = @("*") }
            AccessControlExposeHeaders = @{ Quantity = 2; Items = @("ETag", "Content-Length") }
            AccessControlMaxAgeSec = 3600
            OriginOverride = $true
        }
        SecurityHeadersConfig = @{
            ContentTypeOptions = @{ Override = $true }
            ReferrerPolicy = @{ ReferrerPolicy = "no-referrer"; Override = $true }
        }
    }
}

if (-not $distributionId) {
    Write-Host "Creating CloudFront distribution..."
    $originId = "s3-$bucket"
    $distributionConfig = @{
        CallerReference = "$comment-$([Guid]::NewGuid().ToString('N'))"
        Comment = $comment
        Enabled = $true
        HttpVersion = "http2and3"
        Origins = @{ Quantity = 1; Items = @(@{
            Id = $originId
            DomainName = $originDomain
            OriginPath = ""
            CustomHeaders = @{ Quantity = 0 }
            OriginAccessControlId = $oacId
            S3OriginConfig = @{ OriginAccessIdentity = "" }
            ConnectionAttempts = 3
            ConnectionTimeout = 10
        }) }
        DefaultCacheBehavior = @{
            TargetOriginId = $originId
            ViewerProtocolPolicy = "redirect-to-https"
            CachePolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"
            ResponseHeadersPolicyId = $responsePolicyId
            Compress = $true
            SmoothStreaming = $false
            TrustedSigners = @{ Enabled = $false; Quantity = 0 }
            TrustedKeyGroups = @{ Enabled = $false; Quantity = 0 }
            AllowedMethods = @{
                Quantity = 3
                Items = @("GET", "HEAD", "OPTIONS")
                CachedMethods = @{ Quantity = 3; Items = @("GET", "HEAD", "OPTIONS") }
            }
            LambdaFunctionAssociations = @{ Quantity = 0 }
            FunctionAssociations = @{ Quantity = 0 }
        }
        CacheBehaviors = @{ Quantity = 0 }
        CustomErrorResponses = @{ Quantity = 0 }
        ViewerCertificate = @{ CloudFrontDefaultCertificate = $true; MinimumProtocolVersion = "TLSv1" }
        Restrictions = @{ GeoRestriction = @{ RestrictionType = "none"; Quantity = 0 } }
        PriceClass = "PriceClass_All"
        IsIPV6Enabled = $true
    }
    $distributionId = Invoke-AwsDocument @(
        "cloudfront", "create-distribution-with-tags", "--query", "Distribution.Id", "--output", "text"
    ) "--distribution-config-with-tags" @{
        DistributionConfig = $distributionConfig
        Tags = @{ Items = @(
            @{ Key = "lz:CostCenter"; Value = "PlanningSpatial" },
            @{ Key = "lz:BackupPlan"; Value = "Daily" }
        ) }
    }
}
else {
    $existing = Invoke-Aws @(
        "cloudfront", "get-distribution", "--id", $distributionId,
        "--query", "Distribution.DistributionConfig", "--output", "json"
    ) | ConvertFrom-Json
    $origin = @($existing.Origins.Items)[0]
    if ($existing.Origins.Quantity -ne 1 -or $origin.DomainName -ne $originDomain -or
        $origin.OriginAccessControlId -ne $oacId -or
        $existing.DefaultCacheBehavior.ResponseHeadersPolicyId -ne $responsePolicyId) {
        throw "Existing tile-cache distribution does not exclusively use the expected bucket, OAC, and response policy."
    }
}

$bucketPolicy = @{
    Version = "2012-10-17"
    Statement = @(@{
        Sid = "AllowTileCacheCloudFrontRead"
        Effect = "Allow"
        Principal = @{ Service = "cloudfront.amazonaws.com" }
        Action = "s3:GetObject"
        Resource = "arn:aws:s3:::$bucket/*"
        Condition = @{ StringEquals = @{ "AWS:SourceArn" = "arn:aws:cloudfront::${account}:distribution/$distributionId" } }
    })
}
[void](Invoke-AwsDocument @("s3api", "put-bucket-policy", "--bucket", $bucket, "--expected-bucket-owner", $account) "--policy" $bucketPolicy)

if (-not $SkipWait) {
    Write-Host "Waiting for CloudFront deployment..."
    [void](Invoke-Aws @("cloudfront", "wait", "distribution-deployed", "--id", $distributionId))
}
$domain = Get-AwsValue @("cloudfront", "get-distribution", "--id", $distributionId, "--query", "Distribution.DomainName")
$status = Get-AwsValue @("cloudfront", "get-distribution", "--id", $distributionId, "--query", "Distribution.Status")

Write-Host ""
Write-Host "Tile CDN deployment complete: https://$domain" -ForegroundColor Green
Write-Host "Distribution: $distributionId ($status)"
Write-Host "Latest manifest: https://$domain/tiles/public/au_vic_dtp_planning_scheme_all/webmercator/latest.json"
Write-Host "Test tile:       https://$domain/tiles/public/au_vic_dtp_planning_scheme_all/webmercator/first-build-20260908/0/0/0.mvt"
