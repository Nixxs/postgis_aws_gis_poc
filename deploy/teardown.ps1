# ---------------------------------------------------------------------------
# deploy/teardown.ps1
# Terminates the PoC instance(s) and removes the security group + key pair
# created by deploy.ps1.
#
#   .\deploy\teardown.ps1
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$Profile = 'intelligis.io',
    [string]$Region  = 'ap-southeast-2',
    [string]$Name    = 'gis-postgis-poc',
    [string]$KeyName = 'gis-postgis-poc-key'
)

$ErrorActionPreference = 'Stop'
$env:AWS_PROFILE        = $Profile
$env:AWS_DEFAULT_REGION = $Region

function awsq {
    param([Parameter(ValueFromRemainingArguments = $true)]$a)
    $out = & aws @a
    if ($LASTEXITCODE -ne 0) { throw "aws $($a -join ' ') failed (exit $LASTEXITCODE)" }
    return ("$out").Trim()
}

Write-Host "== Tearing down '$Name' in $Region (profile $Profile) ==" -ForegroundColor Cyan

# --- Terminate instances by Name tag ---------------------------------------
$ids = awsq ec2 describe-instances `
    --filters "Name=tag:Name,Values=$Name" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query 'Reservations[].Instances[].InstanceId' --output text
if ($ids) {
    $idList = $ids -split '\s+'
    Write-Host "  Terminating: $($idList -join ', ')" -ForegroundColor DarkGray
    awsq ec2 terminate-instances --instance-ids $idList | Out-Null
    Write-Host "  Waiting for termination..." -ForegroundColor DarkGray
    awsq ec2 wait instance-terminated --instance-ids $idList | Out-Null
} else {
    Write-Host "  No instances to terminate." -ForegroundColor DarkGray
}

# --- Delete security group (retry; ENIs take a moment to detach) ------------
$vpc = awsq ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text
$sg = awsq ec2 describe-security-groups --filters "Name=group-name,Values=$Name-sg" "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[0].GroupId' --output text
if ($sg -and $sg -ne 'None') {
    $deleted = $false
    for ($i = 0; $i -lt 6 -and -not $deleted; $i++) {
        & aws ec2 delete-security-group --group-id $sg 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $deleted = $true; break }
        Start-Sleep -Seconds 10
    }
    if ($deleted) { Write-Host "  Deleted SG $sg" -ForegroundColor DarkGray }
    else { Write-Host "  Could not delete SG $sg yet (dependencies). Re-run later." -ForegroundColor Yellow }
} else {
    Write-Host "  No security group to delete." -ForegroundColor DarkGray
}

# --- Delete key pair + local .pem ------------------------------------------
& aws ec2 delete-key-pair --key-name $KeyName 2>$null | Out-Null
$keyPath = Join-Path $PSScriptRoot "$KeyName.pem"
if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
Write-Host "  Removed key pair $KeyName" -ForegroundColor DarkGray

Write-Host "== Teardown complete ==" -ForegroundColor Green
