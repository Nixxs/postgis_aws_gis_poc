import unittest

from app.tile_grids import (
    VICGRID_ORIGIN, VICGRID_RESOLUTIONS, VICGRID_SIZES,
    vicgrid_metadata, vicgrid_tile_bounds,
)


class VicgridTests(unittest.TestCase):
    def test_metadata_matches_verified_wmts(self):
        grid = vicgrid_metadata()
        self.assertEqual(grid['crs'], 'EPSG:7899')
        self.assertEqual(grid['origin'], (1786000.0, 3081000.0))
        self.assertEqual(grid['tileSize'], 512)
        self.assertEqual(grid['matrixIds'], [f'{z:02d}' for z in range(14)])
        self.assertEqual(grid['sizes'][6], (160, 80))
        self.assertEqual(grid['sizes'][13], (20000, 10000))
        self.assertAlmostEqual(grid['resolutions'][6], 26.45838625010582)
        self.assertAlmostEqual(grid['resolutions'][13], 0.211667090000856)

    def test_shared_edges_and_row_direction_at_every_zoom(self):
        for z in range(14):
            with self.subTest(z=z):
                first = vicgrid_tile_bounds(z, 0, 0)
                next_column = vicgrid_tile_bounds(z, 1, 0)
                self.assertEqual(first[0], VICGRID_ORIGIN[0])
                self.assertEqual(first[3], VICGRID_ORIGIN[1])
                self.assertEqual(first[2], next_column[0])
                self.assertAlmostEqual(first[2] - first[0], 512 * VICGRID_RESOLUTIONS[z])
                if VICGRID_SIZES[z][1] > 1:
                    next_row = vicgrid_tile_bounds(z, 0, 1)
                    self.assertEqual(first[1], next_row[3])

    def test_matrix_limits_not_xyz_limits(self):
        vicgrid_tile_bounds(6, 159, 79)  # valid despite exceeding 2**6
        for z, (width, height) in enumerate(VICGRID_SIZES):
            vicgrid_tile_bounds(z, width - 1, height - 1)
            for x, y in ((width, 0), (0, height), (-1, 0), (0, -1)):
                with self.subTest(z=z, x=x, y=y), self.assertRaises(ValueError):
                    vicgrid_tile_bounds(z, x, y)
        for z in (-1, 14, 22):
            with self.assertRaises(ValueError):
                vicgrid_tile_bounds(z, 0, 0)