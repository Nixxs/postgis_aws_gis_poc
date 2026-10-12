# Offline regression tests; extracts helper definitions without executing deployment.
$ErrorActionPreference = "Stop"
$path = Join-Path (Split-Path $PSScriptRoot -Parent) "import-s3-to-postgis.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Importer script contains syntax errors." }
$helpers = @("Get-CleanupIdentifiers", "Get-AwsValue", "Invoke-ImporterDocker", "New-ImporterDockerAuthDocument", "Push-ImporterImage")
foreach ($name in $helpers) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing helper: $name" }
    Invoke-Expression $definition.Extent.Text
}

$pattern = '^arn:[a-z0-9-]+:ecs:[a-z0-9-]+:\d{12}:task/(?:[A-Za-z0-9_-]+/)?[a-f0-9-]+$'
$valid = 'arn:aws:ecs:ap-southeast-2:376640768813:task/import-test/0123456789abcdef0123456789abcdef'
$result = @(Get-CleanupIdentifiers @{ ExitCode = 1; Output = "aws.exe : ClusterNotFoundException --profile --region $valid" } $pattern)
if ($result.Count -ne 0) { throw "Failed AWS request was parsed as task IDs." }
$result = @(Get-CleanupIdentifiers @{ ExitCode = 0; Output = "None aws.exe --profile arn:aws:ecs:ap-southeast-2:376640768813:task/ $valid" } $pattern)
if ($result.Count -ne 1 -or $result[0] -ne $valid) { throw "Task identifier validation failed." }
$result = @(Get-CleanupIdentifiers @{ ExitCode = 0; Output = '' } $pattern)
if ($result.Count -ne 0) { throw "Empty list produced task IDs." }
$result = @(Get-CleanupIdentifiers @{ ExitCode = 1; Output = 'sg-12345678' } '^sg-[0-9a-f]+$')
if ($result.Count -ne 0) { throw "Failed group lookup produced a security group ID." }

function Invoke-Aws {
    param([string[]]$Arguments)
    if ($Arguments[-1] -ne 'json') { throw 'Scalar lookup must use JSON output.' }
    return @{ ExitCode = 0; Output = $script:scalarJson }
}
$script:scalarJson = '"arn:aws:secretsmanager:ap-southeast-2:376640768813:secret:example-ABC123"'
$value = Get-AwsValue @('secretsmanager', 'list-secrets')
if ($value -ne 'arn:aws:secretsmanager:ap-southeast-2:376640768813:secret:example-ABC123') { throw 'Secret ARN parsing failed.' }
$script:scalarJson = 'null'
if ((Get-AwsValue @('secretsmanager', 'list-secrets')) -ne '') { throw 'Missing secret parsing failed.' }
foreach ($invalid in @('["None","arn:aws:example"]', '"None\narn:aws:example"')) {
    $script:scalarJson = $invalid
    $rejected = $false
    try { Get-AwsValue @('secretsmanager', 'list-secrets') | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid scalar response was accepted.' }
}

# Simulate native Docker progress and a failed engine without Docker or AWS access.
function docker {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Write-Error 'Simulated Docker stderr' -ErrorAction Continue
    $global:LASTEXITCODE = $script:dockerExit
}
$script:dockerExit = 0
Invoke-ImporterDocker @('build')
$script:dockerExit = 1
$caught = $false
try { Invoke-ImporterDocker @('info') }
catch {
    if ($_.Exception.Message -notmatch 'Docker command failed.*info') { throw }
    $caught = $true
}
if (-not $caught) { throw "Docker failure did not stop the deployment." }

$auth = New-ImporterDockerAuthDocument 'test.example' 'fake-token'
$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth.auths['test.example'].auth))
if ($decoded -ne 'AWS:fake-token' -or $auth.ContainsKey('credsStore') -or $auth.ContainsKey('credHelpers')) {
    throw 'Isolated ECR authentication includes incorrect credentials or a credential helper.'
}

# Verify temporary credentials are removed on both success and failure.
function Invoke-ImporterDocker {
    param([string[]]$Arguments)
    $script:authDirectory = $Arguments[1]
    $document = Get-Content (Join-Path $script:authDirectory 'config.json') -Raw | ConvertFrom-Json
    if (-not $document.auths.'test.example'.auth) { throw 'Push auth missing.' }
    if ($script:failPush) { throw 'Simulated push failure' }
}
$script:failPush = $false
Push-ImporterImage 'test.example' 'test.example/image:test' 'fake-token'
if (Test-Path $script:authDirectory) { throw 'Docker credentials left behind after successful push.' }
$script:failPush = $true
try { Push-ImporterImage 'test.example' 'test.example/image:test' 'fake-token' }
catch { if ($_.Exception.Message -ne 'Simulated push failure') { throw } }
if (Test-Path $script:authDirectory) { throw 'Docker credentials left behind after failed push.' }
Write-Host 'PASS: cleanup IDs, scalar JSON lookups, Docker stderr/failures, isolated ECR auth, credential removal on success/failure.'
