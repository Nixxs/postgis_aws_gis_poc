"""Measure planar distances in Victoria from WGS84 longitude/latitude pairs."""

from typing import Annotated, Literal

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.database import database

router = APIRouter(tags=["measure"])

Longitude = Annotated[float, Field(ge=-180, le=180, allow_inf_nan=False)]
Latitude = Annotated[float, Field(ge=-90, le=90, allow_inf_nan=False)]
Position = tuple[Longitude, Latitude]


class MeasureRequest(BaseModel):
    start: Position = Field(description="WGS84 [longitude, latitude] in degrees")
    end: Position = Field(description="WGS84 [longitude, latitude] in degrees")


class MeasureResponse(BaseModel):
    distance: float = Field(ge=0, allow_inf_nan=False, description="2D grid distance in metres")
    units: Literal["metres"] = "metres"
    sourceCrs: Literal["EPSG:4326"] = "EPSG:4326"
    measurementCrs: Literal["EPSG:7855"] = "EPSG:7855"


@router.post("/measure", response_model=MeasureResponse, status_code=200)
async def measure(body: MeasureRequest) -> MeasureResponse:
    """Transform to GDA2020 / MGA zone 55 and measure the grid distance.

    EPSG:7855 uses metres and is appropriate for Melbourne and the part of
    Victoria in MGA zone 55 (144 to 150 degrees east). Western Victoria is in
    zone 54; this endpoint does not select zones automatically. This is a
    projected 2D distance, not a geodesic, road-route, or terrain distance.
    """
    distance = await database.fetch_val(
        """
        SELECT ST_Distance(
            ST_Transform(ST_SetSRID(ST_MakePoint(:start_lon, :start_lat), 4326), 7855),
            ST_Transform(ST_SetSRID(ST_MakePoint(:end_lon, :end_lat), 4326), 7855)
        )
        """,
        {
            "start_lon": body.start[0],
            "start_lat": body.start[1],
            "end_lon": body.end[0],
            "end_lat": body.end[1],
        },
    )
    return MeasureResponse(distance=distance)