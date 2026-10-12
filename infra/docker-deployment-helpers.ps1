# Safe to dot-source: defines helpers only; does not deploy anything.
function Invoke-DeploymentDocker([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        # Native stderr includes normal build progress in Windows PowerShell 5.1.
        $ErrorActionPreference = "Continue"
        & docker @Arguments 2>&1 | ForEach-Object {
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host $text }
        }
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        throw "Docker command failed (exit $exitCode): $($Arguments -join ' '). Review Docker output above."
    }
}

function New-EcrDockerAuthDocument([string]$Registry, [string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { throw "ECR returned an empty authentication token." }
    return @{
        auths = @{
            $Registry = @{ auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("AWS:$Token")) }
        }
    }
}

function Push-EcrDeploymentImage([string]$Registry, [string]$ImageUri, [string]$Token) {
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) "gis-deploy-docker-$([Guid]::NewGuid().ToString('N'))"
    try {
        [void][System.IO.Directory]::CreateDirectory($directory)
        $document = New-EcrDockerAuthDocument $Registry $Token
        $originalDirectory = $env:DOCKER_CONFIG
        if (-not $originalDirectory) { $originalDirectory = Join-Path $HOME ".docker" }
        $originalFile = Join-Path $originalDirectory "config.json"
        if (Test-Path $originalFile) {
            $original = Get-Content $originalFile -Raw | ConvertFrom-Json
            if ($original.currentContext) { $document.currentContext = $original.currentContext }
        }
        $contexts = Join-Path $originalDirectory "contexts"
        if (Test-Path $contexts) { Copy-Item $contexts -Destination $directory -Recurse }
        # Never copy credential helpers or existing auths; leave user config untouched.
        [System.IO.File]::WriteAllText(
            (Join-Path $directory "config.json"), ($document | ConvertTo-Json -Depth 10 -Compress),
            (New-Object System.Text.UTF8Encoding($false))
        )
        Invoke-DeploymentDocker @("--config", $directory, "push", $ImageUri)
    }
    finally {
        # Base64 auth is not encryption. Remove scoped credentials on every exit.
        if (Test-Path $directory) { Remove-Item $directory -Recurse -Force }
    }
}