import logging
from typing import Annotated

from fastapi import APIRouter, HTTPException, Depends

from app.database import database

router = APIRouter()
logger = logging.getLogger(__name__)

@router.get("/describe-layer/{table_name}", status_code=200)
async def describe_spatial_table(table_name: str, schema: str = "public"):
    # 1. Validate the table exists as a spatial layer (prevents SQL injection
    #    on the count query, since the table name can't be a bind parameter).
    exists = await database.fetch_one(
        """
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = :schema AND f_table_name = :table_name
        """,
        {"schema": schema, "table_name": table_name},
    )
    if not exists:
        raise HTTPException(status_code=404, detail=f"Layer '{table_name}' not found")

    # 2. Column metadata
    columns = await database.fetch_all(
        """
        SELECT
            c.column_name                       AS name,
            c.data_type                         AS type,
            (c.is_nullable = 'YES')             AS nullable,
            (gc.f_geometry_column IS NOT NULL)  AS is_geometry
        FROM information_schema.columns c
        LEFT JOIN geometry_columns gc
            ON  gc.f_table_schema    = c.table_schema
            AND gc.f_table_name      = c.table_name
            AND gc.f_geometry_column = c.column_name
        WHERE c.table_schema = :schema
          AND c.table_name   = :table_name
        ORDER BY c.ordinal_position
        """,
        {"schema": schema, "table_name": table_name},
    )

    # 3. Feature count. Table name is validated above, so it's safe to embed.
    #    Quote identifiers to be safe.
    count_row = await database.fetch_one(
        f'SELECT COUNT(*) AS feature_count FROM "{schema}"."{table_name}"'
    )

    return {
        "layer": table_name,
        "feature_count": count_row["feature_count"],
        "columns": [dict(c) for c in columns],
    }