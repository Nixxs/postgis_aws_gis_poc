# Submit one on-demand PostGIS -> S3 tile pyramid to the deployed AWS Batch queue.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_$]*$')]
    [string]$Layer,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_$]*$')]
    [string]$Schema = "public",

    [ValidatePattern('^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$')]
    [string]$Prefix = "tiles",

    [ValidateSet("webmercator", "vicgrid")]
    [string]$Grid = "webmercator",

    [ValidateRange(0, 22)]
    [int]$MinZoom = 0,

    [ValidateRange(0, 22)]
    [int]$MaxZoom = 12,

    [string]$Fields = "*",
    [string]$Version = "",
    [string]$JobName = "",
    [switch]$DryRun,
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env")
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

if ($MinZoom -gt $MaxZoom) { throw "MinZoom must not exceed MaxZoom." }
if ($Grid -eq "vicgrid" -and $MaxZoom -gt 13) { throw "Vicgrid MaxZoom must not exceed 13." }
if ($Fields -notmatch '^\*$|^[A-Za-z_][A-Za-z0-9_$]*(,[A-Za-z_][A-Za-z0-9_$]*)*$') {
    throw "Fields must be '*' or a comma-separated list of simple column names without spaces."
}
if ($Version -and $Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    throw "Version may contain only letters, digits, dots, underscores, and hyphens."
}

$settings = Import-DotEnv $ConfigFile
foreach ($name in @("AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID")) {
    if ([string]::IsNullOrWhiteSpace($settings[$name]) -or $settings[$name].StartsWith("REPLACE_")) {
        throw "Set $name in the deployment config before submitting."
    }
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: aws" }

$queue = if ($settings.TILECACHE_JOB_QUEUE) { $settings.TILECACHE_JOB_QUEUE } else { "gis-postgis-tilecache" }
$jobDefinition = if ($settings.TILECACHE_JOB_DEFINITION) { $settings.TILECACHE_JOB_DEFINITION } else { "gis-postgis-tilecache" }
if (-not $JobName) {
    $suffix = Get-Date -Format "yyyyMMdd-HHmmss"
    $JobName = "tilecache-$Layer-$suffix"
}
# AWS Batch job names permit letters, digits, hyphens, and underscores only.
$JobName = $JobName -replace '[^A-Za-z0-9_-]', '-'
if ($JobName.Length -gt 128) { $JobName = $JobName.Substring(0, 128) }

$command = @(
    "--layer", $Layer,
    "--schema", $Schema,
    "--prefix", $Prefix,
    "--grid", $Grid,
    "--min-zoom", $MinZoom.ToString(),
    "--max-zoom", $MaxZoom.ToString(),
    "--fields", $Fields
)
if ($Version) { $command += @("--version", $Version) }
if ($DryRun) { $command += "--dry-run" }

$inputDocument = @{
    jobName = $JobName
    jobQueue = $queue
    jobDefinition = $jobDefinition
    containerOverrides = @{ command = $command }
    tags = @{
        "lz:CostCenter" = "PlanningSpatial"
        "lz:BackupPlan" = "Daily"
    }
}
$inputPath = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-submit-$([Guid]::NewGuid().ToString('N')).json"
try {
    [System.IO.File]::WriteAllText(
        $inputPath,
        ($inputDocument | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell turns native stderr into ErrorRecord objects. Keep
        # collecting output so the complete AWS CLI error can be reported.
        $ErrorActionPreference = "Continue"
        $result = & aws batch submit-job `
            --cli-input-json "file://$inputPath" `
            --profile $settings.AWS_PROFILE `
            --region $settings.AWS_REGION `
            --output json `
            --no-cli-pager 2>&1
        $awsExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($awsExitCode -ne 0) {
        throw "AWS Batch submission failed (exit $awsExitCode):`n$($result | Out-String)"
    }
}
finally {
    Remove-Item $inputPath -Force -ErrorAction SilentlyContinue
}

$job = $result | Out-String | ConvertFrom-Json
$consoleUrl = "https://$($settings.AWS_REGION).console.aws.amazon.com/batch/home?region=$($settings.AWS_REGION)#jobs/detail/$($job.jobId)"
Write-Host "Submitted tile-cache job." -ForegroundColor Green
Write-Host "Name:    $($job.jobName)"
Write-Host "Job ID:  $($job.jobId)"
Write-Host "Console: $consoleUrl"
Write-Host ""
Write-Host "Check status:"
Write-Host "aws batch describe-jobs --jobs $($job.jobId) --profile $($settings.AWS_PROFILE) --region $($settings.AWS_REGION) --query jobs[0].status --output text --no-cli-pager"
