"""Measure planar distances and polygon areas in GDA2020 / MGA zone 55."""

import json
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, model_validator

from app.database import database

router = APIRouter(tags=["measure"])

Longitude = Annotated[float, Field(ge=-180, le=180, allow_inf_nan=False)]
Latitude = Annotated[float, Field(ge=-90, le=90, allow_inf_nan=False)]
Position = tuple[Longitude, Latitude]
MAX_POLYGON_VERTICES = 10_000


def _validate_polygon_rings(polygons: list[list[list[Position]]]) -> None:
    if not polygons:
        raise ValueError("Geometry must contain at least one polygon")
    vertex_count = 0
    for polygon_index, rings in enumerate(polygons):
        if not rings:
            raise ValueError(f"Polygon {polygon_index} must contain an exterior ring")
        for ring_index, ring in enumerate(rings):
            vertex_count += len(ring)
            label = f"Polygon {polygon_index} ring {ring_index}"
            if len(ring) < 4:
                raise ValueError(f"{label} must contain at least four positions")
            if ring[0] != ring[-1]:
                raise ValueError(f"{label} must be closed")
            if len(set(ring[:-1])) < 3:
                raise ValueError(f"{label} must contain at least three distinct vertices")
    if vertex_count > MAX_POLYGON_VERTICES:
        raise ValueError(f"Geometry may contain at most {MAX_POLYGON_VERTICES} positions")


class MeasureRequest(BaseModel):
    start: Position = Field(description="WGS84 [longitude, latitude] in degrees")
    end: Position = Field(description="WGS84 [longitude, latitude] in degrees")


class MeasureResponse(BaseModel):
    distance: float = Field(ge=0, allow_inf_nan=False, description="2D grid distance in metres")
    units: Literal["metres"] = "metres"
    sourceCrs: Literal["EPSG:4326"] = "EPSG:4326"
    measurementCrs: Literal["EPSG:7855"] = "EPSG:7855"


class PolygonGeometry(BaseModel):
    type: Literal["Polygon"]
    coordinates: list[list[Position]]

    @model_validator(mode="after")
    def validate_rings(self) -> "PolygonGeometry":
        _validate_polygon_rings([self.coordinates])
        return self


class MultiPolygonGeometry(BaseModel):
    type: Literal["MultiPolygon"]
    coordinates: list[list[list[Position]]]

    @model_validator(mode="after")
    def validate_rings(self) -> "MultiPolygonGeometry":
        _validate_polygon_rings(self.coordinates)
        return self


class PolygonMeasureRequest(BaseModel):
    geometry: PolygonGeometry | MultiPolygonGeometry = Field(description="GeoJSON Polygon or MultiPolygon in WGS84 (EPSG:4326)")


class SegmentMeasurement(BaseModel):
    polygonIndex: int = Field(ge=0, description="Zero-based polygon part index")
    ringIndex: int = Field(ge=0, description="Zero-based ring index; zero is the exterior ring")
    segmentIndex: int = Field(ge=0, description="Zero-based segment index within the ring")
    length: float = Field(ge=0, allow_inf_nan=False, description="2D grid length in metres")


class PolygonMeasureResponse(BaseModel):
    area: float = Field(ge=0, allow_inf_nan=False, description="2D polygon area in square metres")
    perimeter: float = Field(ge=0, allow_inf_nan=False, description="Total exterior and interior ring length in metres")
    segments: list[SegmentMeasurement]
    lengthUnits: Literal["metres"] = "metres"
    areaUnits: Literal["square_metres"] = "square_metres"
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


@router.post("/measure/polygon", response_model=PolygonMeasureResponse, status_code=200)
async def measure_polygon(body: PolygonMeasureRequest) -> PolygonMeasureResponse:
    """Measure WGS84 polygonal geometry in GDA2020 / MGA zone 55.

    Area is the polygon area (subtracting valid interior rings), perimeter is
    the combined length of all rings and parts, and segments contains every
    ring edge in source order. Measurements are planar EPSG:7855 grid values
    and are most appropriate within MGA zone 55 (144 to 150 degrees east).
    """
    geometry_json = json.dumps(body.geometry.model_dump())
    validity = await database.fetch_one(
        """
        WITH input AS (
            SELECT ST_SetSRID(ST_GeomFromGeoJSON(:geometry), 4326) AS geom
        )
        SELECT
            ST_GeometryType(geom) AS geometry_type,
            ST_IsEmpty(geom) AS is_empty,
            ST_IsValid(geom) AS is_valid,
            ST_IsValidReason(geom) AS validity_reason
        FROM input
        """,
        {"geometry": geometry_json},
    )
    if validity is None or validity["geometry_type"] not in ("ST_Polygon", "ST_MultiPolygon") or validity["is_empty"]:
        raise HTTPException(status_code=422, detail="geometry must be a non-empty GeoJSON Polygon or MultiPolygon")
    if not validity["is_valid"]:
        raise HTTPException(status_code=422, detail=f"invalid polygon geometry: {validity['validity_reason']}")

    rows = await database.fetch_all(
        """
        WITH input AS (
            SELECT ST_SetSRID(ST_GeomFromGeoJSON(:geometry), 4326) AS geom
        ),
        projected AS (
            SELECT ST_Multi(ST_Transform(geom, 7855)) AS geom
            FROM input
        )
        SELECT
            ST_Area(projected.geom) AS area,
            ST_Perimeter(projected.geom) AS perimeter,
            segment.path[1] - 1 AS polygon_index,
            segment.path[2] - 1 AS ring_index,
            segment.path[3] - 1 AS segment_index,
            ST_Length(segment.geom) AS length
        FROM projected
        CROSS JOIN LATERAL ST_DumpSegments(projected.geom) AS segment
        ORDER BY segment.path
        """,
        {"geometry": geometry_json},
    )
    if not rows:
        raise HTTPException(status_code=422, detail="polygon contains no measurable segments")

    return PolygonMeasureResponse(
        area=float(rows[0]["area"]),
        perimeter=float(rows[0]["perimeter"]),
        segments=[
            SegmentMeasurement(
                polygonIndex=int(row["polygon_index"]),
                ringIndex=int(row["ring_index"]),
                segmentIndex=int(row["segment_index"]),
                length=float(row["length"]),
            )
            for row in rows
        ],
    )