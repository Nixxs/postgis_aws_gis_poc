import unittest
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException
from pydantic import ValidationError

with patch("sqlalchemy.MetaData.create_all"):
    from app.routers.measure import (
        MultiPolygonGeometry,
        PolygonGeometry,
        PolygonMeasureRequest,
        measure_polygon,
    )


SQUARE = {
    "type": "Polygon",
    "coordinates": [[
        [144.95, -37.82],
        [144.951, -37.82],
        [144.951, -37.819],
        [144.95, -37.819],
        [144.95, -37.82],
    ]],
}


class PolygonGeometryValidationTests(unittest.TestCase):
    def test_accepts_exterior_and_interior_rings(self):
        geometry = PolygonGeometry.model_validate({
            "type": "Polygon",
            "coordinates": [
                SQUARE["coordinates"][0],
                [
                    [144.9502, -37.8198],
                    [144.9504, -37.8198],
                    [144.9503, -37.8196],
                    [144.9502, -37.8198],
                ],
            ],
        })
        self.assertEqual(len(geometry.coordinates), 2)

    def test_accepts_multipart_polygons(self):
        geometry = MultiPolygonGeometry.model_validate({
            "type": "MultiPolygon",
            "coordinates": [SQUARE["coordinates"], SQUARE["coordinates"]],
        })
        self.assertEqual(len(geometry.coordinates), 2)

    def test_rejects_open_ring(self):
        with self.assertRaisesRegex(ValidationError, "must be closed"):
            PolygonGeometry.model_validate({
                "type": "Polygon",
                "coordinates": [[
                    [144.95, -37.82],
                    [144.951, -37.82],
                    [144.951, -37.819],
                    [144.95, -37.819],
                ]],
            })

    def test_rejects_ring_with_too_few_distinct_vertices(self):
        with self.assertRaisesRegex(ValidationError, "three distinct vertices"):
            PolygonGeometry.model_validate({
                "type": "Polygon",
                "coordinates": [[
                    [144.95, -37.82],
                    [144.951, -37.82],
                    [144.95, -37.82],
                    [144.95, -37.82],
                ]],
            })

    def test_rejects_non_polygon_and_non_finite_coordinates(self):
        with self.assertRaises(ValidationError):
            PolygonGeometry.model_validate({"type": "LineString", "coordinates": []})
        invalid = dict(SQUARE)
        invalid["coordinates"] = [[[float("nan"), -37.82]] * 4]
        with self.assertRaises(ValidationError):
            PolygonGeometry.model_validate(invalid)


class PolygonMeasureTests(unittest.IsolatedAsyncioTestCase):
    async def test_projects_once_and_returns_ordered_segment_measurements(self):
        validity = {
            "geometry_type": "ST_Polygon",
            "is_empty": False,
            "is_valid": True,
            "validity_reason": "Valid Geometry",
        }
        rows = [
            {"area": 9780.5, "perimeter": 390.0, "polygon_index": polygon, "ring_index": ring, "segment_index": segment, "length": length}
            for polygon, ring, segment, length in (
                (0, 0, 0, 80.0), (0, 0, 1, 100.0), (0, 0, 2, 80.0), (0, 0, 3, 100.0),
                (0, 1, 0, 10.0), (0, 1, 1, 10.0), (0, 1, 2, 10.0),
            )
        ]
        with (
            patch("app.routers.measure.database.fetch_one", new=AsyncMock(return_value=validity)) as fetch_one,
            patch("app.routers.measure.database.fetch_all", new=AsyncMock(return_value=rows)) as fetch_all,
        ):
            response = await measure_polygon(PolygonMeasureRequest(geometry=SQUARE))

        self.assertEqual(response.area, 9780.5)
        self.assertEqual(response.perimeter, 390.0)
        self.assertEqual(
            [(segment.polygonIndex, segment.ringIndex, segment.segmentIndex) for segment in response.segments],
            [(0, 0, 0), (0, 0, 1), (0, 0, 2), (0, 0, 3), (0, 1, 0), (0, 1, 1), (0, 1, 2)],
        )
        self.assertAlmostEqual(sum(segment.length for segment in response.segments), response.perimeter)
        self.assertEqual(response.measurementCrs, "EPSG:7855")
        self.assertEqual(response.areaUnits, "square_metres")
        self.assertIn("ST_IsValid", fetch_one.await_args.args[0])
        measurement_sql = fetch_all.await_args.args[0]
        self.assertEqual(measurement_sql.count("ST_Transform"), 1)
        self.assertIn("ST_Transform(geom, 7855)", measurement_sql)
        self.assertIn("ST_Multi", measurement_sql)
        self.assertIn("ST_DumpSegments", measurement_sql)
        self.assertIn("ST_Area", measurement_sql)

    async def test_rejects_invalid_polygon_before_measuring(self):
        validity = {
            "geometry_type": "ST_Polygon",
            "is_empty": False,
            "is_valid": False,
            "validity_reason": "Self-intersection[1 1]",
        }
        with (
            patch("app.routers.measure.database.fetch_one", new=AsyncMock(return_value=validity)),
            patch("app.routers.measure.database.fetch_all", new=AsyncMock()) as fetch_all,
        ):
            with self.assertRaises(HTTPException) as raised:
                await measure_polygon(PolygonMeasureRequest(geometry=SQUARE))

        self.assertEqual(raised.exception.status_code, 422)
        self.assertIn("Self-intersection", raised.exception.detail)
        fetch_all.assert_not_awaited()
