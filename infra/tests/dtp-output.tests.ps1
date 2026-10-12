# Offline regression: extract orchestration helpers, never execute deployment.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy-dtp.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'DTP orchestrator contains syntax errors.' }
foreach ($name in @('Invoke-Deployment', 'Get-OutputUrl')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing helper: $name" }
    Invoke-Expression $definition.Extent.Text
}
$fixture = Join-Path $PSScriptRoot 'fixtures\deployment-output.ps1'
foreach ($label in @('Deployment complete:', 'Frontend deployment complete:', 'OpenLayers deployment complete:', 'Tile CDN deployment complete:')) {
    $output = @(Invoke-Deployment $fixture @{ Label = $label })
    $url = Get-OutputUrl $output $label
    if ($url -ne 'https://deployment.example.test') { throw "Host-stream URL capture failed: $label" }
    if ($output -notcontains 'Simulated deployment progress') { throw 'Progress was not captured.' }
}
$output = @(Invoke-Deployment $fixture @{ MixedOutput = $true })
if ($output -notcontains 'Simulated stdout progress') { throw 'Stdout capture failed.' }
if ((Get-OutputUrl $output 'Deployment complete:') -ne 'https://deployment.example.test') { throw 'Mixed-stream URL capture failed.' }
foreach ($case in @(@{ Fail = $true }, @{ NonTerminatingFailure = $true })) {
    $caught = $false
    try { Invoke-Deployment $fixture $case | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'Simulated.*failure') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'Child deployment failure was swallowed.' }
}
$caught = $false
try { Get-OutputUrl @('No completion message') 'Deployment complete:' | Out-Null } catch { $caught = $true }
if (-not $caught) { throw 'Missing completion URL was accepted.' }
Write-Host 'PASS: Write-Host API/frontend/CDN URLs, streamed progress, mixed stdout, child failures and missing URLs.'