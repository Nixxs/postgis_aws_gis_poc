# PostGIS tile-cache batch job

This container builds an immutable Mapbox Vector Tile (MVT) pyramid directly from a PostGIS layer and writes it to a private S3 bucket. It is intended to run on demand as an AWS Batch Fargate job.

The bucket remains private and blocks public access. A dedicated CloudFront
distribution uses Origin Access Control (OAC) to expose generated objects
without making S3 public.

## What a run produces

A run writes only non-empty, gzip-compressed tiles:

```text
s3://BUCKET/tiles/SCHEMA/LAYER/GRID/VERSION/{z}/{x}/{y}.mvt
s3://BUCKET/tiles/SCHEMA/LAYER/GRID/VERSION/tilejson.json
s3://BUCKET/tiles/SCHEMA/LAYER/GRID/VERSION/job.json
s3://BUCKET/tiles/SCHEMA/LAYER/GRID/latest.json
```

Each version is immutable. `latest.json` is written last, so consumers never discover a partially completed pyramid. Re-running a failed version is safe because object writes are idempotent.

The job calculates the layer extent in the target CRS before generating work; it does not iterate over the entire global grid. Empty MVT results are not stored.

## Deploy AWS Batch

The deployer reuses the API's VPC, database secret, and task security group. It creates a dedicated ECR repository, private S3 bucket, IAM roles, CloudWatch log group, Fargate compute environment, job queue, and job definition.

1. Ensure the API deployment is working and the database secret exists.
2. Copy `infra/.env.example` to `infra/.env` if that has not already been done.
3. Fill in the existing AWS, network, secret, and database-related values.
4. Run from the repository root:

```powershell
./infra/deploy-tilecache.ps1
```

The script always registers a new job-definition revision using the image it just pushed. It does not submit a tile job.

Optional deployment settings in `infra/.env`:

| Setting | Default |
|---|---|
| `TILECACHE_ECR_REPOSITORY` | `gis-postgis-tilecache` |
| `TILECACHE_BUCKET` | `gis-postgis-tilecache-<account>` |
| `TILECACHE_PREFIX` | `tiles` |
| `TILECACHE_COMPUTE_ENV` | `gis-postgis-tilecache-fargate` |
| `TILECACHE_JOB_QUEUE` | `gis-postgis-tilecache` |
| `TILECACHE_JOB_DEFINITION` | `gis-postgis-tilecache` |
| `TILECACHE_MAX_VCPUS` | `16` |
| `TILECACHE_JOB_VCPUS` | `2` |
| `TILECACHE_JOB_MEMORY` | `4096` MiB |
| `TILECACHE_JOB_TIMEOUT` | `86400` seconds |

## Submit from the AWS Console

For normal builds, treat the main MapLibre
`frontend/public/config.json` as the source of truth. `layers` controls the UI
catalogue and each layer's `cache.enabled` flag controls whether it is included
in a cache build. Preview, dry-run and build all enabled layers with:

```powershell
./infra/build-configured-tilecache.ps1 -ListOnly
./infra/build-configured-tilecache.ps1 -DryRun
./infra/build-configured-tilecache.ps1
```

To select one configured, cache-enabled layer:

```powershell
./infra/build-configured-tilecache.ps1 `
	-Layer au_vic_dtp_planning_scheme_all `
	-DryRun
```

For an ad-hoc build that is intentionally independent of the UI catalogue, use
the lower-level helper:

```powershell
./infra/submit-tilecache.ps1 `
	-Layer au_vic_dtp_planning_scheme_all `
	-Grid webmercator `
	-MinZoom 0 `
	-MaxZoom 12
```

Both helpers validate arguments, apply the required landing-zone tags, use the
queue and job-definition names from `infra/.env`, and print the job ID, Console
URL and status command.

To submit manually in the AWS Console instead:

1. Open **AWS Batch → Jobs → Submit new job** in the configured region.
2. Choose the `gis-postgis-tilecache` job definition and job queue.
3. Give the job a unique name.
4. Under **Container overrides**, set **Command** to the arguments required by the image. Do not include `python` or the module name because the image already has an entry point.

For a Web Mercator pyramid:

```text
--layer,au_vic_dtp_planning_scheme_all,--grid,webmercator,--min-zoom,0,--max-zoom,12
```

For the native Vicgrid pyramid:

```text
--layer,au_vic_dtp_planning_scheme_all,--grid,vicgrid,--min-zoom,0,--max-zoom,10
```

The exact Console widget may display the command as separate fields or JSON. If it requests JSON, use:

```json
["--layer","au_vic_dtp_planning_scheme_all","--grid","webmercator","--min-zoom","0","--max-zoom","12"]
```

Submit a dry run first to inspect the planned tile ranges and tile count in CloudWatch without writing S3 objects:

```text
--layer,au_vic_dtp_planning_scheme_all,--grid,webmercator,--min-zoom,0,--max-zoom,12,--dry-run
```

## Job arguments

| Argument | Default | Purpose |
|---|---:|---|
| `--layer` | required | Table registered in `geometry_columns` |
| `--schema` | `public` | PostgreSQL schema |
| `--grid` | `webmercator` | `webmercator` or `vicgrid` |
| `--min-zoom` | `0` | First zoom level |
| `--max-zoom` | `12` | Last zoom level |
| `--fields` | `*` | Comma-separated properties included in each MVT |
| `--version` | UTC timestamp | Immutable output version identifier |
| `--workers` | `4` | Concurrent database/render/upload workers, maximum 32 |
| `--max-tiles` | `1000000` | Safety limit; the job fails before rendering if exceeded |
| `--dry-run` | off | Validate and print ranges without uploading |

Database values and the output bucket are injected by the job definition. They do not need to be entered when submitting a job.

## Deploy and test the tile CDN

After at least one successful build, deploy the dedicated CloudFront
distribution from the repository root:

```powershell
./infra/deploy-tilecache-cdn.ps1
```

The script creates or reuses:

- a CloudFront distribution dedicated to the tile-cache bucket;
- an Origin Access Control that signs private S3 requests;
- a response-headers policy allowing cross-origin browser tile requests; and
- a bucket policy restricted to that distribution's ARN.

It waits until the distribution is deployed, then prints URLs for
`latest.json` and a known test tile. Versioned objects retain their immutable
one-year cache header. `latest.json` retains its short/no-cache origin policy.

Optional settings are `TILECACHE_CLOUDFRONT_COMMENT`, `TILECACHE_OAC_NAME`,
and `TILECACHE_RESPONSE_HEADERS_POLICY`. Defaults are listed in
`infra/.env.example`. Public S3 access remains blocked.

## Operational notes

- Start with low zooms and `--dry-run`. Tile counts and database load grow quickly.
- The default two attempts can safely retry because each version uses deterministic object keys.
- CloudWatch logs are under `/aws/batch/gis-postgis-tilecache` unless the job-definition name is changed.
- MVT objects use `Content-Type: application/vnd.mapbox-vector-tile` and `Content-Encoding: gzip`.
- Web Mercator supports zooms 0–22. Vicgrid uses the repository's verified EPSG:7899 matrix and supports matrix indices 0–13.
- `latest.json` uses its origin `no-cache` policy through CloudFront;
	versioned tiles and manifests remain cacheable for a year.
