# Create the permanent private source-data bucket used by the disposable importer.
[CmdletBinding()]
param([string]$ConfigFile = (Join-Path $PSScriptRoot "dtp.env"))

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Deployment config not found: $Path" }
    $result = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) { $result[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'") }
    }
    return $result
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

function Invoke-AwsDocument([string[]]$Arguments, [string]$Parameter, [object]$Document) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "gis-import-bucket-$([Guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        [void](Invoke-Aws ($Arguments + @($Parameter, "file://$path")))
    }
    finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

$settings = Import-DotEnv $ConfigFile
foreach ($name in @("AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID", "IMPORT_BUCKET")) {
    if ([string]::IsNullOrWhiteSpace($settings[$name]) -or $settings[$name].StartsWith("REPLACE_")) { throw "Set $name in $ConfigFile." }
}
$account = (Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
if ($account -ne $settings.AWS_ACCOUNT_ID) { throw "AWS profile points to account $account; expected $($settings.AWS_ACCOUNT_ID)." }

$exists = $true
$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $null = & aws s3api head-bucket --bucket $settings.IMPORT_BUCKET --expected-bucket-owner $account `
        --profile $settings.AWS_PROFILE --region $settings.AWS_REGION --no-cli-pager 2>&1
    if ($LASTEXITCODE -ne 0) { $exists = $false }
}
finally { $ErrorActionPreference = $previousPreference }

if (-not $exists) {
    # General-purpose buckets now support tags in CreateBucketConfiguration.
    # Supply them on creation so the landing-zone request-tag SCP can evaluate them.
    $creationConfiguration = @{
        Tags = @(
            @{ Key = "lz:CostCenter"; Value = "PlanningSpatial" },
            @{ Key = "lz:BackupPlan"; Value = "Daily" }
        )
    }
    if ($settings.AWS_REGION -ne "us-east-1") {
        $creationConfiguration.LocationConstraint = $settings.AWS_REGION
    }
    Invoke-AwsDocument @("s3api", "create-bucket", "--bucket", $settings.IMPORT_BUCKET) `
        "--create-bucket-configuration" $creationConfiguration
}

Invoke-AwsDocument @("s3api", "put-public-access-block", "--bucket", $settings.IMPORT_BUCKET) `
    "--public-access-block-configuration" @{
        BlockPublicAcls = $true; IgnorePublicAcls = $true
        BlockPublicPolicy = $true; RestrictPublicBuckets = $true
    }
Invoke-AwsDocument @("s3api", "put-bucket-encryption", "--bucket", $settings.IMPORT_BUCKET) `
    "--server-side-encryption-configuration" @{
        Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "AES256" }; BucketKeyEnabled = $true })
    }
Invoke-AwsDocument @("s3api", "put-bucket-tagging", "--bucket", $settings.IMPORT_BUCKET) `
    "--tagging" @{ TagSet = @(
        @{ Key = "lz:CostCenter"; Value = "PlanningSpatial" },
        @{ Key = "lz:BackupPlan"; Value = "Daily" }
    ) }

Write-Host "Source-data bucket ready: s3://$($settings.IMPORT_BUCKET)/" -ForegroundColor Green
Write-Host "The bucket and uploaded source data are retained; importer compute is temporary."
