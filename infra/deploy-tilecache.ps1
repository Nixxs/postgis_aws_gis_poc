[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [string]$ImageTag = "",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Deployment config not found: $Path. Copy .env.example to .env first."
    }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) {
            Set-Item -Path "Env:$($parts[0].Trim())" -Value $parts[1].Trim().Trim('"').Trim("'")
        }
    }
}

function Test-RequiredCommand([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $Name"
    }
}

function Test-RequiredSetting([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith("REPLACE_")) {
        throw "Set $Name in $ConfigFile before deploying."
    }
}

function Set-DefaultSetting([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Invoke-Aws([string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $result = (& aws @Arguments --profile $env:AWS_PROFILE --region $env:AWS_REGION --no-cli-pager 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "AWS command failed: aws $($Arguments -join ' ')`n$result"
    }
    return $result
}

function Get-AwsValue([string[]]$Arguments) {
    $value = Invoke-Aws -Arguments ($Arguments + @("--output", "text"))
    if ($value -eq "None") { return "" }
    return $value
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-OrGetRole([string]$Name, [string]$TrustFile, [array]$TagArguments) {
    $roleArn = Get-AwsValue @("iam", "list-roles", "--query", "Roles[?RoleName=='$Name'].Arn | [0]")
    if (-not $roleArn) {
        $arguments = @(
            "iam", "create-role", "--role-name", $Name,
            "--assume-role-policy-document", "file://$TrustFile",
            "--tags", $TagArguments[0], $TagArguments[1]
        )
        if ($env:PERMISSIONS_BOUNDARY_ARN) {
            $arguments += @("--permissions-boundary", $env:PERMISSIONS_BOUNDARY_ARN)
        }
        $roleArn = Get-AwsValue ($arguments + @("--query", "Role.Arn"))
    }
    return $roleArn
}

Import-DotEnv $ConfigFile
Test-RequiredCommand "aws"
Test-RequiredCommand "docker"

@("AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID", "VPC_ID", "SUBNET_IDS", "ASSIGN_PUBLIC_IP", "SECRET_NAME") |
    ForEach-Object { Test-RequiredSetting $_ }

Set-DefaultSetting "TILECACHE_ECR_REPOSITORY" "gis-postgis-tilecache"
Set-DefaultSetting "TILECACHE_BUCKET" "gis-postgis-tilecache-$($env:AWS_ACCOUNT_ID)"
Set-DefaultSetting "TILECACHE_PREFIX" "tiles"
Set-DefaultSetting "TILECACHE_COMPUTE_ENV" "gis-postgis-tilecache-fargate"
Set-DefaultSetting "TILECACHE_JOB_QUEUE" "gis-postgis-tilecache"
Set-DefaultSetting "TILECACHE_JOB_DEFINITION" "gis-postgis-tilecache"
Set-DefaultSetting "TILECACHE_MAX_VCPUS" "16"
Set-DefaultSetting "TILECACHE_JOB_VCPUS" "2"
Set-DefaultSetting "TILECACHE_JOB_MEMORY" "4096"
Set-DefaultSetting "TILECACHE_JOB_TIMEOUT" "86400"

$subnets = $env:SUBNET_IDS.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Trim()
if ($subnets.Count -lt 1) { throw "SUBNET_IDS must contain at least one subnet." }
if ($env:ASSIGN_PUBLIC_IP -notin @("ENABLED", "DISABLED")) { throw "ASSIGN_PUBLIC_IP must be ENABLED or DISABLED." }

$repoRoot = Split-Path $PSScriptRoot -Parent
$tilecacheRoot = Join-Path $repoRoot "tilecache"
$tagArgs = @("Key=lz:CostCenter,Value=PlanningSpatial", "Key=lz:BackupPlan,Value=Daily")
$tags = @{ "lz:CostCenter" = "PlanningSpatial"; "lz:BackupPlan" = "Daily" }
$registry = "$($env:AWS_ACCOUNT_ID).dkr.ecr.$($env:AWS_REGION).amazonaws.com"
if (-not $ImageTag) { $ImageTag = Get-Date -Format "yyyyMMdd-HHmmss" }
$imageUri = "$registry/$($env:TILECACHE_ECR_REPOSITORY):$ImageTag"

Write-Host "Checking AWS identity..."
$account = Get-AwsValue @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $env:AWS_ACCOUNT_ID) {
    throw "AWS profile points to account $account; expected $($env:AWS_ACCOUNT_ID)."
}

$repositoryUri = Get-AwsValue @(
    "ecr", "describe-repositories",
    "--query", "repositories[?repositoryName=='$($env:TILECACHE_ECR_REPOSITORY)'].repositoryUri | [0]"
)
if (-not $repositoryUri) {
    $repositoryUri = Get-AwsValue @(
        "ecr", "create-repository", "--repository-name", $env:TILECACHE_ECR_REPOSITORY,
        "--image-scanning-configuration", "scanOnPush=true", "--tags", $tagArgs[0], $tagArgs[1],
        "--query", "repository.repositoryUri"
    )
}

if (-not $SkipBuild) {
    Write-Host "Building and pushing $imageUri..."
    Push-Location $tilecacheRoot
    try {
        & docker build --platform linux/amd64 --provenance=false --tag $imageUri .
        if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }
        $password = Invoke-Aws @("ecr", "get-login-password")
        $password | & docker login --username AWS --password-stdin $registry
        if ($LASTEXITCODE -ne 0) { throw "Docker registry login failed." }
        & docker push $imageUri
        if ($LASTEXITCODE -ne 0) { throw "Docker push failed." }
    }
    finally {
        Pop-Location
    }
}

Write-Host "Configuring private tile bucket $($env:TILECACHE_BUCKET)..."
$bucketExists = Get-AwsValue @("s3api", "list-buckets", "--query", "Buckets[?Name=='$($env:TILECACHE_BUCKET)'].Name | [0]")
if (-not $bucketExists) {
    if ($env:AWS_REGION -eq "us-east-1") {
        [void](Invoke-Aws @("s3api", "create-bucket", "--bucket", $env:TILECACHE_BUCKET))
    }
    else {
        [void](Invoke-Aws @(
            "s3api", "create-bucket", "--bucket", $env:TILECACHE_BUCKET,
            "--create-bucket-configuration", "LocationConstraint=$($env:AWS_REGION)"
        ))
    }
}
[void](Invoke-Aws @(
    "s3api", "put-public-access-block", "--bucket", $env:TILECACHE_BUCKET,
    "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
))
$encryptionFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-encryption-$PID.json"
Write-Utf8NoBom $encryptionFile (@{
    Rules = @(@{
        ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "AES256" }
        BucketKeyEnabled = $true
    })
} | ConvertTo-Json -Depth 5)
try {
    [void](Invoke-Aws @(
        "s3api", "put-bucket-encryption", "--bucket", $env:TILECACHE_BUCKET,
        "--server-side-encryption-configuration", "file://$encryptionFile"
    ))
}
finally {
    Remove-Item $encryptionFile -Force -ErrorAction SilentlyContinue
}
$bucketTagFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-bucket-tags-$PID.json"
Write-Utf8NoBom $bucketTagFile (@{ TagSet = @(
    @{ Key = "lz:CostCenter"; Value = "PlanningSpatial" },
    @{ Key = "lz:BackupPlan"; Value = "Daily" }
) } | ConvertTo-Json -Depth 4)
try {
    [void](Invoke-Aws @("s3api", "put-bucket-tagging", "--bucket", $env:TILECACHE_BUCKET, "--tagging", "file://$bucketTagFile"))
}
finally {
    Remove-Item $bucketTagFile -Force -ErrorAction SilentlyContinue
}

$secretArn = Get-AwsValue @(
    "secretsmanager", "list-secrets", "--filters", "Key=name,Values=$($env:SECRET_NAME)",
    "--query", "SecretList[?Name=='$($env:SECRET_NAME)'].ARN | [0]"
)
if (-not $secretArn) { throw "Secrets Manager secret '$($env:SECRET_NAME)' does not exist. Deploy the API first." }

$trustFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-trust-$PID.json"
Write-Utf8NoBom $trustFile (@{
    Version = "2012-10-17"
    Statement = @(@{ Effect = "Allow"; Principal = @{ Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" })
} | ConvertTo-Json -Depth 5)
$executionRoleName = "gis-postgis-tilecache-execution-role"
$jobRoleName = "gis-postgis-tilecache-job-role"
try {
    $executionRoleArn = New-OrGetRole $executionRoleName $trustFile $tagArgs
    $jobRoleArn = New-OrGetRole $jobRoleName $trustFile $tagArgs
}
finally {
    Remove-Item $trustFile -Force -ErrorAction SilentlyContinue
}
[void](Invoke-Aws @("iam", "wait", "role-exists", "--role-name", $executionRoleName))
[void](Invoke-Aws @("iam", "wait", "role-exists", "--role-name", $jobRoleName))
[void](Invoke-Aws @(
    "iam", "attach-role-policy", "--role-name", $executionRoleName,
    "--policy-arn", "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
))

$executionPolicyFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-execution-policy-$PID.json"
Write-Utf8NoBom $executionPolicyFile (@{
    Version = "2012-10-17"
    Statement = @(@{ Effect = "Allow"; Action = @("secretsmanager:GetSecretValue"); Resource = $secretArn })
} | ConvertTo-Json -Depth 6)
$jobPolicyFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-job-policy-$PID.json"
Write-Utf8NoBom $jobPolicyFile (@{
    Version = "2012-10-17"
    Statement = @(
        @{ Effect = "Allow"; Action = @("s3:ListBucket"); Resource = "arn:aws:s3:::$($env:TILECACHE_BUCKET)" },
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"); Resource = "arn:aws:s3:::$($env:TILECACHE_BUCKET)/*" }
    )
} | ConvertTo-Json -Depth 6)
try {
    [void](Invoke-Aws @(
        "iam", "put-role-policy", "--role-name", $executionRoleName,
        "--policy-name", "ReadGisDatabaseSecret", "--policy-document", "file://$executionPolicyFile"
    ))
    [void](Invoke-Aws @(
        "iam", "put-role-policy", "--role-name", $jobRoleName,
        "--policy-name", "WriteTileCache", "--policy-document", "file://$jobPolicyFile"
    ))
}
finally {
    Remove-Item $executionPolicyFile, $jobPolicyFile -Force -ErrorAction SilentlyContinue
}

$logGroup = "/aws/batch/$($env:TILECACHE_JOB_DEFINITION)"
$existingLogGroup = Get-AwsValue @(
    "logs", "describe-log-groups", "--log-group-name-prefix", $logGroup,
    "--query", "logGroups[?logGroupName=='$logGroup'].logGroupName | [0]"
)
if (-not $existingLogGroup) {
    [void](Invoke-Aws @("logs", "create-log-group", "--log-group-name", $logGroup))
    [void](Invoke-Aws @(
        "logs", "tag-resource", "--resource-arn", "arn:aws:logs:$($env:AWS_REGION):$($env:AWS_ACCOUNT_ID):log-group:$logGroup",
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily"
    ))
}
[void](Invoke-Aws @("logs", "put-retention-policy", "--log-group-name", $logGroup, "--retention-in-days", "30"))

$taskSecurityGroupId = $env:TASK_SECURITY_GROUP_ID
if (-not $taskSecurityGroupId) {
    $taskSecurityGroupId = Get-AwsValue @(
        "ec2", "describe-security-groups",
        "--filters", "Name=vpc-id,Values=$($env:VPC_ID)", "Name=group-name,Values=gis-postgis-api-task-sg",
        "--query", "SecurityGroups[0].GroupId"
    )
}
if (-not $taskSecurityGroupId) {
    throw "Set TASK_SECURITY_GROUP_ID or deploy the API first so Batch can reuse its database-enabled security group."
}

$computeEnvironmentArn = Get-AwsValue @(
    "batch", "describe-compute-environments", "--compute-environments", $env:TILECACHE_COMPUTE_ENV,
    "--query", "computeEnvironments[0].computeEnvironmentArn"
)
if (-not $computeEnvironmentArn) {
    Write-Host "Creating AWS Batch Fargate compute environment..."
    $computeFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-compute-$PID.json"
    Write-Utf8NoBom $computeFile (@{
        computeEnvironmentName = $env:TILECACHE_COMPUTE_ENV
        type = "MANAGED"
        state = "ENABLED"
        computeResources = @{
            type = "FARGATE"
            maxvCpus = [int]$env:TILECACHE_MAX_VCPUS
            subnets = @($subnets)
            securityGroupIds = @($taskSecurityGroupId)
        }
        tags = $tags
    } | ConvertTo-Json -Depth 8)
    try {
        $computeEnvironmentArn = Get-AwsValue @(
            "batch", "create-compute-environment", "--cli-input-json", "file://$computeFile",
            "--query", "computeEnvironmentArn"
        )
    }
    finally {
        Remove-Item $computeFile -Force -ErrorAction SilentlyContinue
    }
}
else {
    [void](Invoke-Aws @("batch", "update-compute-environment", "--compute-environment", $computeEnvironmentArn, "--state", "ENABLED"))
}

$jobQueueArn = Get-AwsValue @(
    "batch", "describe-job-queues", "--job-queues", $env:TILECACHE_JOB_QUEUE,
    "--query", "jobQueues[0].jobQueueArn"
)
$computeOrder = "order=1,computeEnvironment=$computeEnvironmentArn"
if (-not $jobQueueArn) {
    $jobQueueArn = Get-AwsValue @(
        "batch", "create-job-queue", "--job-queue-name", $env:TILECACHE_JOB_QUEUE,
        "--state", "ENABLED", "--priority", "1", "--compute-environment-order", $computeOrder,
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily", "--query", "jobQueueArn"
    )
}
else {
    [void](Invoke-Aws @(
        "batch", "update-job-queue", "--job-queue", $jobQueueArn, "--state", "ENABLED",
        "--priority", "1", "--compute-environment-order", $computeOrder
    ))
}

Write-Host "Registering AWS Batch job definition..."
$jobDefinitionFile = Join-Path ([System.IO.Path]::GetTempPath()) "tilecache-job-definition-$PID.json"
$containerSecrets = @("DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME") | ForEach-Object {
    @{ name = $_; valueFrom = "${secretArn}:$($_)::" }
}
$jobDefinition = @{
    jobDefinitionName = $env:TILECACHE_JOB_DEFINITION
    type = "container"
    platformCapabilities = @("FARGATE")
    containerProperties = @{
        image = $imageUri
        executionRoleArn = $executionRoleArn
        jobRoleArn = $jobRoleArn
        resourceRequirements = @(
            @{ type = "VCPU"; value = $env:TILECACHE_JOB_VCPUS },
            @{ type = "MEMORY"; value = $env:TILECACHE_JOB_MEMORY }
        )
        environment = @(
            @{ name = "TILE_BUCKET"; value = $env:TILECACHE_BUCKET },
            @{ name = "TILE_PREFIX"; value = $env:TILECACHE_PREFIX },
            @{ name = "TILE_WORKERS"; value = "4" },
            @{ name = "TILE_MAX_TILES"; value = "1000000" }
        )
        secrets = @($containerSecrets)
        networkConfiguration = @{ assignPublicIp = $env:ASSIGN_PUBLIC_IP }
        fargatePlatformConfiguration = @{ platformVersion = "LATEST" }
        runtimePlatform = @{ operatingSystemFamily = "LINUX"; cpuArchitecture = "X86_64" }
        logConfiguration = @{
            logDriver = "awslogs"
            options = @{
                "awslogs-group" = $logGroup
                "awslogs-region" = $env:AWS_REGION
                "awslogs-stream-prefix" = "tilecache"
            }
        }
    }
    retryStrategy = @{
        attempts = 2
        evaluateOnExit = @(
            @{ onExitCode = "2"; action = "EXIT" },
            @{ onReason = "*"; action = "RETRY" }
        )
    }
    timeout = @{ attemptDurationSeconds = [int]$env:TILECACHE_JOB_TIMEOUT }
    propagateTags = $true
    tags = $tags
}
Write-Utf8NoBom $jobDefinitionFile ($jobDefinition | ConvertTo-Json -Depth 12)
try {
    $jobDefinitionArn = Get-AwsValue @(
        "batch", "register-job-definition", "--cli-input-json", "file://$jobDefinitionFile",
        "--query", "jobDefinitionArn"
    )
}
finally {
    Remove-Item $jobDefinitionFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Tile-cache Batch deployment complete."
Write-Host "Bucket:         s3://$($env:TILECACHE_BUCKET)/$($env:TILECACHE_PREFIX)/"
Write-Host "Job queue:      $($env:TILECACHE_JOB_QUEUE)"
Write-Host "Job definition: $jobDefinitionArn"
Write-Host "Submit in AWS Console > Batch > Jobs > Submit new job."
Write-Host "Command example: --layer au_vic_dtp_planning_scheme_all --grid webmercator --min-zoom 0 --max-zoom 12"
