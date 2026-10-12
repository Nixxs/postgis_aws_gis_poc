# Independent MapLibre UI; shares only the API with OpenLayers.
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot ".env"),
    [switch]$SkipBuild
)

& (Join-Path $PSScriptRoot "frontend-deployment.ps1") -Frontend MapLibre -ConfigFile $ConfigFile -SkipBuild:$SkipBuild
