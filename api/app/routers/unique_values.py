"""unique-values: return the distinct values of one column in a layer.

The front-end uses this to power an autocomplete in the query builder: after
``describe-layer`` tells it which columns exist, the user picks a column and
this returns the values to suggest as they type.

Request body:
    table    required, the spatial table to read
    field    required, the (attribute) column to list values for
    search   optional, case-insensitive substring filter for autocomplete
    limit    optional, max values to return (clamped to MAX_VALUES)
    schema   optional, defaults to "public"

Only real attribute columns are allowed - geometry columns are rejected. The
field is validated against the live schema and then quoted as an identifier, so
no raw user text reaches the SQL except via the parameterised ``search`` value.
"""

import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.database import database

router = APIRouter()
logger = logging.getLogger(__name__)

# Cap how many distinct values we hand back so a high-cardinality column (e.g. a
# parcel id) can't return a huge payload. The UI only needs enough to suggest.
MAX_VALUES = 200
DEFAULT_VALUES = 50


class UniqueValuesRequest(BaseModel):
    table: str
    field: str
    search: str | None = None
    limit: int | None = None
    schema_name: str = Field(default="public", alias="schema")


def _clamp_limit(value) -> int:
    if value is None or str(value).strip() == "":
        return DEFAULT_VALUES
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=422, detail=f"expected an integer limit, got {value!r}"
        )
    if n < 1:
        return 1
    return min(n, MAX_VALUES)


@router.post("/unique-values", status_code=200)
async def unique_values(body: UniqueValuesRequest):
    schema = body.schema_name
    table_name = body.table
    field = body.field

    # 1. Validate the table exists as a spatial layer.
    exists = await database.fetch_one(
        """
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = :schema AND f_table_name = :table_name
        """,
        {"schema": schema, "table_name": table_name},
    )
    if not exists:
        raise HTTPException(status_code=404, detail=f"Layer '{table_name}' not found")

    # 2. Validate the field against the live schema and confirm it isn't geometry.
    column = await database.fetch_one(
        """
        SELECT (gc.f_geometry_column IS NOT NULL) AS is_geometry
        FROM information_schema.columns c
        LEFT JOIN geometry_columns gc
            ON  gc.f_table_schema    = c.table_schema
            AND gc.f_table_name      = c.table_name
            AND gc.f_geometry_column = c.column_name
        WHERE c.table_schema = :schema
          AND c.table_name   = :table_name
          AND c.column_name  = :field
        """,
        {"schema": schema, "table_name": table_name, "field": field},
    )
    if column is None:
        raise HTTPException(status_code=422, detail=f"unknown field: {field!r}")
    if column["is_geometry"]:
        raise HTTPException(
            status_code=422, detail=f"field {field!r} is a geometry column"
        )

    clamped = _clamp_limit(body.limit)

    # The schema/table/field are validated above, so quoting them as identifiers
    # is safe. The search term is bound as a parameter (:search).
    sql = (
        f'SELECT DISTINCT "{field}" AS value '
        f'FROM "{schema}"."{table_name}" '
        f'WHERE "{field}" IS NOT NULL'
    )
    args = {"limit": clamped}
    if body.search and body.search.strip():
        sql += f' AND lower(CAST("{field}" AS VARCHAR)) LIKE :search'
        args["search"] = f"%{body.search.strip().lower()}%"
    sql += " ORDER BY value LIMIT :limit"

    rows = await database.fetch_all(sql, args)
    values = [row["value"] for row in rows]

    return {
        "layer": table_name,
        "field": field,
        "values": values,
        "truncated": len(values) >= clamped,
    }
