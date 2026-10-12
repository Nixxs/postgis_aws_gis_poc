# Offline stand-in for deployment scripts: completion messages use Write-Host.
param(
    [string]$Label = "Deployment complete:",
    [switch]$MixedOutput,
    [switch]$Fail,
    [switch]$NonTerminatingFailure
)
Write-Host 'Simulated deployment progress'
if ($Fail) { throw 'Simulated deployment failure' }
if ($NonTerminatingFailure) { Write-Error 'Simulated nonterminating failure' -ErrorAction Continue }
if ($MixedOutput) { Write-Output 'Simulated stdout progress' }
Write-Host "$Label https://deployment.example.test/"