# Spatial-query endpoint comparison

`compare-spatial-query.ps1` sends the same 25-feature parcel polygon query to:

- the Lambda + DuckDB + GeoParquet endpoint; and
- the API Gateway + ECS/FastAPI + PostGIS endpoint.

From the repository root:

```powershell
.\performance\compare-spatial-query.ps1
```

The default run performs one untimed warm-up and 10 measured sequential requests per service. It prints mean, p50, p95, minimum and maximum client-observed latency, and writes raw runs plus methodology to the ignored `performance/results/spatial-query-comparison.json` file.

Options:

```powershell
.\performance\compare-spatial-query.ps1 `
  -RequestCount 20 `
  -WarmupCount 2 `
  -TimeoutSeconds 120 `
  -OutputPath .\performance\results\comparison.json
```

The script verifies HTTP success and reports returned feature counts. Equal counts are useful but do not prove complete response equivalence. A warm-up also cannot guarantee that AWS Lambda routes every later invocation to the same execution environment.
