"""Serve Web Mercator and native GDA2020 / Vicgrid Mapbox Vector Tiles."""

from fastapi import APIRouter, HTTPException, Path, Query, Response

from app.database import database
from app.tile_grids import (
    VICGRID_MAX_ZOOM,
    VICGRID_SRID,
    vicgrid_metadata,
    vicgrid_tile_bounds,
)

router = APIRouter(prefix="/tiles", tags=["tiles"])

MVT_EXTENT = 4096
MVT_BUFFER = 64
MAX_ZOOM = 22

# Types that ST_AsMVT can encode while preserving useful MapLibre value types.
_NATIVE_MVT_TYPES = {
    "bool",
    "int2",
    "int4",
    "int8",
    "float4",
    "float8",
    "numeric",
    "text",
    "varchar",
    "bpchar",
}


def _quote_identifier(value: str) -> str:
    """Quote a validated PostgreSQL identifier."""
    return '"' + value.replace('"', '""') + '"'


async def _layer_metadata(schema: str, layer: str):
    geometry = await database.fetch_one(
        """
        SELECT f_geometry_column AS geom, srid
        FROM geometry_columns
        WHERE f_table_schema = :schema AND f_table_name = :layer
        """,
        {"schema": schema, "layer": layer},
    )
    if geometry is None:
        raise HTTPException(status_code=404, detail=f"Layer '{layer}' not found")
    if not geometry["srid"]:
        raise HTTPException(
            status_code=422,
            detail=f"Layer '{layer}' must have a known SRID to produce tiles",
        )

    columns = await database.fetch_all(
        """
        SELECT column_name AS name, udt_name
        FROM information_schema.columns
        WHERE table_schema = :schema
          AND table_name = :layer
          AND column_name <> :geom
        ORDER BY ordinal_position
        """,
        {"schema": schema, "layer": layer, "geom": geometry["geom"]},
    )
    return geometry, columns


def _attribute_select(columns, fields: str | None) -> str:
    by_name = {column["name"]: column for column in columns}
    if fields is None or not fields.strip() or fields.strip() == "*":
        selected = list(by_name)
    else:
        selected = [name.strip() for name in fields.split(",") if name.strip()]
        unknown = [name for name in selected if name not in by_name]
        if unknown:
            raise HTTPException(
                status_code=422,
                detail=f"Unknown tile fields: {', '.join(unknown)}",
            )

    expressions = []
    for name in selected:
        identifier = _quote_identifier(name)
        if by_name[name]["udt_name"] in _NATIVE_MVT_TYPES:
            expressions.append(f"t.{identifier}")
        else:
            # UUIDs, dates, enums, and other scalar values remain useful as
            # feature properties when represented as strings.
            expressions.append(f"CAST(t.{identifier} AS text) AS {identifier}")
    return (", ".join(expressions) + ", ") if expressions else ""


@router.get("/{layer}/{z}/{x}/{y}.mvt", response_class=Response)
async def vector_tile(
    layer: str,
    z: int = Path(ge=0, le=MAX_ZOOM),
    x: int = Path(ge=0),
    y: int = Path(ge=0),
    schema: str = Query(default="public"),
    fields: str | None = Query(
        default=None,
        description="Comma-separated feature properties; defaults to all attributes",
    ),
):
    """Return one MVT tile generated dynamically from a spatial table."""
    tile_count = 1 << z
    if x >= tile_count or y >= tile_count:
        raise HTTPException(
            status_code=422,
            detail=f"x and y must be between 0 and {tile_count - 1} at zoom {z}",
        )

    return await _render_tile(
        layer, schema, fields, 3857,
        f"ST_TileEnvelope({z}, {x}, {y})", {},
    )


@router.get("/grids/vicgrid")
async def vicgrid_grid():
    """Describe the native grid, including non-power-of-two WMTS zoom levels."""
    return {
        **vicgrid_metadata(),
        "mvtExtent": MVT_EXTENT,
        "mvtBuffer": MVT_BUFFER,
        "sourceLayer": "{layer}",
    }


@router.get("/vicgrid/{layer}/{z}/{x}/{y}.mvt", response_class=Response)
async def vicgrid_vector_tile(
    layer: str,
    z: int = Path(ge=0, le=VICGRID_MAX_ZOOM),
    x: int = Path(ge=0),
    y: int = Path(ge=0),
    schema: str = Query(default="public"),
    fields: str | None = Query(default=None, description="Comma-separated properties; defaults to all attributes"),
):
    """Native EPSG:7899 MVT aligned to Vicmap's GDA2020 WMTS grid.

    z is the zero-based matrix index (0..13), x is the column, y is the row
    counted from the top. These are not Web Mercator tile coordinates.
    """
    try:
        xmin, ymin, xmax, ymax = vicgrid_tile_bounds(z, x, y)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return await _render_tile(
        layer, schema, fields, VICGRID_SRID,
        "ST_MakeEnvelope(:xmin, :ymin, :xmax, :ymax, 7899)",
        {"xmin": xmin, "ymin": ymin, "xmax": xmax, "ymax": ymax,
         "margin": (xmax - xmin) * MVT_BUFFER / MVT_EXTENT,
         "segment_length": (xmax - xmin) / 64},
        buffered=True,
    )


async def _render_tile(layer, schema, fields, target_srid, envelope_sql, bounds_values, *, buffered=False):
    """Shared attribute encoding; envelope/CRS expressions are server-controlled."""
    geometry, columns = await _layer_metadata(schema, layer)
    geom_column = _quote_identifier(geometry["geom"])
    table = f"{_quote_identifier(schema)}.{_quote_identifier(layer)}"
    attributes = _attribute_select(columns, fields)
    srid = int(geometry["srid"])

    # Include features in the MVT buffer. Densify the rectangle before changing
    # CRS because straight Vicgrid edges need not be straight in the data CRS.
    # Keep the existing Mercator selection behavior unchanged.
    filter_envelope = (
        "ST_Segmentize(ST_Expand(tile_geom, :margin), :segment_length)"
        if buffered else "tile_geom"
    )

    sql = f"""
        WITH tile_bounds AS (
            SELECT {envelope_sql} AS tile_geom
        ),
        bounds AS (
            SELECT
                tile_geom,
                ST_Transform({filter_envelope}, {srid}) AS source_geom
            FROM tile_bounds
        ),
        tile_rows AS (
            SELECT
                {attributes}
                ST_AsMVTGeom(
                    ST_Transform(t.{geom_column}, {target_srid}),
                    bounds.tile_geom,
                    {MVT_EXTENT},
                    {MVT_BUFFER},
                    true
                ) AS __mvt_geom
            FROM {table} AS t
            CROSS JOIN bounds
            WHERE t.{geom_column} IS NOT NULL
              AND t.{geom_column} && bounds.source_geom
              AND ST_Intersects(t.{geom_column}, bounds.source_geom)
        )
        SELECT ST_AsMVT(tile_rows, :layer_name, {MVT_EXTENT}, '__mvt_geom') AS tile
        FROM tile_rows
        WHERE __mvt_geom IS NOT NULL
    """
    tile = await database.fetch_val(
        sql,
        {"layer_name": layer, **bounds_values},
    )

    return Response(
        content=bytes(tile) if tile else b"",
        media_type="application/vnd.mapbox-vector-tile",
        headers={"Cache-Control": "public, max-age=300"},
    )