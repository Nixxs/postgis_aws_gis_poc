# Offline tests: load helpers only; never run AWS deployment.
$ErrorActionPreference = "Stop"
$infra = Split-Path $PSScriptRoot -Parent
. (Join-Path $infra "docker-deployment-helpers.ps1")
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $infra "deploy-api.ps1"), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'API deployer has syntax errors.' }
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AwsValue' }, $true)
Invoke-Expression $definition.Extent.Text
function Invoke-Aws([string[]]$Arguments) {
    if ($Arguments[-1] -ne 'json') { throw 'Scalar lookup must use JSON.' }
    return $script:scalarJson
}
$script:scalarJson = '"arn:aws:example:single"'
if ((Get-AwsValue @('test')) -ne 'arn:aws:example:single') { throw 'Scalar ARN parsing failed.' }
$script:scalarJson = 'null'
if ((Get-AwsValue @('test')) -ne '') { throw 'Missing scalar parsing failed.' }
foreach ($invalid in @('["None","arn:aws:example"]', '"None\narn:aws:example"')) {
    $script:scalarJson = $invalid
    $rejected = $false
    try { Get-AwsValue @('test') | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid scalar was accepted.' }
}
function docker {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Write-Error 'Simulated build progress on stderr' -ErrorAction Continue
    $global:LASTEXITCODE = $script:dockerExit
}
$script:dockerExit = 0
Invoke-DeploymentDocker @('build')
if ($ErrorActionPreference -ne 'Stop') { throw 'Docker helper did not restore preference.' }
$script:dockerExit = 1
$caught = $false
try { Invoke-DeploymentDocker @('build') } catch {
    if ($_.Exception.Message -notmatch 'Docker command failed.*build') { throw }
    $caught = $true
}
if (-not $caught -or $ErrorActionPreference -ne 'Stop') { throw 'Docker failure handling failed.' }
$document = New-EcrDockerAuthDocument 'test.example' 'fake-token'
$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($document.auths['test.example'].auth))
if ($decoded -ne 'AWS:fake-token' -or $document.ContainsKey('credsStore') -or $document.ContainsKey('credHelpers')) { throw 'Unsafe ECR auth document.' }
function Invoke-DeploymentDocker([string[]]$Arguments) {
    if ($Arguments[0] -ne '--config' -or $Arguments[2] -ne 'push') { throw 'Push must use isolated config.' }
    $script:authDirectory = $Arguments[1]
    $auth = Get-Content (Join-Path $script:authDirectory 'config.json') -Raw | ConvertFrom-Json
    if (-not $auth.auths.'test.example'.auth -or $auth.credsStore -or $auth.credHelpers) { throw 'Unsafe push auth.' }
    if ($script:failPush) { throw 'Simulated push failure' }
}
$script:failPush = $false
Push-EcrDeploymentImage 'test.example' 'test.example/api:test' 'fake-token'
if (Test-Path $script:authDirectory) { throw 'Auth remains after success.' }
$script:failPush = $true
$caught = $false
try { Push-EcrDeploymentImage 'test.example' 'test.example/api:test' 'fake-token' } catch {
    if ($_.Exception.Message -ne 'Simulated push failure') { throw }
    $caught = $true
}
if (-not $caught -or (Test-Path $script:authDirectory)) { throw 'Auth cleanup failed after push error.' }
Write-Host 'PASS: API scalar JSON lookups, Docker stderr/exit handling, isolated ECR auth and credential cleanup.'