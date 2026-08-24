# ---------------------------------------------------------------------------
# deploy/deploy.ps1
# Launches a single EC2 instance that runs the whole stack via docker compose.
# Uses the account's DEFAULT VPC (no networking to build). On first boot the
# instance installs Docker, clones the repo, and runs `docker compose up`.
#
#   .\deploy\deploy.ps1
#
# Idempotent-ish: reuses the security group / key pair if they already exist,
# but always launches a NEW instance. Use teardown.ps1 to clean up.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$Profile      = 'intelligis.io',
    [string]$Region       = 'ap-southeast-2',
    [string]$Name         = 'gis-postgis-poc',
    [string]$InstanceType = 't3.small',
    [string]$KeyName      = 'gis-postgis-poc-key'
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

Write-Host "== Deploying '$Name' to $Region (profile $Profile) ==" -ForegroundColor Cyan

# --- Default VPC + subnet --------------------------------------------------
$vpc = awsq ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text
if (-not $vpc -or $vpc -eq 'None') { throw "No default VPC found in $Region. Create one or pick another region." }
$subnet = awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text
Write-Host "  VPC     $vpc / subnet $subnet" -ForegroundColor DarkGray

# --- Security group (open 80 + 22) -----------------------------------------
$sg = awsq ec2 describe-security-groups --filters "Name=group-name,Values=$Name-sg" "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[0].GroupId' --output text
if (-not $sg -or $sg -eq 'None') {
    $sg = awsq ec2 create-security-group --group-name "$Name-sg" --description "$Name http and ssh" --vpc-id $vpc --query 'GroupId' --output text
    awsq ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null
    awsq ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr 0.0.0.0/0 | Out-Null
    Write-Host "  SG      $sg (created; :80 and :22 open to the internet)" -ForegroundColor DarkGray
} else {
    Write-Host "  SG      $sg (existing)" -ForegroundColor DarkGray
}

# --- Key pair --------------------------------------------------------------
$keyPath = Join-Path $PSScriptRoot "$KeyName.pem"
$keyExists = & aws ec2 describe-key-pairs --key-names $KeyName 2>$null
if ($LASTEXITCODE -ne 0) {
    $pem = awsq ec2 create-key-pair --key-name $KeyName --query 'KeyMaterial' --output text
    Set-Content -Path $keyPath -Value $pem -NoNewline -Encoding ascii
    Write-Host "  Key     $KeyName (created; private key saved to $keyPath)" -ForegroundColor DarkGray
} else {
    Write-Host "  Key     $KeyName (existing)" -ForegroundColor DarkGray
}

# --- Latest Amazon Linux 2023 AMI ------------------------------------------
$ami = awsq ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[0].Value' --output text
Write-Host "  AMI     $ami" -ForegroundColor DarkGray

# --- Launch ----------------------------------------------------------------
$udPath  = (Join-Path $PSScriptRoot 'user-data.sh') -replace '\\', '/'
$userUri = "file://$udPath"
$id = awsq ec2 run-instances `
    --image-id $ami `
    --instance-type $InstanceType `
    --key-name $KeyName `
    --security-group-ids $sg `
    --subnet-id $subnet `
    --associate-public-ip-address `
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}" `
    --user-data $userUri `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
    --query 'Instances[0].InstanceId' --output text

Write-Host "  Instance $id launching; waiting for 'running' state..." -ForegroundColor DarkGray
awsq ec2 wait instance-running --instance-ids $id | Out-Null
$ip = awsq ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

Write-Host ""
Write-Host "== Instance $id is running ==" -ForegroundColor Green
Write-Host "  App URL : http://$ip/         (docs at http://$ip/docs)"
Write-Host "  SSH     : ssh -i `"$keyPath`" ec2-user@$ip"
Write-Host ""
Write-Host "First boot installs Docker and builds the image - allow ~3-5 minutes." -ForegroundColor Yellow
Write-Host "Watch progress via SSH: sudo tail -f /var/log/cloud-init-output.log" -ForegroundColor Yellow
