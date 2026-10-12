# S3 to PostGIS import

This workflow keeps the source archive in a private encrypted S3 bucket and
runs GDAL inside the existing DTP VPC. RDS remains private and receives only a
temporary security-group-to-security-group ingress rule while the task runs.

## 1. Provision RDS and the source bucket

```powershell
.\infra\deploy-dtp.ps1 -Phase Database
```

The source bucket is permanent. Public access is blocked and default SSE-S3
encryption is enabled.

## 2. Package and upload the source

For a File Geodatabase, preserve the `.gdb` directory inside a ZIP archive:

```powershell
Compress-Archive -Path .\data\au_vic_dtp_ingestion.gdb -DestinationPath .\data\au_vic_dtp_ingestion.gdb.zip
aws s3 cp .\data\au_vic_dtp_ingestion.gdb.zip s3://gis-postgis-source-376640768813/source/au_vic_dtp_ingestion.gdb.zip --profile dtp-admin --region ap-southeast-2
```

Do not upload database credentials. The import task receives them from the
permanent Secrets Manager secret used by the API.

## 3. Configure the manifest

```powershell
Copy-Item .\infra\import-manifest.example.json .\infra\import-manifest.json
```

Set:

- `s3Bucket` to the `IMPORT_BUCKET` value in the ignored DTP config.
- `s3Key` to the uploaded object's key, without an `s3://` prefix.
- `archive` to `zip` for a ZIP or `none` for a directly readable file.
- `datasetPathSuffix` to the path inside the archive, such as
  `/au_vic_dtp_ingestion.gdb`; use an empty string for a GeoPackage or a ZIP
  whose root is directly readable.
- Each `source` layer name and its required `target` PostGIS table name.

Source and target layer names are restricted to unqualified identifiers. All
targets are written to the `public` schema. Existing target tables are replaced.

## 4. Run the disposable importer

Docker Desktop must be running locally so the orchestration can build the
pinned GDAL image and push it to a temporary private ECR repository.

The push uses an isolated temporary Docker configuration with a short-lived
ECR token, avoiding Windows credential-helper failures. It preserves the active
Docker context and does not change your normal Docker settings. The temporary
authentication directory is deleted after the push, including if it fails.

```powershell
.\infra\deploy-dtp.ps1 -Phase Import
```

The script verifies that the S3 object exists before creating temporary
infrastructure. It generates a time-limited object URL, runs one Fargate task,
waits for completion, and prints the task logs. The import task:

1. downloads the object into encrypted Fargate ephemeral storage;
2. enables the PostGIS extension;
3. imports each configured layer with `ogr2ogr`;
4. preserves `OBJECTID` as the feature ID, promotes geometry to multi geometry,
   creates a GiST index, and runs `ANALYZE`.

In a `finally` block, the orchestrator stops the task if necessary and removes
the temporary task definition, ECS cluster, security group, RDS ingress rule,
CloudWatch log group, ECR image and ECR repository. It never deletes the S3
source object or imported database tables.

If cleanup reports a warning, remove the named temporary resource before
retrying. Temporary resources start with `gis-postgis-import-`.

## 5. Continue deployment

```powershell
.\infra\deploy-dtp.ps1 -Phase Application
.\infra\deploy-dtp.ps1 -Phase TileCache
.\infra\deploy-dtp.ps1 -Phase Verify
```

Alternatively, after upload, run all remaining phases (the import is
idempotent because configured tables are overwritten):

```powershell
.\infra\deploy-dtp.ps1 -Phase All -SourceUploaded
```
