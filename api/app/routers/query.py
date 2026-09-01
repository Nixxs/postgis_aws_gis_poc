"""query: return rows from a layer, Esri-style.

This mirrors a useful subset of the ArcGIS Feature Service ``query`` operation
so the parameters are familiar to GIS clients (sent as a JSON POST body):

    layer              required, the spatial table to query
    where              SQL-92 WHERE clause (the only raw user SQL we accept)
    outFields          comma list of fields, or * (default: all attributes)
    orderByFields      e.g. "Shape_Area DESC, lga ASC"
    resultOffset       skip N rows (default 0)
    resultRecordCount  page size, clamped to MAX_RECORD_COUNT
    returnCountOnly    true -> {"count": N} fast path
    f                  "json" (default, attributes only) or "geojson"
    returnGeometry     true also forces geometry output (GeoJSON)
    geometry           GeoJSON geometry to spatially filter by (assumed EPSG:4326)
    spatialRel         spatial predicate for `geometry`, Esri names
                       (default esriSpatialRelIntersects)

For f=geojson the response is a GeoJSON FeatureCollection: each feature's
attributes become ``properties`` and the layer's geometry column is converted to
GeoJSON via PostGIS (ST_AsGeoJSON), ready to drop onto a map.

Security model ("standardized queries", lite): the only place raw user SQL
lands is ``where``, which we inject as ``WHERE (<where>)``. We harden it the way
Esri's standardized queries do:

  * single statement only - reject ``;`` and SQL comments,
  * a blocklist of file/SSRF functions (pg_read_file, dblink, copy, lo_import),
  * the clause is wrapped in parentheses so an attempted breakout (e.g.
    ``1=1) UNION SELECT ...``) produces unbalanced parens and a clean parse error,
  * outFields / orderByFields are validated against the live schema, and the
    page size is clamped.

This is acceptable here because the data behind it is already public. If this
ever fronts private data, replace the raw ``where`` with a parsed/whitelisted
filter builder instead.
"""

import json
import logging

import asyncpg
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.database import database

router = APIRouter()
logger = logging.getLogger(__name__)

# Server-side cap on rows returned, mirroring Esri's maxRecordCount.
MAX_RECORD_COUNT = 1000
DEFAULT_RECORD_COUNT = 200
MAX_BUFFER_METERS = 50000

_ORDER_DIRECTIONS = {"ASC", "DESC"}

# Esri spatialRel names -> PostGIS predicate functions.
_SPATIAL_REL = {
    "esriSpatialRelIntersects": "ST_Intersects",
    "esriSpatialRelContains": "ST_Contains",
    "esriSpatialRelWithin": "ST_Within",
    "esriSpatialRelCrosses": "ST_Crosses",
    "esriSpatialRelOverlaps": "ST_Overlaps",
    "esriSpatialRelTouches": "ST_Touches",
}

# Lowercased fragments that must never appear in a WHERE clause: SQL statement
# terminators/comments and the functions that could read arbitrary files or make
# outbound requests from inside a scalar subquery.
_FORBIDDEN = (
    ";", "--", "/*", "*/",
    "pg_read", "pg_ls", "pg_stat_file", "pg_sleep",
    "dblink", "lo_import", "lo_export", "copy ",
)

# Postgres SQLSTATE classes that mean "the user's query is bad" (-> 400) rather
# than an infrastructure failure (-> 500): syntax/access, data exception,
# invalid cursor/transaction, undefined objects.
_BAD_QUERY_SQLSTATE = ("42", "22", "2F", "38")


class QueryRequest(BaseModel):
    layer: str
    where: str | None = None
    outFields: str | None = None
    orderByFields: str | None = None
    resultOffset: int | None = None
    resultRecordCount: int | None = None
    returnCountOnly: bool = False
    returnGeometry: bool = False
    f: str = "json"
    geometry: dict | None = None
    spatialRel: str = "esriSpatialRelIntersects"
    schema_name: str = Field(default="public", alias="schema")


class SpatialQueryRequest(BaseModel):
    layer: str
    geometry: dict
    buffer: float = 0
    schema_name: str = Field(default="public", alias="schema")


def _clamp_int(value, default: int, lo: int, hi=None) -> int:
    if value is None:
        n = default
    else:
        try:
            n = int(value)
        except (TypeError, ValueError):
            raise HTTPException(status_code=422, detail=f"expected an integer, got {value!r}")
    if n < lo:
        n = lo
    if hi is not None and n > hi:
        n = hi
    return n


def _check_where(where: str):
    lowered = where.lower()
    for token in _FORBIDDEN:
        if token in lowered:
            raise HTTPException(status_code=422, detail="where clause contains disallowed syntax")


def _select_fields(out_fields, attribute_names):
    """Resolve outFields to a validated column list (geometry excluded)."""
    if not out_fields or out_fields.strip() == "*":
        return list(attribute_names)
    requested = [f.strip() for f in out_fields.split(",") if f.strip()]
    unknown = [f for f in requested if f not in attribute_names]
    if unknown:
        raise HTTPException(status_code=422, detail=f"unknown outFields: {', '.join(unknown)}")
    return requested


def _order_by_clause(order_by_fields, valid_names):
    if not order_by_fields or not order_by_fields.strip():
        return ""
    parts = []
    for token in order_by_fields.split(","):
        token = token.strip()
        if not token:
            continue
        bits = token.split()
        field = bits[0]
        direction = bits[1].upper() if len(bits) > 1 else "ASC"
        if field not in valid_names:
            raise HTTPException(status_code=422, detail=f"unknown orderByFields field: {field!r}")
        if direction not in _ORDER_DIRECTIONS:
            raise HTTPException(status_code=422, detail=f"invalid sort direction: {direction!r}")
        parts.append(f'"{field}" {direction}')
    return " ORDER BY " + ", ".join(parts) if parts else ""


async def _run(query: str, values: dict):
    """Execute SQL, mapping user-caused query errors to HTTP 400."""
    try:
        return await database.fetch_all(query, values)
    except asyncpg.PostgresError as exc:
        sqlstate = getattr(exc, "sqlstate", "") or ""
        if sqlstate[:2] in _BAD_QUERY_SQLSTATE:
            raise HTTPException(status_code=400, detail=f"invalid query: {exc}")
        raise


async def _layer_info(schema: str, layer: str):
    """Return (geometry column name, srid, geometry type) or 404."""
    row = await database.fetch_one(
        """
        SELECT f_geometry_column AS geom, srid, type
        FROM geometry_columns
        WHERE f_table_schema = :schema AND f_table_name = :layer
        """,
        {"schema": schema, "layer": layer},
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"Layer '{layer}' not found")
    return row["geom"], row["srid"], row["type"]


async def _layer_columns(schema: str, layer: str, geom_col: str):
    rows = await database.fetch_all(
        """
        SELECT column_name AS name
        FROM information_schema.columns
        WHERE table_schema = :schema AND table_name = :layer
        ORDER BY ordinal_position
        """,
        {"schema": schema, "layer": layer},
    )
    all_names = [r["name"] for r in rows]
    attribute_names = [n for n in all_names if n != geom_col]
    return all_names, attribute_names


def _spatial_filter(geometry: dict | None, spatial_rel: str, geom_col: str, srid, args: dict) -> str:
    """Build a spatial predicate clause from a GeoJSON geometry (EPSG:4326)."""
    if not geometry:
        return ""
    func = _SPATIAL_REL.get(spatial_rel)
    if func is None:
        raise HTTPException(status_code=422, detail=f"unsupported spatialRel: {spatial_rel!r}")
    args["filter_geom"] = json.dumps(geometry)
    # Input GeoJSON is EPSG:4326; transform it to the layer's SRID when needed.
    input_geom = "ST_SetSRID(ST_GeomFromGeoJSON(:filter_geom), 4326)"
    if srid and srid not in (0, 4326):
        input_geom = f"ST_Transform({input_geom}, {int(srid)})"
    return f' AND {func}("{geom_col}", {input_geom})'


@router.post("/query", status_code=200)
async def query_layer(body: QueryRequest):
    schema = body.schema_name
    layer = body.layer

    fmt = (body.f or "json").lower()
    if fmt not in ("json", "geojson"):
        raise HTTPException(status_code=422, detail=f"unsupported format: {fmt!r} (use 'json' or 'geojson')")

    geom_col, srid, _geom_type = await _layer_info(schema, layer)
    want_geometry = fmt == "geojson" or body.returnGeometry

    all_names, attribute_names = await _layer_columns(schema, layer, geom_col)
    table = f'"{schema}"."{layer}"'

    # Optional WHERE clause, wrapped in parens so a breakout attempt can't escape
    # it. "1=1" is the Esri idiom for "no filter", so treat it as empty.
    args: dict = {}
    where = body.where
    where_sql = ""
    if where and where.strip() and where.strip() != "1=1":
        _check_where(where)
        where_sql = f" WHERE ({where})"

    # Optional spatial filter (Esri geometry + spatialRel). Combine with the
    # attribute WHERE, opening one if there wasn't one already.
    spatial_sql = _spatial_filter(body.geometry, body.spatialRel, geom_col, srid, args)
    if spatial_sql:
        where_sql = (where_sql + spatial_sql) if where_sql else f" WHERE (TRUE{spatial_sql})"

    if body.returnCountOnly:
        rows = await _run(f"SELECT count(*) AS count FROM {table}{where_sql}", args)
        return {"layer": layer, "count": rows[0]["count"]}

    fields = _select_fields(body.outFields, attribute_names)
    order_sql = _order_by_clause(body.orderByFields, all_names)
    limit = _clamp_int(body.resultRecordCount, DEFAULT_RECORD_COUNT, 1, MAX_RECORD_COUNT)
    offset = _clamp_int(body.resultOffset, 0, 0)
    args["limit"] = limit
    args["offset"] = offset

    if want_geometry:
        if not geom_col:
            raise HTTPException(status_code=422, detail=f"layer {layer!r} has no geometry column")
        return await _query_geojson(
            table, layer, fields, geom_col, srid, where_sql, order_sql, args, limit, offset
        )

    select_list = ", ".join(f'"{f}"' for f in fields) or "*"
    sql = f"SELECT {select_list} FROM {table}{where_sql}{order_sql} LIMIT :limit OFFSET :offset"

    rows = await _run(sql, args)
    features = [dict(r) for r in rows]

    return {
        "layer": layer,
        "count": len(features),
        "resultOffset": offset,
        "resultRecordCount": limit,
        "fields": fields,
        "features": features,
    }


async def _query_geojson(table, layer, fields, geom_col, srid, where_sql, order_sql, args, limit, offset):
    """Return a GeoJSON FeatureCollection (attributes as properties + geometry)."""
    # Emit geometry as EPSG:4326 GeoJSON; transform from the layer SRID if needed.
    geom = f'"{geom_col}"'
    if srid and srid not in (0, 4326):
        geom = f"ST_Transform({geom}, 4326)"
    geom_expr = f"ST_AsGeoJSON({geom})"

    select_list = ", ".join(f'"{f}"' for f in fields)
    if select_list:
        select_list += ", "
    sql = (
        f"SELECT {select_list}{geom_expr} AS __geojson "
        f"FROM {table}{where_sql}{order_sql} LIMIT :limit OFFSET :offset"
    )

    rows = await _run(sql, args)
    features = []
    for record in rows:
        row = dict(record)
        geom_raw = row.pop("__geojson", None)
        geometry = json.loads(geom_raw) if geom_raw else None
        features.append({"type": "Feature", "geometry": geometry, "properties": row})

    return {
        "type": "FeatureCollection",
        "features": features,
        # Non-standard extras the client can ignore; handy for paging/debugging.
        "layer": layer,
        "count": len(features),
        "resultOffset": offset,
        "resultRecordCount": limit,
    }


@router.post("/spatial-query", status_code=200)
async def spatial_query(body: SpatialQueryRequest):
    """Return features intersecting a GeoJSON geometry buffered in metres."""
    buffer_meters = min(max(float(body.buffer), 0), MAX_BUFFER_METERS)
    geometry_json = json.dumps(body.geometry)
    query_geometry_json = await database.fetch_val(
        """
        WITH input AS (
            SELECT ST_SetSRID(ST_GeomFromGeoJSON(:geometry), 4326) AS geom
        )
        SELECT ST_AsGeoJSON(
            CASE
                WHEN :buffer_meters > 0
                THEN ST_Buffer(geom::geography, :buffer_meters)::geometry
                ELSE geom
            END
        )
        FROM input
        """,
        {"geometry": geometry_json, "buffer_meters": buffer_meters},
    )
    if not query_geometry_json:
        raise HTTPException(status_code=422, detail="invalid query geometry")

    result = await query_layer(
        QueryRequest(
            layer=body.layer,
            geometry=json.loads(query_geometry_json),
            f="geojson",
            resultRecordCount=MAX_RECORD_COUNT,
            schema=body.schema_name,
        )
    )
    result["bufferMeters"] = buffer_meters
    result["queryGeometry"] = json.loads(query_geometry_json)
    return result
