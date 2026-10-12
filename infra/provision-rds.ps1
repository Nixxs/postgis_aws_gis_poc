# Provision the private, encrypted DTP PostgreSQL RDS instance and persist its
# generated endpoint/password into the ignored deployment config.
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot "dtp.env")
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Deployment config not found: $Path. Copy infra/dtp.env.example to infra/dtp.env first."
    }
    $settings = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) { $settings[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'") }
    }
    return $settings
}

function Test-RequiredSetting([hashtable]$Settings, [string]$Name) {
    $value = [string]$Settings[$Name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith("REPLACE_")) {
        throw "Set $Name in $ConfigFile."
    }
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
    $value = Invoke-Aws ($Arguments + @("--output", "text"))
    if ($value -eq "None") { return "" }
    return $value
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
    $settings[$Name] = $Value
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: aws" }
$settings = Import-DotEnv $ConfigFile
foreach ($name in @(
    "AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID", "VPC_ID", "SUBNET_IDS",
    "RDS_INSTANCE_ID", "RDS_SUBNET_GROUP", "RDS_SECURITY_GROUP_NAME",
    "RDS_INSTANCE_CLASS", "RDS_ALLOCATED_STORAGE", "RDS_BACKUP_RETENTION_DAYS",
    "DB_USER", "DB_PORT", "DB_NAME"
)) { Test-RequiredSetting $settings $name }

if ($settings.AWS_ACCOUNT_ID -notmatch '^\d{12}$') { throw "AWS_ACCOUNT_ID must contain 12 digits." }
if ($settings.DB_NAME -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "DB_NAME must be a valid RDS database name." }
if ($settings.DB_USER -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "DB_USER must be a valid PostgreSQL user name." }
$subnets = @($settings.SUBNET_IDS.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Trim())
if ($subnets.Count -lt 2) { throw "SUBNET_IDS must contain at least two subnets." }

$account = Get-AwsValue @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $settings.AWS_ACCOUNT_ID) { throw "AWS profile points to account $account; expected $($settings.AWS_ACCOUNT_ID)." }

$subnetArguments = @("ec2", "describe-subnets", "--subnet-ids") + $subnets + @(
    "--query", "Subnets[].VpcId", "--output", "text"
)
$vpcText = Invoke-Aws $subnetArguments
$vpcIds = @($vpcText -split '\s+' | Where-Object { $_ })
if (($vpcIds | Select-Object -Unique).Count -ne 1 -or $vpcIds[0] -ne $settings.VPC_ID) {
    throw "Every configured subnet must belong to VPC $($settings.VPC_ID)."
}

$tagArgs = @("Key=lz:CostCenter,Value=PlanningSpatial", "Key=lz:BackupPlan,Value=Daily")

$subnetGroup = Get-AwsValue @(
    "rds", "describe-db-subnet-groups",
    "--query", "DBSubnetGroups[?DBSubnetGroupName=='$($settings.RDS_SUBNET_GROUP)'].DBSubnetGroupName | [0]"
)
if (-not $subnetGroup) {
    $arguments = @(
        "rds", "create-db-subnet-group", "--db-subnet-group-name", $settings.RDS_SUBNET_GROUP,
        "--db-subnet-group-description", "PostGIS POC private subnets", "--subnet-ids"
    ) + $subnets + @("--tags", $tagArgs[0], $tagArgs[1])
    [void](Invoke-Aws $arguments)
    Write-Host "Created DB subnet group $($settings.RDS_SUBNET_GROUP)."
}

$securityGroupId = [string]$settings.DB_SECURITY_GROUP_ID
if (-not $securityGroupId) {
    $securityGroupId = Get-AwsValue @(
        "ec2", "describe-security-groups", "--filters",
        "Name=vpc-id,Values=$($settings.VPC_ID)", "Name=group-name,Values=$($settings.RDS_SECURITY_GROUP_NAME)",
        "--query", "SecurityGroups[0].GroupId"
    )
    if (-not $securityGroupId) {
        $securityGroupId = Get-AwsValue @(
            "ec2", "create-security-group", "--group-name", $settings.RDS_SECURITY_GROUP_NAME,
            "--description", "Private PostgreSQL for the PostGIS POC", "--vpc-id", $settings.VPC_ID,
            "--tag-specifications", "ResourceType=security-group,Tags=[{Key=lz:CostCenter,Value=PlanningSpatial},{Key=lz:BackupPlan,Value=Daily}]",
            "--query", "GroupId"
        )
        Write-Host "Created RDS security group $securityGroupId."
    }
    Set-DotEnvValue $ConfigFile "DB_SECURITY_GROUP_ID" $securityGroupId
}

$instanceStatus = Get-AwsValue @(
    "rds", "describe-db-instances",
    "--query", "DBInstances[?DBInstanceIdentifier=='$($settings.RDS_INSTANCE_ID)'].DBInstanceStatus | [0]"
)

if (-not $instanceStatus) {
    $arguments = @(
        "rds", "create-db-instance",
        "--db-instance-identifier", $settings.RDS_INSTANCE_ID,
        "--db-instance-class", $settings.RDS_INSTANCE_CLASS,
        "--engine", "postgres",
        "--allocated-storage", $settings.RDS_ALLOCATED_STORAGE,
        "--storage-type", "gp3",
        "--db-name", $settings.DB_NAME,
        "--master-username", $settings.DB_USER,
        "--manage-master-user-password",
        "--port", $settings.DB_PORT,
        "--db-subnet-group-name", $settings.RDS_SUBNET_GROUP,
        "--vpc-security-group-ids", $securityGroupId,
        "--storage-encrypted", "--multi-az", "--no-publicly-accessible",
        "--backup-retention-period", $settings.RDS_BACKUP_RETENTION_DAYS,
        "--copy-tags-to-snapshot", "--deletion-protection", "--auto-minor-version-upgrade",
        "--tags", $tagArgs[0], $tagArgs[1]
    )
    if ($settings.RDS_ENGINE_VERSION) { $arguments += @("--engine-version", $settings.RDS_ENGINE_VERSION) }
    [void](Invoke-Aws $arguments)
    Write-Host "RDS creation started. This commonly takes 10-20 minutes."
}
else {
    Write-Host "RDS instance $($settings.RDS_INSTANCE_ID) already exists ($instanceStatus)."
}

Write-Host "Waiting for RDS availability..."
[void](Invoke-Aws @("rds", "wait", "db-instance-available", "--db-instance-identifier", $settings.RDS_INSTANCE_ID))

$details = Invoke-Aws @(
    "rds", "describe-db-instances", "--db-instance-identifier", $settings.RDS_INSTANCE_ID,
    "--query", "DBInstances[0].{Endpoint:Endpoint.Address,Port:Endpoint.Port,SecretArn:MasterUserSecret.SecretArn,Encrypted:StorageEncrypted,MultiAZ:MultiAZ,Public:PubliclyAccessible,DeletionProtection:DeletionProtection}",
    "--output", "json"
) | ConvertFrom-Json
if (-not $details.Encrypted -or -not $details.MultiAZ -or $details.Public -or -not $details.DeletionProtection) {
    throw "RDS exists but does not satisfy encrypted/private/Multi-AZ/deletion-protection requirements."
}
if (-not $details.SecretArn) { throw "RDS does not expose a managed master-user secret ARN." }

$masterSecret = Invoke-Aws @(
    "secretsmanager", "get-secret-value", "--secret-id", $details.SecretArn,
    "--query", "SecretString", "--output", "text"
) | ConvertFrom-Json
if (-not $masterSecret.password) { throw "Managed RDS secret did not contain a password." }

Set-DotEnvValue $ConfigFile "DB_HOST" ([string]$details.Endpoint)
Set-DotEnvValue $ConfigFile "DB_PORT" ([string]$details.Port)
Set-DotEnvValue $ConfigFile "DB_USER" ([string]$masterSecret.username)
Set-DotEnvValue $ConfigFile "DB_PASSWORD" ([string]$masterSecret.password)

Write-Host ""
Write-Host "RDS ready: $($details.Endpoint):$($details.Port)/$($settings.DB_NAME)" -ForegroundColor Green
Write-Host "Connection credentials were written to the ignored config file; the password was not printed."
Write-Host "Next: upload the source archive to the private import bucket, then run the disposable importer."
Write-Host "Guide: infra/S3-DATA-IMPORT.md"
