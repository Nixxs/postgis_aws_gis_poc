# Independent OpenLayers UI; shares only the API with MapLibre.
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [switch]$SkipBuild
)

& (Join-Path $PSScriptRoot "frontend-deployment.ps1") -Frontend OpenLayers -ConfigFile $ConfigFile -SkipBuild:$SkipBuild