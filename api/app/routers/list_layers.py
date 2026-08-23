import logging
from typing import Annotated

from fastapi import APIRouter, HTTPException, Depends

from app.database import database

router = APIRouter()
logger = logging.getLogger(__name__)

@router.get("/list-layers", status_code=200)
async def list_spatial_tables():
    query = """
        SELECT f_table_schema  AS schema,
               f_table_name    AS table,
               f_geometry_column AS geometry_column,
               srid,
               type
        FROM geometry_columns
        WHERE f_table_schema IN ('public')
        ORDER BY f_table_schema, f_table_name;
    """
    rows = await database.fetch_all(query)
    return {"layers": [row["table"] for row in rows]}