[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Deployment config not found: $Path" }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) {
            Set-Item -Path "Env:$($parts[0].Trim())" -Value $parts[1].Trim().Trim('"').Trim("'")
        }
    }
}

function Invoke-Aws([string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $result = (& aws @Arguments --profile $env:AWS_PROFILE --no-cli-pager 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) { throw "AWS command failed: aws $($Arguments -join ' ')`n$result" }
    return $result
}

function Get-AwsValue([string[]]$Arguments) {
    $value = Invoke-Aws -Arguments ($Arguments + @("--output", "text"))
    if ($value -eq "None") { return "" }
    return $value
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Import-DotEnv $ConfigFile
foreach ($name in @("AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Set $name in $ConfigFile before deploying."
    }
}
foreach ($command in @("aws", "npm")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $command" }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$frontendRoot = Join-Path $repoRoot "frontend"
$bucket = if ($env:FRONTEND_BUCKET) { $env:FRONTEND_BUCKET } else { "gis-postgis-frontend-$($env:AWS_ACCOUNT_ID)" }
$comment = if ($env:FRONTEND_CLOUDFRONT_COMMENT) { $env:FRONTEND_CLOUDFRONT_COMMENT } else { "gis-postgis-frontend" }
$oacName = if ($env:FRONTEND_OAC_NAME) { $env:FRONTEND_OAC_NAME } else { "gis-postgis-frontend-oac" }

$account = Get-AwsValue -Arguments @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $env:AWS_ACCOUNT_ID) { throw "AWS profile points to account $account; expected $($env:AWS_ACCOUNT_ID)." }

if (-not $SkipBuild) {
    Write-Host "Building frontend..."
    Push-Location $frontendRoot
    try {
        if (-not (Test-Path (Join-Path $frontendRoot "node_modules"))) {
            & npm.cmd ci
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed." }
        }
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }
    }
    finally { Pop-Location }
}

$dist = Join-Path $frontendRoot "dist"
if (-not (Test-Path (Join-Path $dist "index.html"))) { throw "Frontend dist/index.html not found. Run without -SkipBuild." }

Write-Host "Ensuring private S3 bucket $bucket..."
$bucketExists = $true
try { [void](Invoke-Aws -Arguments @("s3api", "head-bucket", "--bucket", $bucket)) }
catch { $bucketExists = $false }
if (-not $bucketExists) {
    if ($env:AWS_REGION -eq "us-east-1") {
        [void](Invoke-Aws -Arguments @("s3api", "create-bucket", "--bucket", $bucket, "--region", $env:AWS_REGION))
    }
    else {
        [void](Invoke-Aws -Arguments @(
            "s3api", "create-bucket", "--bucket", $bucket, "--region", $env:AWS_REGION,
            "--create-bucket-configuration", "LocationConstraint=$($env:AWS_REGION)"
        ))
    }
}
[void](Invoke-Aws -Arguments @(
    "s3api", "put-public-access-block", "--bucket", $bucket,
    "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
))
$encryptionFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-encryption-$PID.json"
Write-Utf8NoBom $encryptionFile '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
try {
    [void](Invoke-Aws -Arguments @(
        "s3api", "put-bucket-encryption", "--bucket", $bucket,
        "--server-side-encryption-configuration", "file://$encryptionFile"
    ))
}
finally { Remove-Item $encryptionFile -Force -ErrorAction SilentlyContinue }
[void](Invoke-Aws -Arguments @(
    "s3api", "put-bucket-tagging", "--bucket", $bucket,
    "--tagging", "TagSet=[{Key=lz:CostCenter,Value=PlanningSpatial},{Key=lz:BackupPlan,Value=Daily}]"
))

Write-Host "Ensuring CloudFront Origin Access Control..."
$oacId = Get-AwsValue -Arguments @(
    "cloudfront", "list-origin-access-controls",
    "--query", "OriginAccessControlList.Items[?Name=='$oacName'].Id | [0]"
)
if (-not $oacId) {
    $oacFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-oac-$PID.json"
    Write-Utf8NoBom $oacFile (@{
        Name = $oacName
        Description = "Private S3 access for the GIS frontend"
        SigningProtocol = "sigv4"
        SigningBehavior = "always"
        OriginAccessControlOriginType = "s3"
    } | ConvertTo-Json)
    try {
        $oacId = Get-AwsValue -Arguments @(
            "cloudfront", "create-origin-access-control",
            "--origin-access-control-config", "file://$oacFile",
            "--query", "OriginAccessControl.Id"
        )
    }
    finally { Remove-Item $oacFile -Force -ErrorAction SilentlyContinue }
}

Write-Host "Ensuring CloudFront distribution..."
$distributionId = Get-AwsValue -Arguments @(
    "cloudfront", "list-distributions",
    "--query", "DistributionList.Items[?Comment=='$comment'].Id | [0]"
)
if (-not $distributionId) {
    $originDomain = "$bucket.s3.$($env:AWS_REGION).amazonaws.com"
    $distributionConfig = @{
        CallerReference = "$comment-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        Comment = $comment
        Enabled = $true
        HttpVersion = "http2and3"
        DefaultRootObject = "index.html"
        Origins = @{ Quantity = 1; Items = @(@{
            Id = "s3-$bucket"
            DomainName = $originDomain
            OriginPath = ""
            CustomHeaders = @{ Quantity = 0 }
            OriginAccessControlId = $oacId
            S3OriginConfig = @{ OriginAccessIdentity = "" }
            ConnectionAttempts = 3
            ConnectionTimeout = 10
        }) }
        DefaultCacheBehavior = @{
            TargetOriginId = "s3-$bucket"
            ViewerProtocolPolicy = "redirect-to-https"
            CachePolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"
            Compress = $true
            SmoothStreaming = $false
            TrustedSigners = @{ Enabled = $false; Quantity = 0 }
            TrustedKeyGroups = @{ Enabled = $false; Quantity = 0 }
            AllowedMethods = @{
                Quantity = 2
                Items = @("GET", "HEAD")
                CachedMethods = @{ Quantity = 2; Items = @("GET", "HEAD") }
            }
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
    $distributionFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-distribution-$PID.json"
    Write-Utf8NoBom $distributionFile ($distributionConfig | ConvertTo-Json -Depth 20)
    try {
        $distributionId = Get-AwsValue -Arguments @(
            "cloudfront", "create-distribution", "--distribution-config", "file://$distributionFile",
            "--query", "Distribution.Id"
        )
    }
    finally { Remove-Item $distributionFile -Force -ErrorAction SilentlyContinue }
}

$domain = Get-AwsValue -Arguments @(
    "cloudfront", "get-distribution", "--id", $distributionId,
    "--query", "Distribution.DomainName"
)

$policyFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-frontend-policy-$PID.json"
$policy = @{
    Version = "2012-10-17"
    Statement = @(@{
        Sid = "AllowCloudFrontRead"
        Effect = "Allow"
        Principal = @{ Service = "cloudfront.amazonaws.com" }
        Action = "s3:GetObject"
        Resource = "arn:aws:s3:::$bucket/*"
        Condition = @{ StringEquals = @{ "AWS:SourceArn" = "arn:aws:cloudfront::$($env:AWS_ACCOUNT_ID):distribution/$distributionId" } }
    })
}
Write-Utf8NoBom $policyFile ($policy | ConvertTo-Json -Depth 10)
try {
    [void](Invoke-Aws -Arguments @("s3api", "put-bucket-policy", "--bucket", $bucket, "--policy", "file://$policyFile"))
}
finally { Remove-Item $policyFile -Force -ErrorAction SilentlyContinue }

Write-Host "Uploading frontend..."
[void](Invoke-Aws -Arguments @("s3", "sync", $dist, "s3://$bucket", "--delete"))
if (Test-Path (Join-Path $dist "assets")) {
    [void](Invoke-Aws -Arguments @(
        "s3", "cp", (Join-Path $dist "assets"), "s3://$bucket/assets",
        "--recursive", "--cache-control", "public,max-age=31536000,immutable"
    ))
}
foreach ($file in @("index.html", "config.json")) {
    $path = Join-Path $dist $file
    if (Test-Path $path) {
        [void](Invoke-Aws -Arguments @(
            "s3", "cp", $path, "s3://$bucket/$file",
            "--cache-control", "no-cache,no-store,must-revalidate",
            "--content-type", $(if ($file.EndsWith(".json")) { "application/json" } else { "text/html" })
        ))
    }
}
[void](Invoke-Aws -Arguments @(
    "cloudfront", "create-invalidation", "--distribution-id", $distributionId,
    "--paths", "/*"
))

Write-Host ""
Write-Host "Frontend deployment complete: https://$domain" -ForegroundColor Green
Write-Host "CloudFront may take several minutes to become available on the first deployment."
Write-Host "Set FRONTEND_URL=https://$domain in infra/.env and redeploy the API to restrict CORS to this frontend."
