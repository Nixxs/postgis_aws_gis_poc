[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$RequestCount = 10,

    [ValidateRange(0, 20)]
    [int]$WarmupCount = 1,

    [ValidateRange(1, 900)]
    [int]$TimeoutSeconds = 120,

    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "results\spatial-query-comparison.json"
}

# Both services receive the same geometry, fields and 25-feature limit. The
# Lambda action is selected in its query string; FastAPI exposes /query.
$body = @'
{
  "layer": "au_vic_dtp_parcel",
  "geometry": {
    "type": "Polygon",
    "coordinates": [[[144.9,-37.8],[145.0,-37.8],[145.0,-37.9],[144.9,-37.9],[144.9,-37.8]]]
  },
  "spatialRel": "esriSpatialRelIntersects",
  "outFields": "OBJECTID,parcel_plan_number,parcel_status",
  "f": "geojson",
  "resultRecordCount": 25
}
'@

$cases = @(
    [pscustomobject]@{
        Name = "Lambda + DuckDB + GeoParquet"
        Url = "https://xwcbfdedow5kqa2roja44nzmle0zqfvn.lambda-url.ap-southeast-2.on.aws/?action=spatial-query"
    },
    [pscustomobject]@{
        Name = "ECS + FastAPI + PostGIS"
        Url = "https://r554gl2g2j.execute-api.ap-southeast-2.amazonaws.com/query"
    }
)

function Get-NearestRankPercentile([double[]]$Values, [double]$Percentile) {
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    return [double]$sorted[[Math]::Max(0, $index)]
}

function Invoke-SpatialRequest([pscustomobject]$Case, [int]$Sequence, [bool]$Warmup) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest `
            -Uri $Case.Url `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec $TimeoutSeconds `
            -UseBasicParsing
        $watch.Stop()

        $content = $response.Content | ConvertFrom-Json
        $featureCount = if ($null -ne $content.count) {
            [int]$content.count
        }
        elseif ($null -ne $content.features) {
            @($content.features).Count
        }
        else { $null }

        return [pscustomobject]@{
            service = $Case.Name
            sequence = $Sequence
            warmup = $Warmup
            success = $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
            status = [int]$response.StatusCode
            latency_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            response_bytes = [Text.Encoding]::UTF8.GetByteCount($response.Content)
            feature_count = $featureCount
            error = $null
        }
    }
    catch {
        $watch.Stop()
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        return [pscustomobject]@{
            service = $Case.Name
            sequence = $Sequence
            warmup = $Warmup
            success = $false
            status = $status
            latency_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            response_bytes = 0
            feature_count = $null
            error = $_.Exception.Message
        }
    }
}

$allRuns = @()
$summaries = @()

foreach ($case in $cases) {
    Write-Host "Warming $($case.Name) with $WarmupCount request(s)..."
    for ($i = 1; $i -le $WarmupCount; $i++) {
        $warmup = Invoke-SpatialRequest -Case $case -Sequence $i -Warmup $true
        if (-not $warmup.success) {
            throw "Warm-up failed for $($case.Name): HTTP $($warmup.status) $($warmup.error)"
        }
    }

    Write-Host "Measuring $($case.Name) with $RequestCount sequential request(s)..."
    $serviceRuns = @(
        for ($i = 1; $i -le $RequestCount; $i++) {
            $run = Invoke-SpatialRequest -Case $case -Sequence $i -Warmup $false
            Write-Host ("  {0,2}/{1}: {2,8:N2} ms, HTTP {3}, features {4}" -f $i, $RequestCount, $run.latency_ms, $run.status, $run.feature_count)
            $run
        }
    )
    $allRuns += $serviceRuns

    $successful = @($serviceRuns | Where-Object success)
    $latencies = [double[]]@($successful | ForEach-Object latency_ms)
    $featureCounts = @($successful | ForEach-Object feature_count | Select-Object -Unique)
    $responseSizes = [double[]]@($successful | ForEach-Object response_bytes)

    $summaries += [pscustomobject]@{
        service = $case.Name
        requests = $serviceRuns.Count
        successful_requests = $successful.Count
        errors = $serviceRuns.Count - $successful.Count
        mean_ms = if ($latencies.Count) { [Math]::Round(($latencies | Measure-Object -Average).Average, 2) } else { $null }
        p50_ms = if ($latencies.Count) { [Math]::Round((Get-NearestRankPercentile $latencies 0.50), 2) } else { $null }
        p95_ms = if ($latencies.Count) { [Math]::Round((Get-NearestRankPercentile $latencies 0.95), 2) } else { $null }
        minimum_ms = if ($latencies.Count) { [Math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2) } else { $null }
        maximum_ms = if ($latencies.Count) { [Math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2) } else { $null }
        mean_response_bytes = if ($responseSizes.Count) { [Math]::Round(($responseSizes | Measure-Object -Average).Average, 0) } else { $null }
        feature_counts = $featureCounts
    }
}

Write-Host "`nPost-warm-up sequential request summary:"
$summaries | Format-Table service, requests, successful_requests, errors, mean_ms, p50_ms, p95_ms, minimum_ms, maximum_ms, feature_counts -AutoSize

$counts = @($summaries | ForEach-Object feature_counts | ForEach-Object { $_ } | Select-Object -Unique)
if ($counts.Count -ne 1) {
    Write-Warning "The services returned different feature counts. Treat latency results as non-equivalent until response semantics are reconciled."
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
$result = [ordered]@{
    generated_at_utc = [DateTime]::UtcNow.ToString("o")
    methodology = [ordered]@{
        request_count = $RequestCount
        warmup_count = $WarmupCount
        concurrency = 1
        timeout_seconds = $TimeoutSeconds
        note = "Client-observed sequential latency after one or more untimed warm-ups. Lambda may still route a request to another execution environment; no cold start is intentionally forced."
    }
    request_body = $body | ConvertFrom-Json
    summary = $summaries
    runs = $allRuns
}
$result | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Detailed results written to $((Resolve-Path $OutputPath).Path)"
