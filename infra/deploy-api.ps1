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
        if ($parts.Count -ne 2) { continue }
        Set-Item -Path "Env:$($parts[0].Trim())" -Value $parts[1].Trim().Trim('"').Trim("'")
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

function Invoke-Aws([string[]]$Arguments) {
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $result = (& aws @Arguments --profile $env:AWS_PROFILE --region $env:AWS_REGION --no-cli-pager 2>&1 | Out-String).Trim()
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -eq 0) { return $result }

        $isTransient = $result -match "TooManyRequests|Throttl|RequestLimitExceeded|ServiceUnavailable"
        if ($isTransient -and $attempt -lt $maxAttempts) {
            $delaySeconds = [Math]::Pow(2, $attempt)
            Write-Host "AWS request was throttled; retrying in $delaySeconds seconds ($attempt/$maxAttempts)..."
            Start-Sleep -Seconds $delaySeconds
            continue
        }

        throw "AWS command failed: aws $($Arguments -join ' ')`n$result"
    }
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

function Grant-SecurityGroupIngress(
    [string]$GroupId,
    [int]$Port,
    [string]$SourceGroupId
) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $awsError = (& aws ec2 authorize-security-group-ingress `
            --group-id $GroupId `
            --protocol tcp `
            --port $Port `
            --source-group $SourceGroupId `
            --profile $env:AWS_PROFILE `
            --region $env:AWS_REGION `
            --no-cli-pager 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) { return }
    if ($awsError -match "InvalidPermission\.Duplicate") {
        Write-Host "Ingress rule already exists: $SourceGroupId -> $GroupId port $Port"
        return
    }

    throw "Failed to authorize ingress from $SourceGroupId to $GroupId on port ${Port}: $awsError"
}

Import-DotEnv $ConfigFile
Test-RequiredCommand "aws"
Test-RequiredCommand "docker"

$required = @(
    "AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID", "VPC_ID", "SUBNET_IDS",
    "ASSIGN_PUBLIC_IP", "ECR_REPOSITORY", "ECS_CLUSTER", "ECS_SERVICE",
    "TASK_FAMILY", "SECRET_NAME", "ALB_NAME", "TARGET_GROUP_NAME", "HTTP_API_NAME",
    "DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME", "FRONTEND_URL"
)
$required | ForEach-Object { Test-RequiredSetting $_ }

$repoRoot = Split-Path $PSScriptRoot -Parent
$apiRoot = Join-Path $repoRoot "api"
$subnets = $env:SUBNET_IDS.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Trim()
if ($subnets.Count -lt 2) { throw "SUBNET_IDS must contain subnets in at least two Availability Zones." }

$tags = @(
    @{ key = "lz:CostCenter"; value = "PlanningSpatial" },
    @{ key = "lz:BackupPlan"; value = "Daily" }
)
$tagArgs = @("Key=lz:CostCenter,Value=PlanningSpatial", "Key=lz:BackupPlan,Value=Daily")
$ecsTagArgs = @("key=lz:CostCenter,value=PlanningSpatial", "key=lz:BackupPlan,value=Daily")
$registry = "$($env:AWS_ACCOUNT_ID).dkr.ecr.$($env:AWS_REGION).amazonaws.com"
$image = "$registry/$($env:ECR_REPOSITORY)"
if (-not $ImageTag) { $ImageTag = Get-Date -Format "yyyyMMdd-HHmmss" }
$imageUri = "${image}:$ImageTag"

Write-Host "Checking AWS identity..."
$account = Get-AwsValue -Arguments @("sts", "get-caller-identity", "--query", "Account")
if ($account -ne $env:AWS_ACCOUNT_ID) {
    throw "AWS profile points to account $account; expected $($env:AWS_ACCOUNT_ID)."
}

$repositoryUri = Get-AwsValue -Arguments @(
    "ecr", "describe-repositories",
    "--query", "repositories[?repositoryName=='$($env:ECR_REPOSITORY)'].repositoryUri | [0]"
)
if (-not $repositoryUri) {
    $repositoryUri = Get-AwsValue -Arguments @(
        "ecr", "create-repository", "--repository-name", $env:ECR_REPOSITORY,
        "--image-scanning-configuration", "scanOnPush=true",
        "--tags", $tagArgs[0], $tagArgs[1],
        "--query", "repository.repositoryUri"
    )
}

if (-not $SkipBuild) {
    Write-Host "Building $imageUri..."
    Push-Location $apiRoot
    try {
        & docker build --platform linux/amd64 --provenance=false --tag $imageUri .
        if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }

        $loginPassword = Invoke-Aws -Arguments @("ecr", "get-login-password")
        $loginPassword | & docker login --username AWS --password-stdin $registry
        if ($LASTEXITCODE -ne 0) { throw "Docker registry login failed." }

        & docker push $imageUri
        if ($LASTEXITCODE -ne 0) { throw "Docker push failed." }
    }
    finally {
        Pop-Location
    }
}

Write-Host "Updating application secret..."
$secretPayload = @{
    DB_USER = $env:DB_USER
    DB_PASSWORD = $env:DB_PASSWORD
    DB_HOST = $env:DB_HOST
    DB_PORT = $env:DB_PORT
    DB_NAME = $env:DB_NAME
    FRONTEND_URL = $env:FRONTEND_URL
} | ConvertTo-Json -Compress
$secretFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-api-secret-$PID.json"
Write-Utf8NoBom -Path $secretFile -Content $secretPayload
try {
    $secretArn = Get-AwsValue -Arguments @(
        "secretsmanager", "list-secrets", "--filters", "Key=name,Values=$($env:SECRET_NAME)",
        "--query", "SecretList[?Name=='$($env:SECRET_NAME)'].ARN | [0]"
    )
    if ($secretArn) {
        $secretArn = Get-AwsValue -Arguments @(
            "secretsmanager", "put-secret-value", "--secret-id", $env:SECRET_NAME,
            "--secret-string", "file://$secretFile", "--query", "ARN"
        )
    }
    else {
        $secretArn = Get-AwsValue -Arguments @(
            "secretsmanager", "create-secret", "--name", $env:SECRET_NAME,
            "--secret-string", "file://$secretFile", "--tags", $tagArgs[0], $tagArgs[1],
            "--query", "ARN"
        )
    }
}
finally {
    Remove-Item $secretFile -Force -ErrorAction SilentlyContinue
}

$executionRoleName = "gis-postgis-api-execution-role"
$taskRoleName = "gis-postgis-api-task-role"
$trustFile = Join-Path ([System.IO.Path]::GetTempPath()) "ecs-trust-$PID.json"
$trustDocument = @{
    Version = "2012-10-17"
    Statement = @(@{
        Effect = "Allow"
        Principal = @{ Service = "ecs-tasks.amazonaws.com" }
        Action = "sts:AssumeRole"
    })
}
Write-Utf8NoBom -Path $trustFile -Content ($trustDocument | ConvertTo-Json -Depth 5)

try {
    foreach ($roleName in @($executionRoleName, $taskRoleName)) {
        $roleArn = Get-AwsValue -Arguments @(
            "iam", "list-roles", "--query", "Roles[?RoleName=='$roleName'].Arn | [0]"
        )
        if (-not $roleArn) {
            $createRoleArguments = @(
                "iam", "create-role", "--role-name", $roleName,
                "--assume-role-policy-document", "file://$trustFile",
                "--tags", $tagArgs[0], $tagArgs[1]
            )
            if ($env:PERMISSIONS_BOUNDARY_ARN) {
                $createRoleArguments += @("--permissions-boundary", $env:PERMISSIONS_BOUNDARY_ARN)
            }
            [void](Invoke-Aws -Arguments $createRoleArguments)
        }
    }
}
finally {
    Remove-Item $trustFile -Force -ErrorAction SilentlyContinue
}

[void](Invoke-Aws -Arguments @("iam", "wait", "role-exists", "--role-name", $executionRoleName))
[void](Invoke-Aws -Arguments @("iam", "wait", "role-exists", "--role-name", $taskRoleName))

[void](Invoke-Aws -Arguments @(
    "iam", "attach-role-policy", "--role-name", $executionRoleName,
    "--policy-arn", "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
))

$secretPolicyFile = Join-Path ([System.IO.Path]::GetTempPath()) "ecs-secret-policy-$PID.json"
$secretPolicy = @{
    Version = "2012-10-17"
    Statement = @(@{
        Effect = "Allow"
        Action = @("secretsmanager:GetSecretValue")
        Resource = $secretArn
    })
}
Write-Utf8NoBom -Path $secretPolicyFile -Content ($secretPolicy | ConvertTo-Json -Depth 5)
try {
    [void](Invoke-Aws -Arguments @(
        "iam", "put-role-policy", "--role-name", $executionRoleName,
        "--policy-name", "ReadGisApiSecret", "--policy-document", "file://$secretPolicyFile"
    ))
}
finally {
    Remove-Item $secretPolicyFile -Force -ErrorAction SilentlyContinue
}

$logGroup = "/ecs/$($env:TASK_FAMILY)"
$existingLogGroup = Get-AwsValue -Arguments @(
    "logs", "describe-log-groups", "--log-group-name-prefix", $logGroup,
    "--query", "logGroups[?logGroupName=='$logGroup'].logGroupName | [0]"
)
if (-not $existingLogGroup) {
    [void](Invoke-Aws -Arguments @("logs", "create-log-group", "--log-group-name", $logGroup))
    [void](Invoke-Aws -Arguments @(
        "logs", "tag-resource", "--resource-arn",
        "arn:aws:logs:$($env:AWS_REGION):$($env:AWS_ACCOUNT_ID):log-group:$logGroup",
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily"
    ))
}
[void](Invoke-Aws -Arguments @("logs", "put-retention-policy", "--log-group-name", $logGroup, "--retention-in-days", "30"))

Write-Host "Creating a new task definition revision..."
$taskDefinitionFile = Join-Path ([System.IO.Path]::GetTempPath()) "gis-api-task-$PID.json"
$containerSecrets = @("DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME", "FRONTEND_URL") | ForEach-Object {
    @{ name = $_; valueFrom = "${secretArn}:$($_)::" }
}
$taskDefinition = @{
    family = $env:TASK_FAMILY
    taskRoleArn = "arn:aws:iam::$($env:AWS_ACCOUNT_ID):role/$taskRoleName"
    executionRoleArn = "arn:aws:iam::$($env:AWS_ACCOUNT_ID):role/$executionRoleName"
    networkMode = "awsvpc"
    requiresCompatibilities = @("FARGATE")
    cpu = "512"
    memory = "1024"
    runtimePlatform = @{ operatingSystemFamily = "LINUX"; cpuArchitecture = "X86_64" }
    containerDefinitions = @(@{
        name = "api"
        image = $imageUri
        essential = $true
        portMappings = @(@{ containerPort = 8000; hostPort = 8000; protocol = "tcp" })
        environment = @(
            @{ name = "ENV_STATE"; value = "" },
            @{ name = "DB_FORCE_ROLL_BACK"; value = "false" }
        )
        secrets = @($containerSecrets)
        logConfiguration = @{
            logDriver = "awslogs"
            options = @{
                "awslogs-group" = $logGroup
                "awslogs-region" = $env:AWS_REGION
                "awslogs-stream-prefix" = "api"
            }
        }
    })
    tags = $tags
}
Write-Utf8NoBom -Path $taskDefinitionFile -Content ($taskDefinition | ConvertTo-Json -Depth 12)
try {
    $taskDefinitionArn = Get-AwsValue -Arguments @(
        "ecs", "register-task-definition", "--cli-input-json", "file://$taskDefinitionFile",
        "--query", "taskDefinition.taskDefinitionArn"
    )
}
finally {
    Remove-Item $taskDefinitionFile -Force -ErrorAction SilentlyContinue
}

[void](Invoke-Aws -Arguments @("ecs", "create-cluster", "--cluster-name", $env:ECS_CLUSTER, "--tags", $ecsTagArgs[0], $ecsTagArgs[1]))

function Get-OrCreate-SecurityGroup([string]$Name, [string]$Description) {
    $groupId = Get-AwsValue -Arguments @(
        "ec2", "describe-security-groups",
        "--filters", "Name=vpc-id,Values=$($env:VPC_ID)", "Name=group-name,Values=$Name",
        "--query", "SecurityGroups[0].GroupId"
    )
    if (-not $groupId) {
        $groupId = Get-AwsValue -Arguments @(
            "ec2", "create-security-group", "--group-name", $Name,
            "--description", $Description, "--vpc-id", $env:VPC_ID,
            "--tag-specifications",
            "ResourceType=security-group,Tags=[{Key=lz:CostCenter,Value=PlanningSpatial},{Key=lz:BackupPlan,Value=Daily}]",
            "--query", "GroupId"
        )
    }
    return $groupId
}

$taskSecurityGroupId = $env:TASK_SECURITY_GROUP_ID
if (-not $taskSecurityGroupId) {
    $taskSecurityGroupId = Get-OrCreate-SecurityGroup "gis-postgis-api-task-sg" "ECS tasks for the GIS API"
}
$albSecurityGroupId = Get-OrCreate-SecurityGroup "gis-postgis-api-alb-sg" "Internal ALB for the GIS API"
$vpcLinkSecurityGroupId = Get-OrCreate-SecurityGroup "gis-postgis-api-vpclink-sg" "API Gateway VPC Link for the GIS API"
Grant-SecurityGroupIngress -GroupId $albSecurityGroupId -Port 80 -SourceGroupId $vpcLinkSecurityGroupId
Grant-SecurityGroupIngress -GroupId $taskSecurityGroupId -Port 8000 -SourceGroupId $albSecurityGroupId
if ($env:DB_SECURITY_GROUP_ID) {
    Grant-SecurityGroupIngress -GroupId $env:DB_SECURITY_GROUP_ID -Port ([int]$env:DB_PORT) -SourceGroupId $taskSecurityGroupId
}
else {
    Write-Warning "DB_SECURITY_GROUP_ID is empty. Ensure the database permits connections from the ECS task security group."
}

$targetGroupArn = Get-AwsValue -Arguments @(
    "elbv2", "describe-target-groups",
    "--query", "TargetGroups[?TargetGroupName=='$($env:TARGET_GROUP_NAME)'].TargetGroupArn | [0]"
)
if (-not $targetGroupArn) {
    $targetGroupArn = Get-AwsValue -Arguments @(
        "elbv2", "create-target-group", "--name", $env:TARGET_GROUP_NAME,
        "--protocol", "HTTP", "--port", "8000", "--target-type", "ip",
        "--vpc-id", $env:VPC_ID, "--health-check-path", "/health",
        "--health-check-interval-seconds", "30", "--healthy-threshold-count", "2",
        "--unhealthy-threshold-count", "3", "--tags", $tagArgs[0], $tagArgs[1],
        "--query", "TargetGroups[0].TargetGroupArn"
    )
}

$albArn = Get-AwsValue -Arguments @(
    "elbv2", "describe-load-balancers",
    "--query", "LoadBalancers[?LoadBalancerName=='$($env:ALB_NAME)'].LoadBalancerArn | [0]"
)
if (-not $albArn) {
    $createAlbArguments = @(
        "elbv2", "create-load-balancer", "--name", $env:ALB_NAME,
        "--scheme", "internal", "--type", "application", "--ip-address-type", "ipv4",
        "--subnets"
    ) + $subnets + @(
        "--security-groups", $albSecurityGroupId,
        "--tags", $tagArgs[0], $tagArgs[1],
        "--query", "LoadBalancers[0].LoadBalancerArn"
    )
    $albArn = Get-AwsValue -Arguments $createAlbArguments
    [void](Invoke-Aws -Arguments @("elbv2", "wait", "load-balancer-available", "--load-balancer-arns", $albArn))
}

$listenerArn = Get-AwsValue -Arguments @(
    "elbv2", "describe-listeners", "--load-balancer-arn", $albArn,
    "--query", 'Listeners[?Port==`80`].ListenerArn | [0]'
)
if (-not $listenerArn) {
    $listenerArn = Get-AwsValue -Arguments @(
        "elbv2", "create-listener", "--load-balancer-arn", $albArn,
        "--protocol", "HTTP", "--port", "80",
        "--default-actions", "Type=forward,TargetGroupArn=$targetGroupArn",
        "--tags", $tagArgs[0], $tagArgs[1], "--query", "Listeners[0].ListenerArn"
    )
}
else {
    [void](Invoke-Aws -Arguments @(
        "elbv2", "modify-listener", "--listener-arn", $listenerArn,
        "--default-actions", "Type=forward,TargetGroupArn=$targetGroupArn"
    ))
}

$serviceArn = Get-AwsValue -Arguments @(
    "ecs", "list-services", "--cluster", $env:ECS_CLUSTER,
    "--query", "serviceArns[?ends_with(@, '/$($env:ECS_SERVICE)')] | [0]"
)
$networkConfiguration = "awsvpcConfiguration={subnets=[$($subnets -join ',')],securityGroups=[$taskSecurityGroupId],assignPublicIp=$($env:ASSIGN_PUBLIC_IP)}"
$loadBalancer = "targetGroupArn=$targetGroupArn,containerName=api,containerPort=8000"
if ($serviceArn) {
    [void](Invoke-Aws -Arguments @(
        "ecs", "update-service", "--cluster", $env:ECS_CLUSTER,
        "--service", $env:ECS_SERVICE, "--task-definition", $taskDefinitionArn,
        "--desired-count", "1", "--force-new-deployment",
        "--network-configuration", $networkConfiguration,
        "--load-balancers", $loadBalancer,
        "--health-check-grace-period-seconds", "60"
    ))
}
else {
    [void](Invoke-Aws -Arguments @(
        "ecs", "create-service", "--cluster", $env:ECS_CLUSTER,
        "--service-name", $env:ECS_SERVICE, "--task-definition", $taskDefinitionArn,
        "--desired-count", "1", "--launch-type", "FARGATE",
        "--network-configuration", $networkConfiguration,
        "--load-balancers", $loadBalancer,
        "--health-check-grace-period-seconds", "60",
        "--enable-execute-command", "--tags", $ecsTagArgs[0], $ecsTagArgs[1]
    ))
}

Write-Host "Waiting for the ECS service..."
[void](Invoke-Aws -Arguments @("ecs", "wait", "services-stable", "--cluster", $env:ECS_CLUSTER, "--services", $env:ECS_SERVICE))

$vpcLinkId = Get-AwsValue -Arguments @(
    "apigatewayv2", "get-vpc-links",
    "--query", "Items[?Name=='$($env:HTTP_API_NAME)-link'].VpcLinkId | [0]"
)
if (-not $vpcLinkId) {
    $createVpcLinkArguments = @(
        "apigatewayv2", "create-vpc-link", "--name", "$($env:HTTP_API_NAME)-link",
        "--subnet-ids"
    ) + $subnets + @(
        "--security-group-ids", $vpcLinkSecurityGroupId,
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily",
        "--query", "VpcLinkId"
    )
    $vpcLinkId = Get-AwsValue -Arguments $createVpcLinkArguments
}

Write-Host "Waiting for the API Gateway VPC link..."
$deadline = (Get-Date).AddMinutes(10)
do {
    $vpcLinkStatus = Get-AwsValue -Arguments @(
        "apigatewayv2", "get-vpc-link", "--vpc-link-id", $vpcLinkId, "--query", "VpcLinkStatus"
    )
    if ($vpcLinkStatus -eq "FAILED") { throw "API Gateway VPC link creation failed." }
    if ($vpcLinkStatus -ne "AVAILABLE") { Start-Sleep -Seconds 10 }
} while ($vpcLinkStatus -ne "AVAILABLE" -and (Get-Date) -lt $deadline)
if ($vpcLinkStatus -ne "AVAILABLE") { throw "Timed out waiting for the API Gateway VPC link." }

$apiId = Get-AwsValue -Arguments @(
    "apigatewayv2", "get-apis", "--query", "Items[?Name=='$($env:HTTP_API_NAME)'].ApiId | [0]"
)
if (-not $apiId) {
    $apiId = Get-AwsValue -Arguments @(
        "apigatewayv2", "create-api", "--name", $env:HTTP_API_NAME,
        "--protocol-type", "HTTP",
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily",
        "--query", "ApiId"
    )
}

$integrationId = Get-AwsValue -Arguments @(
    "apigatewayv2", "get-integrations", "--api-id", $apiId,
    "--query", "Items[?IntegrationUri=='$listenerArn'].IntegrationId | [0]"
)
if (-not $integrationId) {
    $integrationId = Get-AwsValue -Arguments @(
        "apigatewayv2", "create-integration", "--api-id", $apiId,
        "--integration-type", "HTTP_PROXY", "--integration-method", "ANY",
        "--integration-uri", $listenerArn, "--connection-type", "VPC_LINK",
        "--connection-id", $vpcLinkId, "--payload-format-version", "1.0",
        "--timeout-in-millis", "30000", "--query", "IntegrationId"
    )
}

$routeId = Get-AwsValue -Arguments @(
    "apigatewayv2", "get-routes", "--api-id", $apiId,
    "--query", "Items[?RouteKey=='`$default'].RouteId | [0]"
)
if ($routeId) {
    [void](Invoke-Aws -Arguments @(
        "apigatewayv2", "update-route", "--api-id", $apiId,
        "--route-id", $routeId, "--target", "integrations/$integrationId"
    ))
}
else {
    [void](Invoke-Aws -Arguments @(
        "apigatewayv2", "create-route", "--api-id", $apiId,
        "--route-key", "`$default", "--target", "integrations/$integrationId"
    ))
}

$stageName = Get-AwsValue -Arguments @(
    "apigatewayv2", "get-stages", "--api-id", $apiId,
    "--query", "Items[?StageName=='`$default'].StageName | [0]"
)
if (-not $stageName) {
    [void](Invoke-Aws -Arguments @(
        "apigatewayv2", "create-stage", "--api-id", $apiId,
        "--stage-name", "`$default", "--auto-deploy",
        "--tags", "lz:CostCenter=PlanningSpatial,lz:BackupPlan=Daily"
    ))
}

$publicUrl = "https://$apiId.execute-api.$($env:AWS_REGION).amazonaws.com"
Write-Host ""
Write-Host "Deployment complete: $publicUrl"
Write-Host "Health: $publicUrl/health"
Write-Host "Docs:   $publicUrl/docs"
