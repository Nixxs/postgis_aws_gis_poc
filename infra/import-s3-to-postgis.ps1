# Build and run a disposable VPC-local GDAL task that imports an S3 object into PostGIS.
# The source bucket/object and database tables are retained. Import-only AWS resources
# (ECR repository/image, ECS cluster/task definition, security group and log group)
# are removed in the finally block, including after an import failure.
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot "dtp.env"),
    [string]$ManifestFile = (Join-Path $PSScriptRoot "import-manifest.json"),
    [int]$UrlExpirySeconds = 43200,
    [switch]$InspectOnly
)

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

function Test-Setting([string]$Name) {
    $value = [string]$settings[$Name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith("REPLACE_")) { throw "Set $Name in $ConfigFile." }
}

function Invoke-Aws([string[]]$Arguments, [switch]$AllowFailure) {
    $previousPreference = $ErrorActionPreference
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $ErrorActionPreference = "Continue"
        $result = (& aws @Arguments --profile $settings.AWS_PROFILE --region $settings.AWS_REGION --no-cli-pager 2>$errorFile | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        $errorText = [System.IO.File]::ReadAllText($errorFile).Trim()
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item $errorFile -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "AWS command failed: aws $($Arguments -join ' ')`n$errorText`n$result" }
    return @{ Output = $result; Error = $errorText; ExitCode = $exitCode }
}

function Invoke-ImporterDocker([string[]]$Arguments, [string]$InputText = "") {
    $previousPreference = $ErrorActionPreference
    try {
        # Docker writes normal build progress to stderr, not just errors.
        # Render captured error records as plain strings, without PowerShell's
        # misleading NativeCommandError wrapper for successful build progress.
        $ErrorActionPreference = "Continue"
        if ($InputText) {
            $InputText | & docker @Arguments 2>&1 | ForEach-Object { Write-Host $_.ToString() }
        }
        else {
            & docker @Arguments 2>&1 | ForEach-Object { Write-Host $_.ToString() }
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "Docker command failed (exit $exitCode): $($Arguments -join ' '). Review the Docker output above."
    }
}

function New-ImporterDockerAuthDocument([string]$Registry, [string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { throw "ECR returned an empty authentication token." }
    return @{
        auths = @{
            $Registry = @{ auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("AWS:$Token")) }
        }
    }
}

function Push-ImporterImage([string]$Registry, [string]$ImageUri, [string]$Token) {
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) "gis-import-docker-$([Guid]::NewGuid().ToString('N'))"
    try {
        [void][System.IO.Directory]::CreateDirectory($directory)
        $document = New-ImporterDockerAuthDocument $Registry $Token
        # Preserve context metadata, but never copy existing auths/credential helpers.
        # Populated auths suppress Docker's automatic default credential-store selection.
        $originalDirectory = $env:DOCKER_CONFIG
        if (-not $originalDirectory) { $originalDirectory = Join-Path $HOME ".docker" }
        $originalFile = Join-Path $originalDirectory "config.json"
        if (Test-Path $originalFile) {
            $original = Get-Content $originalFile -Raw | ConvertFrom-Json
            if ($original.currentContext) { $document.currentContext = $original.currentContext }
        }
        $contexts = Join-Path $originalDirectory "contexts"
        if (Test-Path $contexts) { Copy-Item $contexts -Destination $directory -Recurse }
        [System.IO.File]::WriteAllText(
            (Join-Path $directory "config.json"), ($document | ConvertTo-Json -Depth 10 -Compress),
            (New-Object System.Text.UTF8Encoding($false))
        )
        # No docker login: the scoped ECR token is used directly for this push only.
        Invoke-ImporterDocker @("--config", $directory, "push", $ImageUri)
    }
    finally {
        # The auth value is base64, not encryption. Delete it on success or failure.
        if (Test-Path $directory) { Remove-Item $directory -Recurse -Force }
    }
}

function Get-CleanupIdentifiers([hashtable]$Result, [string]$Pattern) {
    # Failed requests may contain CLI usage text. Never interpret it as resource IDs.
    if ($Result.ExitCode -ne 0) { return }
    $Result.Output -split '\s+' | Where-Object { $_ -match $Pattern }
}

function Get-AwsValue([string[]]$Arguments) {
    # JSON applies --query after pagination; text applies it separately per page,
    # potentially returning several "None" lines followed by an ARN.
    $result = Invoke-Aws ($Arguments + @("--output", "json"))
    $value = ConvertFrom-Json -InputObject $result.Output
    if ($null -eq $value) { return "" }
    if ($value -isnot [string] -and $value -isnot [ValueType]) {
        throw "AWS scalar lookup returned a collection instead of a single value."
    }
    if ([string]$value -match '[\r\n]') { throw "AWS scalar lookup returned a multiline value." }
    return [string]$value
}

function Invoke-CleanupAws([string[]]$Arguments, [string]$Description) {
    $result = Invoke-Aws $Arguments -AllowFailure
    $message = "$($result.Error)`n$($result.Output)"
    if ($result.ExitCode -ne 0 -and $message -notmatch "not found|not exist|ClusterNotFound|RepositoryNotFound|ResourceNotFound|InvalidGroup\.NotFound|InvalidPermission\.NotFound") {
        $script:cleanupFailed = $true
        Write-Warning "Cleanup could not $Description`: $message"
    }
    return $result
}

function Write-JsonFile([object]$Document, [string]$Prefix) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "$Prefix-$([Guid]::NewGuid().ToString('N')).json"
    [System.IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 20 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $script:temporaryFiles.Add($path)
    return $path
}

function Remove-TemporarySecurityGroup([string]$GroupId) {
    if ($GroupId -notmatch '^sg-[0-9a-f]+$') { return }
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $result = Invoke-Aws @("ec2", "delete-security-group", "--group-id", $GroupId) -AllowFailure
        $message = "$($result.Error)`n$($result.Output)"
        if ($result.ExitCode -eq 0 -or $message -match "InvalidGroup\.NotFound") { return }
        if ($message -notmatch "DependencyViolation" -or $attempt -eq 12) {
            $script:cleanupFailed = $true
            Write-Warning "Could not delete temporary security group ${GroupId}: $message"
            return
        }
        Start-Sleep -Seconds 5
    }
}

foreach ($command in @("aws", "docker")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $command" }
}
if (-not (Test-Path $ManifestFile)) {
    throw "Import manifest not found: $ManifestFile. Copy infra/import-manifest.example.json to infra/import-manifest.json and edit it."
}
if ($UrlExpirySeconds -lt 3600 -or $UrlExpirySeconds -gt 604800) { throw "UrlExpirySeconds must be between 3600 and 604800." }

$settings = Import-DotEnv $ConfigFile
foreach ($name in @(
    "AWS_PROFILE", "AWS_REGION", "AWS_ACCOUNT_ID", "VPC_ID", "SUBNET_IDS", "ASSIGN_PUBLIC_IP",
    "IMPORT_BUCKET", "DB_SECURITY_GROUP_ID", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD",
    "SECRET_NAME", "API_EXECUTION_ROLE_ARN", "API_TASK_ROLE_ARN"
)) { Test-Setting $name }
if ($settings.ASSIGN_PUBLIC_IP -notin @("ENABLED", "DISABLED")) { throw "ASSIGN_PUBLIC_IP must be ENABLED or DISABLED." }

$manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
if (-not $manifest.s3Bucket -or -not $manifest.s3Key -or -not $manifest.layers -or $manifest.layers.Count -lt 1) {
    throw "Manifest requires s3Bucket, s3Key and at least one layer."
}
if ($manifest.s3Bucket -ne $settings.IMPORT_BUCKET) { throw "Manifest s3Bucket must equal IMPORT_BUCKET in $ConfigFile." }
foreach ($layer in $manifest.layers) {
    if ($layer.source -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $layer.target -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Layer names must be unqualified identifiers: $($layer.source) -> $($layer.target)"
    }
}

Write-Host "Checking Docker Linux engine before creating any importer resources..."
Invoke-ImporterDocker @("info", "--format", "{{.OSType}}")

$account = (Get-AwsValue @("sts", "get-caller-identity", "--query", "Account")).Trim()
if ($account -ne $settings.AWS_ACCOUNT_ID) { throw "AWS profile points to account $account; expected $($settings.AWS_ACCOUNT_ID)." }
[void](Invoke-Aws @("s3api", "head-object", "--bucket", $manifest.s3Bucket, "--key", $manifest.s3Key, "--expected-bucket-owner", $account))

$repoRoot = Split-Path $PSScriptRoot -Parent
$importerRoot = Join-Path $repoRoot "importer"
$token = (Get-Date -Format "yyyyMMddHHmmss") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 6))
$name = "gis-postgis-import-$token"
$repositoryName = $name
$clusterName = $name
$taskFamily = $name
$securityGroupName = "$name-sg"
$logGroup = "/ecs/$name"
$registry = "$account.dkr.ecr.$($settings.AWS_REGION).amazonaws.com"
$imageUri = "$registry/${repositoryName}:import"
$subnets = @($settings.SUBNET_IDS.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Trim())
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
$securityGroupId = ""
$taskDefinitionArn = ""
$taskArn = ""
$importSucceeded = $false
$cleanupFailed = $false

try {
    Write-Host "Creating temporary importer image repository..."
    [void](Invoke-Aws @(
        "ecr", "create-repository", "--repository-name", $repositoryName,
        "--image-scanning-configuration", "scanOnPush=true",
        "--tags", "Key=lz:CostCenter,Value=PlanningSpatial", "Key=lz:BackupPlan,Value=Daily"
    ))

    Write-Host "Building and pushing pinned GDAL importer image..."
    Push-Location $importerRoot
    try {
        Invoke-ImporterDocker @("build", "--platform", "linux/amd64", "--provenance=false", "--tag", $imageUri, ".")
        $password = (Invoke-Aws @("ecr", "get-login-password")).Output
        Push-ImporterImage $registry $imageUri $password
    }
    finally { Pop-Location }

    if ($InspectOnly) {
        Write-Host "Using existing database secret for read-only inspection..."
        $secretArn = Get-AwsValue @("secretsmanager", "describe-secret", "--secret-id", $settings.SECRET_NAME, "--query", "ARN")
    }
    else {
        Write-Host "Storing database configuration in the permanent API secret..."
        $secretDocument = @{
            DB_HOST = $settings.DB_HOST; DB_PORT = $settings.DB_PORT; DB_NAME = $settings.DB_NAME
            DB_USER = $settings.DB_USER; DB_PASSWORD = $settings.DB_PASSWORD
            FRONTEND_URL = $settings.FRONTEND_URL; FRONTEND_OL_URL = $settings.FRONTEND_OL_URL
        }
        $secretFile = Write-JsonFile $secretDocument "gis-import-secret"
        $secretArn = Get-AwsValue @("secretsmanager", "list-secrets", "--query", "SecretList[?Name=='$($settings.SECRET_NAME)'].ARN | [0]")
        if ($secretArn) {
            [void](Invoke-Aws @("secretsmanager", "put-secret-value", "--secret-id", $secretArn, "--secret-string", "file://$secretFile"))
        }
        else {
            $secretArn = Get-AwsValue @(
                "secretsmanager", "create-secret", "--name", $settings.SECRET_NAME,
                "--secret-string", "file://$secretFile",
                "--tags", "Key=lz:CostCenter,Value=PlanningSpatial", "Key=lz:BackupPlan,Value=Daily",
                "--query", "ARN"
            )
        }
        Write-Host "Creating temporary VPC resources..."
    }
    if ($InspectOnly) { Write-Host "Creating temporary read-only inspection resources..." }
    $securityGroupId = Get-AwsValue @(
        "ec2", "create-security-group", "--group-name", $securityGroupName,
        "--description", "Disposable S3 to PostGIS importer", "--vpc-id", $settings.VPC_ID,
        "--tag-specifications", "ResourceType=security-group,Tags=[{Key=lz:CostCenter,Value=PlanningSpatial},{Key=lz:BackupPlan,Value=Daily}]",
        "--query", "GroupId"
    )
    [void](Invoke-Aws @(
        "ec2", "authorize-security-group-ingress", "--group-id", $settings.DB_SECURITY_GROUP_ID,
        "--protocol", "tcp", "--port", $settings.DB_PORT, "--source-group", $securityGroupId
    ))
    [void](Invoke-Aws @("logs", "create-log-group", "--log-group-name", $logGroup))
    [void](Invoke-Aws @("logs", "put-retention-policy", "--log-group-name", $logGroup, "--retention-in-days", "1"))
    [void](Invoke-Aws @("ecs", "create-cluster", "--cluster-name", $clusterName, "--tags", "key=lz:CostCenter,value=PlanningSpatial", "key=lz:BackupPlan,value=Daily"))

    $manifestJson = $manifest | ConvertTo-Json -Depth 10 -Compress
    $secretKeys = @("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD") | ForEach-Object {
        @{ name = $_; valueFrom = "${secretArn}:$($_)::" }
    }
    $taskDocument = @{
        family = $taskFamily
        networkMode = "awsvpc"
        requiresCompatibilities = @("FARGATE")
        cpu = "4096"
        memory = "16384"
        ephemeralStorage = @{ sizeInGiB = 100 }
        executionRoleArn = $settings.API_EXECUTION_ROLE_ARN
        taskRoleArn = $settings.API_TASK_ROLE_ARN
        containerDefinitions = @(@{
            name = "importer"; image = $imageUri; essential = $true
            environment = @(
                @{ name = "SOURCE_URL"; value = "PRESIGNED_URL_PLACEHOLDER" },
                @{ name = "SOURCE_FILENAME"; value = [System.IO.Path]::GetFileName([string]$manifest.s3Key) },
                @{ name = "IMPORT_MANIFEST"; value = $manifestJson },
                @{ name = "IMPORT_MODE"; value = $(if ($InspectOnly) { "inspect" } else { "import" }) }
            )
            secrets = @($secretKeys)
            logConfiguration = @{
                logDriver = "awslogs"
                options = @{ "awslogs-group" = $logGroup; "awslogs-region" = $settings.AWS_REGION; "awslogs-stream-prefix" = "import" }
            }
        })
        tags = @(
            @{ key = "lz:CostCenter"; value = "PlanningSpatial" },
            @{ key = "lz:BackupPlan"; value = "Daily" }
        )
    }

    # Generate the URL only immediately before task registration so its full lifetime is available to the import.
    $sourceUrl = (& aws s3 presign "s3://$($manifest.s3Bucket)/$($manifest.s3Key)" --expires-in $UrlExpirySeconds `
        --profile $settings.AWS_PROFILE --region $settings.AWS_REGION | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sourceUrl) { throw "Could not generate the temporary S3 download URL." }
    $taskDocument.containerDefinitions[0].environment[0].value = $sourceUrl
    $taskFile = Write-JsonFile $taskDocument "gis-import-task"
    $taskDefinitionArn = Get-AwsValue @("ecs", "register-task-definition", "--cli-input-json", "file://$taskFile", "--query", "taskDefinition.taskDefinitionArn")

    $networkFile = Write-JsonFile @{
        awsvpcConfiguration = @{
            subnets = $subnets; securityGroups = @($securityGroupId); assignPublicIp = $settings.ASSIGN_PUBLIC_IP
        }
    } "gis-import-network"
    Write-Host "Running disposable importer task..."
    $taskArn = Get-AwsValue @(
        "ecs", "run-task", "--cluster", $clusterName, "--launch-type", "FARGATE",
        "--task-definition", $taskDefinitionArn, "--network-configuration", "file://$networkFile",
        "--query", "tasks[0].taskArn"
    )
    if (-not $taskArn) { throw "ECS did not return an importer task ARN." }
    [void](Invoke-Aws @("ecs", "wait", "tasks-stopped", "--cluster", $clusterName, "--tasks", $taskArn))

    $taskResult = (Invoke-Aws @(
        "ecs", "describe-tasks", "--cluster", $clusterName, "--tasks", $taskArn,
        "--query", "tasks[0].{ExitCode:containers[0].exitCode,Reason:containers[0].reason,StoppedReason:stoppedReason}", "--output", "json"
    )).Output | ConvertFrom-Json
    $taskId = $taskArn.Substring($taskArn.LastIndexOf("/") + 1)
    $streamName = "import/importer/$taskId"
    $logs = Invoke-Aws @("logs", "get-log-events", "--log-group-name", $logGroup, "--log-stream-name", $streamName, "--query", "events[].message", "--output", "text") -AllowFailure
    if ($logs.Output) { Write-Host $logs.Output }
    if ($taskResult.ExitCode -ne 0) {
        throw "Importer task failed (exit $($taskResult.ExitCode)): $($taskResult.Reason) $($taskResult.StoppedReason)"
    }
    $importSucceeded = $true
    if ($InspectOnly) { Write-Host "Read-only database inspection completed successfully." -ForegroundColor Green }
    else { Write-Host "S3 data import completed successfully." -ForegroundColor Green }
}
finally {
    Write-Host "Removing all import-only infrastructure..."
    $listedTasks = Invoke-Aws @(
        "ecs", "list-tasks", "--cluster", $clusterName, "--desired-status", "RUNNING",
        "--query", "taskArns[]", "--output", "text"
    ) -AllowFailure
    $taskPattern = '^arn:[a-z0-9-]+:ecs:[a-z0-9-]+:\d{12}:task/(?:[A-Za-z0-9_-]+/)?[a-f0-9-]+$'
    $taskArns = @(Get-CleanupIdentifiers $listedTasks $taskPattern)
    if ($taskArn -and $taskArn -notin $taskArns) { $taskArns += $taskArn }
    foreach ($arn in $taskArns) {
        $status = Invoke-Aws @("ecs", "describe-tasks", "--cluster", $clusterName, "--tasks", $arn, "--query", "tasks[0].lastStatus", "--output", "text") -AllowFailure
        if ($status.ExitCode -eq 0 -and $status.Output -in @("PROVISIONING", "PENDING", "ACTIVATING", "RUNNING", "DEACTIVATING", "STOPPING", "DEPROVISIONING")) {
            [void](Invoke-CleanupAws @("ecs", "stop-task", "--cluster", $clusterName, "--task", $arn, "--reason", "Importer cleanup") "stop importer task")
            [void](Invoke-CleanupAws @("ecs", "wait", "tasks-stopped", "--cluster", $clusterName, "--tasks", $arn) "wait for importer task shutdown")
        }
    }

    $listedDefinitions = Invoke-Aws @(
        "ecs", "list-task-definitions", "--family-prefix", $taskFamily,
        "--query", "taskDefinitionArns[]", "--output", "text"
    ) -AllowFailure
    $definitionArns = @(Get-CleanupIdentifiers $listedDefinitions '^arn:[a-z0-9-]+:ecs:[a-z0-9-]+:\d{12}:task-definition/[A-Za-z0-9_-]+:\d+$')
    if ($taskDefinitionArn -and $taskDefinitionArn -notin $definitionArns) { $definitionArns += $taskDefinitionArn }
    foreach ($arn in $definitionArns) {
        [void](Invoke-CleanupAws @("ecs", "deregister-task-definition", "--task-definition", $arn) "deregister importer task definition")
        [void](Invoke-CleanupAws @("ecs", "delete-task-definitions", "--task-definitions", $arn) "delete importer task definition")
    }

    [void](Invoke-CleanupAws @("ecs", "delete-cluster", "--cluster", $clusterName) "delete importer ECS cluster")
    if (-not $securityGroupId) {
        $groupLookup = Invoke-Aws @(
            "ec2", "describe-security-groups", "--filters",
            "Name=vpc-id,Values=$($settings.VPC_ID)", "Name=group-name,Values=$securityGroupName",
            "--query", "SecurityGroups[0].GroupId", "--output", "text"
        ) -AllowFailure
        $securityGroupId = @(Get-CleanupIdentifiers $groupLookup '^sg-[0-9a-f]+$') | Select-Object -First 1
    }
    if ($securityGroupId -match '^sg-[0-9a-f]+$') {
        [void](Invoke-CleanupAws @(
            "ec2", "revoke-security-group-ingress", "--group-id", $settings.DB_SECURITY_GROUP_ID,
            "--protocol", "tcp", "--port", $settings.DB_PORT, "--source-group", $securityGroupId
        ) "revoke importer database ingress")
    }
    Remove-TemporarySecurityGroup $securityGroupId
    [void](Invoke-CleanupAws @("logs", "delete-log-group", "--log-group-name", $logGroup) "delete importer log group")
    [void](Invoke-CleanupAws @("ecr", "delete-repository", "--repository-name", $repositoryName, "--force") "delete importer image repository")
    foreach ($path in $temporaryFiles) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    if ($importSucceeded -and -not $cleanupFailed) {
        Write-Host "Cleanup complete. Only the source S3 data, API database secret, and imported PostGIS tables remain." -ForegroundColor Green
    }
    else {
        Write-Host "Cleanup attempted. Review the original failure and any cleanup warnings above." -ForegroundColor Yellow
    }
}
