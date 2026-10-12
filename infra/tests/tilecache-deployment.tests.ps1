# Offline tests: AWS and Docker are mocked; no deployment or registry access.
$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
foreach ($file in @('deploy-tilecache.ps1', 'deploy-tilecache-cdn.ps1')) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $infra $file), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "$file contains syntax errors." }
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AwsValue' }, $true)
    Invoke-Expression $definition.Extent.Text
    function Invoke-Aws([string[]]$Arguments) {
        if ($Arguments[-1] -ne 'json') { throw 'Scalar lookup must use JSON.' }
        return $script:scalarJson
    }
    foreach ($json in @('"arn:aws:example:single"', 'null')) {
        $script:scalarJson = $json
        $expected = if ($json -eq 'null') { '' } else { 'arn:aws:example:single' }
        if ((Get-AwsValue @('test')) -ne $expected) { throw "$file scalar parsing failed." }
    }
    foreach ($json in @('["None","example"]', '"None\nexample"', '{"Id":"example"}')) {
        $script:scalarJson = $json
        $caught = $false
        try { Get-AwsValue @('test') | Out-Null } catch { $caught = $true }
        if (-not $caught) { throw "$file accepted an invalid scalar." }
    }
    # Exercise the real AWS wrapper with stderr separated from valid stdout.
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Aws' }, $true)
    Invoke-Expression $definition.Extent.Text
    $settings = @{ AWS_PROFILE = 'offline'; AWS_REGION = 'ap-southeast-2' }
    function aws {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        Write-Error 'Simulated AWS warning' -ErrorAction Continue
        Write-Output '"single-value"'
        $global:LASTEXITCODE = $script:awsExit
    }
    $script:awsExit = 0
    if ((Get-AwsValue @('test')) -ne 'single-value' -or $ErrorActionPreference -ne 'Stop') { throw "$file mixed AWS stderr with JSON." }
    $script:awsExit = 1
    $caught = $false
    try { Invoke-Aws @('test') | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'AWS command failed.*aws test' -or $_.Exception.Message -notmatch 'Simulated AWS warning') { throw }
        $caught = $true
    }
    if (-not $caught -or $ErrorActionPreference -ne 'Stop') { throw "$file swallowed an AWS failure." }
}

$settings = @{
    AWS_PROFILE = 'offline'; AWS_REGION = 'ap-southeast-2'; AWS_ACCOUNT_ID = '376640768813'
    VPC_ID = 'vpc-offline'; SUBNET_IDS = 'subnet-offline-a,subnet-offline-b'; ASSIGN_PUBLIC_IP = 'DISABLED'
    SECRET_NAME = 'offline-secret'; TASK_SECURITY_GROUP_ID = 'sg-offline'
    TILECACHE_ECR_REPOSITORY = 'offline-tilecache'; TILECACHE_BUCKET = 'offline-tilecache-376640768813'
    TILECACHE_PREFIX = 'tiles'; TILECACHE_COMPUTE_ENV = 'offline-compute'; TILECACHE_JOB_QUEUE = 'offline-queue'
    TILECACHE_JOB_DEFINITION = 'offline-job'; TILECACHE_MAX_VCPUS = '16'; TILECACHE_JOB_VCPUS = '2'
    TILECACHE_JOB_MEMORY = '4096'; TILECACHE_JOB_TIMEOUT = '86400'
    TILECACHE_EXECUTION_ROLE_ARN = 'arn:aws:iam::376640768813:role/offline-execution'
    TILECACHE_JOB_ROLE_ARN = 'arn:aws:iam::376640768813:role/offline-job'
}
$saved = @{}
foreach ($name in @($settings.Keys) + @('AWS_PAGER')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$config = [System.IO.Path]::GetTempFileName()
$testState = @{
    AwsCalls = [System.Collections.Generic.List[object]]::new()
    DockerCalls = [System.Collections.Generic.List[object]]::new()
    BucketExists = $false; DockerExit = 0; AuthDirectory = ''
}
function aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $operation = $Arguments[0] + ':' + $Arguments[1]
    $document = $null
    foreach ($argument in $Arguments) {
        if ($argument -and $argument.StartsWith('file://')) { $document = Get-Content $argument.Substring(7) -Raw | ConvertFrom-Json }
    }
    $testState.AwsCalls.Add(@{ Operation = $operation; Arguments = $Arguments; Document = $document })
    Write-Error 'Simulated AWS diagnostic on stderr' -ErrorAction Continue
    $global:LASTEXITCODE = 0
    $value = switch ($operation) {
        'sts:get-caller-identity' { '376640768813' }
        'ecr:describe-repositories' { 'offline.example/tilecache' }
        'ecr:get-login-password' { Write-Output 'offline-token'; return }
        's3api:list-buckets' { if ($testState.BucketExists) { 'offline-tilecache-376640768813' } else { $null } }
        's3api:create-bucket' { $null }
        's3api:put-public-access-block' { $null }
        's3api:put-bucket-encryption' { $null }
        's3api:put-bucket-tagging' { $null }
        'secretsmanager:describe-secret' { 'arn:aws:secretsmanager:ap-southeast-2:376640768813:secret:offline' }
        'logs:describe-log-groups' { $null }
        'logs:create-log-group' { $null }
        'logs:put-retention-policy' { $null }
        'batch:describe-compute-environments' { $null }
        'batch:create-compute-environment' { 'arn:aws:batch:ap-southeast-2:376640768813:compute-environment/offline' }
        'batch:describe-job-queues' { $null }
        'batch:create-job-queue' { 'arn:aws:batch:ap-southeast-2:376640768813:job-queue/offline' }
        'batch:register-job-definition' { 'arn:aws:batch:ap-southeast-2:376640768813:job-definition/offline:1' }
        default { throw "Unexpected offline AWS operation: $operation" }
    }
    if ($null -ne $value) { ConvertTo-Json -InputObject $value -Compress } else { Write-Output 'null' }
}
function docker {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $testState.DockerCalls.Add($Arguments)
    Write-Error 'Simulated normal Docker progress on stderr' -ErrorAction Continue
    $global:LASTEXITCODE = 0
    if ($Arguments[0] -eq 'info') { Write-Output 'linux' }
    if ($Arguments[0] -eq 'build') { $global:LASTEXITCODE = $testState.DockerExit }
    if ($Arguments[0] -eq '--config') {
        if ($Arguments[2] -ne 'push') { throw 'Unexpected scoped Docker command.' }
        $testState.AuthDirectory = $Arguments[1]
        $auth = Get-Content (Join-Path $testState.AuthDirectory 'config.json') -Raw | ConvertFrom-Json
        $registry = '376640768813.dkr.ecr.ap-southeast-2.amazonaws.com'
        if (-not $auth.auths.$registry.auth -or $auth.credsStore -or $auth.credHelpers) { throw 'Push must use direct isolated credentials.' }
    }
}
try {
    [System.IO.File]::WriteAllLines($config, @($settings.Keys | ForEach-Object { "$_=$($settings[$_])" }))
    foreach ($exists in @($false, $true)) {
        $testState.BucketExists = $exists
        $testState.DockerExit = 0
        $testState.AwsCalls.Clear(); $testState.DockerCalls.Clear()
        & (Join-Path $infra 'deploy-tilecache.ps1') -ConfigFile $config -ImageTag 'offline-test'
        if ($testState.DockerCalls.Count -ne 3 -or $testState.DockerCalls[1][0] -ne 'build' -or $testState.DockerCalls[1] -notcontains '--provenance=false' -or $testState.DockerCalls[2][2] -ne 'push') { throw 'Build/push did not use the shared safe helpers.' }
        if (Test-Path $testState.AuthDirectory) { throw 'Scoped ECR credentials were not removed.' }
        $creates = @($testState.AwsCalls | Where-Object Operation -eq 's3api:create-bucket')
        if ($creates.Count -ne [int](-not $exists)) { throw 'Bucket creation is not restartable.' }
        if (-not $exists) {
            $document = $creates[0].Document
            if ($document.LocationConstraint -ne 'ap-southeast-2' -or $document.Tags.Count -ne 2 -or
                $document.Tags[0].Key -cne 'lz:CostCenter' -or $document.Tags[0].Value -ne 'PlanningSpatial' -or
                $document.Tags[1].Key -cne 'lz:BackupPlan' -or $document.Tags[1].Value -ne 'Daily') { throw 'Bucket creation tags/region are incorrect.' }
        }
        $logCreate = @($testState.AwsCalls | Where-Object Operation -eq 'logs:create-log-group')[0]
        if ($logCreate.Arguments -notcontains '--tags') { throw 'Log group needs creation-time tags.' }
        $job = @($testState.AwsCalls | Where-Object Operation -eq 'batch:register-job-definition')[0].Document
        if ($job.containerProperties.executionRoleArn -ne $settings.TILECACHE_EXECUTION_ROLE_ARN -or
            $job.containerProperties.jobRoleArn -ne $settings.TILECACHE_JOB_ROLE_ARN -or
            $job.containerProperties.networkConfiguration.assignPublicIp -ne 'DISABLED' -or
            $job.containerProperties.image -notmatch ':offline-test$') { throw 'Job definition changed provisioned roles, private networking or image.' }
    }
    $testState.DockerExit = 1
    $testState.AwsCalls.Clear(); $testState.DockerCalls.Clear()
    $caught = $false
    try { & (Join-Path $infra 'deploy-tilecache.ps1') -ConfigFile $config -ImageTag 'offline-test' } catch {
        if ($_.Exception.Message -notmatch 'Docker command failed.*exit 1.*build') { throw }
        $caught = $true
    }
    if (-not $caught -or @($testState.AwsCalls | Where-Object { $_.Operation -like 's3api:*' -or $_.Operation -like 'batch:*' }).Count) { throw 'Failed builds must stop bucket/Batch provisioning.' }
    # Reload the bucket helper without executing provisioning.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $infra 'deploy-tilecache.ps1'), [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-TileCacheBucketConfiguration' }, $true)
    Invoke-Expression $definition.Extent.Text
    $document = New-TileCacheBucketConfiguration 'us-east-1'
    if ($document.ContainsKey('LocationConstraint') -or $document.Tags.Count -ne 2) { throw 'us-east-1 bucket configuration is incorrect.' }
}
finally {
    Remove-Item $config -Force -ErrorAction SilentlyContinue
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
Write-Host 'PASS: Batch/CDN AWS JSON and stderr handling, safe Docker build/push, ECR credential cleanup, tagged bucket/log creation, private pre-provisioned roles and build failure propagation.'