"""Generate an immutable PostGIS MVT pyramid and publish it to Amazon S3."""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import json
import logging
import os
import re
import sys
import time
from collections import deque
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Iterable

import boto3
import psycopg2
from psycopg2 import sql
from psycopg2.pool import ThreadedConnectionPool

from .tiling import (
    Bounds,
    TileRange,
    VICGRID_MAX_ZOOM,
    vicgrid_tile_bounds,
    vicgrid_tile_range,
    web_mercator_tile_bounds,
    web_mercator_tile_range,
)

LOGGER = logging.getLogger("tilecache")
MVT_EXTENT = 4096
MVT_BUFFER = 64
TILE_DATABASE_ATTEMPTS = 3
_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_NATIVE_MVT_TYPES = {
    "bool", "int2", "int4", "int8", "float4", "float8", "numeric",
    "text", "varchar", "bpchar",
}


@dataclass(frozen=True)
class LayerMetadata:
    geometry_column: str
    srid: int
    columns: tuple[tuple[str, str], ...]
    bounds: Bounds
    wgs84_bounds: Bounds


@dataclass(frozen=True)
class TileResult:
    size: int
    empty: bool


def _env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    return int(value) if value else default


def _identifier(value: str, label: str) -> str:
    if not _IDENTIFIER.fullmatch(value):
        raise ValueError(f"{label} must be a simple PostgreSQL identifier")
    return value


def _prefix(value: str) -> str:
    normalized = value.strip("/")
    if not normalized or any(part in {".", ".."} for part in normalized.split("/")):
        raise ValueError("prefix must contain valid non-empty path segments")
    return normalized


def _version(value: str) -> str:
    if not _VERSION.fullmatch(value):
        raise ValueError("version may contain only letters, digits, dot, underscore, and hyphen")
    return value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layer", default=os.getenv("TILE_LAYER"), required=not os.getenv("TILE_LAYER"))
    parser.add_argument("--schema", default=os.getenv("TILE_SCHEMA", "public"))
    parser.add_argument("--grid", choices=("webmercator", "vicgrid"), default=os.getenv("TILE_GRID", "webmercator"))
    parser.add_argument("--min-zoom", type=int, default=_env_int("TILE_MIN_ZOOM", 0))
    parser.add_argument("--max-zoom", type=int, default=_env_int("TILE_MAX_ZOOM", 12))
    parser.add_argument("--fields", default=os.getenv("TILE_FIELDS", "*"), help="Comma-separated properties or *")
    parser.add_argument("--bucket", default=os.getenv("TILE_BUCKET"), required=not os.getenv("TILE_BUCKET"))
    parser.add_argument("--prefix", default=os.getenv("TILE_PREFIX", "tiles"))
    parser.add_argument("--version", default=os.getenv("TILE_VERSION", datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")))
    parser.add_argument("--workers", type=int, default=_env_int("TILE_WORKERS", 4))
    parser.add_argument("--max-tiles", type=int, default=_env_int("TILE_MAX_TILES", 1_000_000))
    parser.add_argument("--dry-run", action="store_true", help="Validate and report work without rendering or uploading")
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    _identifier(args.schema, "schema")
    _identifier(args.layer, "layer")
    args.prefix = _prefix(args.prefix)
    args.version = _version(args.version)
    maximum = VICGRID_MAX_ZOOM if args.grid == "vicgrid" else 22
    if not 0 <= args.min_zoom <= args.max_zoom <= maximum:
        raise ValueError(f"zoom range must satisfy 0 <= min <= max <= {maximum}")
    if not 1 <= args.workers <= 32:
        raise ValueError("workers must be between 1 and 32")
    if args.max_tiles < 1:
        raise ValueError("max-tiles must be positive")


def connect_kwargs() -> dict[str, object]:
    required = ("DB_HOST", "DB_PORT", "DB_USER", "DB_PASSWORD", "DB_NAME")
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise ValueError(f"Missing database settings: {', '.join(missing)}")
    return {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ["DB_PORT"]),
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "dbname": os.environ["DB_NAME"],
        "connect_timeout": 15,
        "keepalives": 1,
        "keepalives_idle": 30,
        "keepalives_interval": 10,
        "keepalives_count": 5,
        "application_name": "postgis-tilecache-batch",
        "options": "-c default_transaction_read_only=on",
    }


def selected_columns(columns: tuple[tuple[str, str], ...], fields: str) -> tuple[tuple[str, str], ...]:
    by_name = {name: udt_name for name, udt_name in columns}
    if not fields.strip() or fields.strip() == "*":
        return columns
    names = tuple(dict.fromkeys(name.strip() for name in fields.split(",") if name.strip()))
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise ValueError(f"Unknown tile fields: {', '.join(unknown)}")
    return tuple((name, by_name[name]) for name in names)


def load_metadata(connection, schema: str, layer: str, target_srid: int) -> LayerMetadata:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT f_geometry_column, srid
            FROM geometry_columns
            WHERE f_table_schema = %s AND f_table_name = %s
            """,
            (schema, layer),
        )
        geometry = cursor.fetchone()
        if geometry is None:
            raise ValueError(f"Layer '{schema}.{layer}' was not found in geometry_columns")
        geometry_column, srid = geometry
        if not srid:
            raise ValueError(f"Layer '{schema}.{layer}' must have a known SRID")

        cursor.execute(
            """
            SELECT column_name, udt_name
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s AND column_name <> %s
            ORDER BY ordinal_position
            """,
            (schema, layer, geometry_column),
        )
        columns = tuple(cursor.fetchall())

        extent_query = sql.SQL(
            """
            SELECT
                ST_XMin(target_extent), ST_YMin(target_extent),
                ST_XMax(target_extent), ST_YMax(target_extent),
                ST_XMin(wgs84_extent), ST_YMin(wgs84_extent),
                ST_XMax(wgs84_extent), ST_YMax(wgs84_extent)
            FROM (
                SELECT
                    ST_Extent(ST_Transform({geometry}, %s))::box2d AS target_extent,
                    ST_Extent(ST_Transform({geometry}, 4326))::box2d AS wgs84_extent
                FROM {table}
                WHERE {geometry} IS NOT NULL
            ) AS layer_extent
            """
        ).format(
            geometry=sql.Identifier(geometry_column),
            table=sql.Identifier(schema, layer),
        )
        cursor.execute(extent_query, (target_srid,))
        extents = cursor.fetchone()
        if extents is None or any(value is None for value in extents):
            raise ValueError(f"Layer '{schema}.{layer}' contains no non-empty geometry")

    return LayerMetadata(
        geometry_column=str(geometry_column),
        srid=int(srid),
        columns=columns,
        bounds=Bounds(*(float(value) for value in extents[:4])),
        wgs84_bounds=Bounds(*(float(value) for value in extents[4:])),
    )


def build_ranges(bounds: Bounds, grid: str, min_zoom: int, max_zoom: int) -> list[TileRange]:
    range_function = vicgrid_tile_range if grid == "vicgrid" else web_mercator_tile_range
    return [tile_range for z in range(min_zoom, max_zoom + 1) if (tile_range := range_function(bounds, z))]


def attribute_sql(columns: tuple[tuple[str, str], ...]) -> sql.Composed:
    expressions: list[sql.Composable] = []
    for name, udt_name in columns:
        identifier = sql.Identifier(name)
        if udt_name in _NATIVE_MVT_TYPES:
            expressions.append(sql.SQL("t.{}").format(identifier))
        else:
            expressions.append(sql.SQL("CAST(t.{} AS text) AS {}").format(identifier, identifier))
    if not expressions:
        return sql.SQL("")
    return sql.SQL(", ").join(expressions) + sql.SQL(", ")


def render_tile(connection, metadata: LayerMetadata, schema: str, layer: str, grid: str, z: int, x: int, y: int, columns) -> bytes:
    bounds = vicgrid_tile_bounds(z, x, y) if grid == "vicgrid" else web_mercator_tile_bounds(z, x, y)
    if grid == "vicgrid":
        filter_expression = sql.SQL("ST_Segmentize(ST_Expand(tile_geom, %s), %s)")
        filter_parameters = ((bounds.xmax - bounds.xmin) * MVT_BUFFER / MVT_EXTENT, (bounds.xmax - bounds.xmin) / 64)
        target_srid = 7899
    else:
        filter_expression = sql.SQL("tile_geom")
        filter_parameters = ()
        target_srid = 3857

    query = sql.SQL(
        """
        WITH tile_bounds AS (
            SELECT ST_MakeEnvelope(%s, %s, %s, %s, %s) AS tile_geom
        ),
        bounds AS (
            SELECT tile_geom, ST_Transform({filter_expression}, %s) AS source_geom
            FROM tile_bounds
        ),
        tile_rows AS (
            SELECT {attributes}
                ST_AsMVTGeom(ST_Transform(t.{geometry}, %s), bounds.tile_geom, %s, %s, true) AS __mvt_geom
            FROM {table} AS t
            CROSS JOIN bounds
            WHERE t.{geometry} IS NOT NULL
              AND t.{geometry} && bounds.source_geom
              AND ST_Intersects(t.{geometry}, bounds.source_geom)
        )
        SELECT ST_AsMVT(tile_rows, %s, %s, '__mvt_geom')
        FROM tile_rows
        WHERE __mvt_geom IS NOT NULL
        """
    ).format(
        filter_expression=filter_expression,
        attributes=attribute_sql(columns),
        geometry=sql.Identifier(metadata.geometry_column),
        table=sql.Identifier(schema, layer),
    )
    parameters = (
        bounds.xmin, bounds.ymin, bounds.xmax, bounds.ymax, target_srid,
        *filter_parameters,
        metadata.srid, target_srid, MVT_EXTENT, MVT_BUFFER,
        layer, MVT_EXTENT,
    )
    with connection.cursor() as cursor:
        cursor.execute(query, parameters)
        tile = cursor.fetchone()[0]
    return bytes(tile) if tile else b""


def upload_json(s3, bucket: str, key: str, value: dict, cache_control: str) -> None:
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(value, indent=2, sort_keys=True).encode("utf-8"),
        ContentType="application/json",
        CacheControl=cache_control,
        ServerSideEncryption="AES256",
    )


def process_tile(pool, s3, metadata, args, columns, base_key: str, tile: tuple[int, int, int]) -> TileResult:
    z, x, y = tile
    for attempt in range(1, TILE_DATABASE_ATTEMPTS + 1):
        connection = pool.getconn()
        try:
            if not connection.autocommit:
                connection.set_session(readonly=True, autocommit=True)
            payload = render_tile(connection, metadata, args.schema, args.layer, args.grid, z, x, y, columns)
        except (psycopg2.InterfaceError, psycopg2.OperationalError):
            pool.putconn(connection, close=True)
            if attempt == TILE_DATABASE_ATTEMPTS:
                raise
            LOGGER.warning(
                "Database connection failed for tile %s/%s/%s; retrying with a new connection (%s/%s)",
                z, x, y, attempt + 1, TILE_DATABASE_ATTEMPTS,
            )
            time.sleep(2 ** (attempt - 1))
        except BaseException:
            pool.putconn(connection)
            raise
        else:
            pool.putconn(connection)
            break
    compressed = gzip.compress(payload, compresslevel=6, mtime=0)
    s3.put_object(
        Bucket=args.bucket,
        Key=f"{base_key}/{z}/{x}/{y}.mvt",
        Body=compressed,
        ContentType="application/vnd.mapbox-vector-tile",
        ContentEncoding="gzip",
        CacheControl="public,max-age=31536000,immutable",
        ServerSideEncryption="AES256",
    )
    return TileResult(size=len(compressed), empty=not payload)


def iter_tiles(ranges: Iterable[TileRange]) -> Iterable[tuple[int, int, int]]:
    for tile_range in ranges:
        yield from tile_range.tiles()


def run(args: argparse.Namespace) -> dict:
    validate_args(args)
    started = datetime.now(UTC)
    started_clock = time.monotonic()
    target_srid = 7899 if args.grid == "vicgrid" else 3857
    db_settings = connect_kwargs()

    metadata_connection = psycopg2.connect(**db_settings)
    try:
        metadata_connection.set_session(readonly=True, autocommit=True)
        metadata = load_metadata(metadata_connection, args.schema, args.layer, target_srid)
    finally:
        metadata_connection.close()

    columns = selected_columns(metadata.columns, args.fields)
    ranges = build_ranges(metadata.bounds, args.grid, args.min_zoom, args.max_zoom)
    planned = sum(tile_range.count for tile_range in ranges)
    if planned > args.max_tiles:
        raise ValueError(
            f"Layer requires {planned:,} tiles, exceeding --max-tiles {args.max_tiles:,}; "
            "raise the limit explicitly after checking expected cost"
        )

    LOGGER.info("Layer %s.%s spans %s tiles across %s", args.schema, args.layer, f"{planned:,}", args.grid)
    base_key = f"{args.prefix}/{args.schema}/{args.layer}/{args.grid}/{args.version}"
    if args.dry_run:
        return {"dryRun": True, "plannedTiles": planned, "baseKey": base_key, "ranges": [asdict(value) for value in ranges]}

    pool = ThreadedConnectionPool(1, args.workers, **db_settings)
    s3 = boto3.client("s3")
    written = empty = byte_count = completed = 0
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            pending: deque[concurrent.futures.Future[TileResult]] = deque()
            for tile in iter_tiles(ranges):
                pending.append(executor.submit(process_tile, pool, s3, metadata, args, columns, base_key, tile))
                if len(pending) >= args.workers * 4:
                    result = pending.popleft().result()
                    completed += 1
                    written += 1
                    empty += int(result.empty)
                    byte_count += result.size
                    if completed % 1000 == 0:
                        LOGGER.info("Processed %s/%s tiles", f"{completed:,}", f"{planned:,}")
            while pending:
                result = pending.popleft().result()
                completed += 1
                written += 1
                empty += int(result.empty)
                byte_count += result.size
    finally:
        pool.closeall()

    finished = datetime.now(UTC)
    manifest_key = f"{base_key}/tilejson.json"
    tilejson = {
        "tilejson": "3.0.0",
        "name": args.layer,
        "scheme": "xyz",
        "tiles": [f"./{{z}}/{{x}}/{{y}}.mvt"],
        "minzoom": args.min_zoom,
        "maxzoom": args.max_zoom,
        "vector_layers": [{"id": args.layer, "fields": {name: udt for name, udt in columns}}],
        "bounds": [
            metadata.wgs84_bounds.xmin,
            metadata.wgs84_bounds.ymin,
            metadata.wgs84_bounds.xmax,
            metadata.wgs84_bounds.ymax,
        ],
        "nativeBoundsCrs": f"EPSG:{target_srid}",
        "nativeBounds": [metadata.bounds.xmin, metadata.bounds.ymin, metadata.bounds.xmax, metadata.bounds.ymax],
        "grid": args.grid,
    }
    upload_json(s3, args.bucket, manifest_key, tilejson, "public,max-age=31536000,immutable")

    summary = {
        "schema": args.schema,
        "layer": args.layer,
        "grid": args.grid,
        "version": args.version,
        "bucket": args.bucket,
        "baseKey": base_key,
        "manifestKey": manifest_key,
        "startedAt": started.isoformat(),
        "finishedAt": finished.isoformat(),
        "durationSeconds": round(time.monotonic() - started_clock, 3),
        "plannedTiles": planned,
        "writtenTiles": written,
        "emptyTiles": empty,
        "compressedBytes": byte_count,
        "ranges": [asdict(value) for value in ranges],
    }
    upload_json(s3, args.bucket, f"{base_key}/job.json", summary, "public,max-age=31536000,immutable")
    upload_json(
        s3,
        args.bucket,
        f"{args.prefix}/{args.schema}/{args.layer}/{args.grid}/latest.json",
        {"version": args.version, "baseKey": base_key, "manifestKey": manifest_key, "updatedAt": finished.isoformat()},
        "no-cache",
    )
    return summary


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    try:
        result = run(parse_args(argv))
    except Exception:
        LOGGER.exception("Tile-cache job failed")
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
