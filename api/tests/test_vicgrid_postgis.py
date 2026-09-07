"""Opt-in integration tests: RUN_POSTGIS_TILE_TESTS=1, using the API's DB settings.

Only creates a temporary table inside a rolled-back transaction. No application
tables are changed. Run from api: python -m unittest discover -s tests -p '*tile*.py'
or specify this file explicitly.
"""

import os
import unittest

from fastapi import HTTPException

from app.tile_grids import vicgrid_tile_bounds


@unittest.skipUnless(os.environ.get('RUN_POSTGIS_TILE_TESTS') == '1', 'Requires local PostGIS; opt in explicitly')
class PostgisTileTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from app.database import database
        from app.routers import tiles
        self.database, self.tiles = database, tiles
        await database.connect()
        self.transaction = database.transaction(force_rollback=True)
        await self.transaction.start()
        await database.execute('CREATE TEMP TABLE vicgrid_test (id integer, label text, geom geometry(Point,4326)) ON COMMIT DROP')
        self.schema = await database.fetch_val('SELECT pg_my_temp_schema()::regnamespace::text')
        self.bounds = vicgrid_tile_bounds(8, 193, 196)
        xmin, ymin, xmax, ymax = self.bounds
        span = xmax - xmin
        # Centre point, a point just inside the buffer, and a point outside it.
        for ident, px in ((1, (xmin + xmax) / 2), (2, xmax + span / 128), (3, xmax + span)):
            await database.execute(
                'INSERT INTO vicgrid_test VALUES (:id, :label, ST_Transform(ST_SetSRID(ST_MakePoint(:x, :y),7899),4326))',
                {'id': ident, 'label': f'point-{ident}', 'x': px, 'y': (ymin + ymax) / 2},
            )

    async def asyncTearDown(self):
        await self.transaction.rollback()
        await self.database.disconnect()

    async def test_native_bytes_match_known_tile_coordinates_and_buffer(self):
        response = await self.tiles.vicgrid_vector_tile('vicgrid_test', 8, 193, 196, self.schema, None)
        # Independent MVT fixture: centre = (2048,2048), buffer point = (4128,2048).
        expected = await self.database.fetch_val("""
            SELECT ST_AsMVT(q, 'vicgrid_test', 4096, '__mvt_geom') FROM (
                SELECT 1 AS id, 'point-1' AS label, ST_MakePoint(2048,2048) AS __mvt_geom
                UNION ALL
                SELECT 2, 'point-2', ST_MakePoint(4128,2048)
            ) AS q
        """)
        self.assertEqual(response.body, bytes(expected))
        self.assertEqual(response.media_type, 'application/vnd.mapbox-vector-tile')
        self.assertEqual(response.headers['cache-control'], 'public, max-age=300')

    async def test_web_mercator_matches_original_sql(self):
        response = await self.tiles.vector_tile('vicgrid_test', 8, 230, 157, self.schema, None)
        expected = await self.database.fetch_val("""
            WITH bounds AS (
                SELECT ST_TileEnvelope(8,230,157) AS tile_geom,
                       ST_Transform(ST_TileEnvelope(8,230,157),4326) AS source_geom
            ), tile_rows AS (
                SELECT t.id, t.label,
                       ST_AsMVTGeom(ST_Transform(t.geom,3857), bounds.tile_geom,4096,64,true) AS __mvt_geom
                FROM vicgrid_test t CROSS JOIN bounds
                WHERE t.geom IS NOT NULL AND t.geom && bounds.source_geom
                  AND ST_Intersects(t.geom,bounds.source_geom)
            )
            SELECT ST_AsMVT(tile_rows,'vicgrid_test',4096,'__mvt_geom') FROM tile_rows
            WHERE __mvt_geom IS NOT NULL
        """)
        self.assertTrue(response.body)
        self.assertEqual(response.body, bytes(expected))

    async def test_empty_native_tile(self):
        response = await self.tiles.vicgrid_vector_tile('vicgrid_test', 8, 0, 0, self.schema, None)
        self.assertEqual(response.body, b'')

    async def test_invalid_grid_layer_and_fields(self):
        for layer, z, x, y, fields, status in (
            ('vicgrid_test', 6, 160, 0, None, 422),
            ('vicgrid_test', 6, 0, 80, None, 422),
            ('vicgrid_test', 14, 0, 0, None, 422),
            ('missing_layer', 0, 0, 0, None, 404),
            ('vicgrid_test', 0, 0, 0, 'unknown_field', 422),
        ):
            with self.subTest(layer=layer, z=z, x=x, y=y, fields=fields):
                with self.assertRaises(HTTPException) as context:
                    await self.tiles.vicgrid_vector_tile(layer, z, x, y, self.schema, fields)
                self.assertEqual(context.exception.status_code, status)