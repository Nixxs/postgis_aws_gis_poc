import math
import unittest

from app.tiling import (
    Bounds,
    VICGRID_ORIGIN,
    VICGRID_SIZES,
    WEB_MERCATOR_LIMIT,
    vicgrid_tile_bounds,
    vicgrid_tile_range,
    web_mercator_tile_bounds,
    web_mercator_tile_range,
)


class BoundsTests(unittest.TestCase):
    def test_rejects_non_finite_or_empty_bounds(self):
        with self.assertRaises(ValueError):
            Bounds(0, 0, math.inf, 1)
        with self.assertRaises(ValueError):
            Bounds(0, 0, 0, 1)


class WebMercatorTests(unittest.TestCase):
    def test_world_is_one_tile_at_zoom_zero(self):
        result = web_mercator_tile_range(
            Bounds(-WEB_MERCATOR_LIMIT, -WEB_MERCATOR_LIMIT, WEB_MERCATOR_LIMIT, WEB_MERCATOR_LIMIT),
            0,
        )
        self.assertIsNotNone(result)
        self.assertEqual((result.min_x, result.max_x, result.min_y, result.max_y), (0, 0, 0, 0))

    def test_bounds_outside_world_return_none(self):
        result = web_mercator_tile_range(
            Bounds(WEB_MERCATOR_LIMIT + 1, 0, WEB_MERCATOR_LIMIT + 2, 1),
            3,
        )
        self.assertIsNone(result)

    def test_tile_bounds_round_trip(self):
        bounds = web_mercator_tile_bounds(3, 5, 2)
        result = web_mercator_tile_range(bounds, 3)
        self.assertEqual(result.count, 1)
        self.assertEqual(next(result.tiles()), (3, 5, 2))


class VicgridTests(unittest.TestCase):
    def test_origin_tile_round_trip(self):
        bounds = vicgrid_tile_bounds(6, 0, 0)
        result = vicgrid_tile_range(bounds, 6)
        self.assertEqual(result.count, 1)
        self.assertEqual(next(result.tiles()), (6, 0, 0))

    def test_grid_dimensions_are_enforced(self):
        width, height = VICGRID_SIZES[13]
        bounds = vicgrid_tile_bounds(13, width - 1, height - 1)
        result = vicgrid_tile_range(bounds, 13)
        self.assertEqual((result.min_x, result.max_x), (width - 1, width - 1))
        self.assertEqual((result.min_y, result.max_y), (height - 1, height - 1))

    def test_bounds_north_of_grid_return_none(self):
        left, top = VICGRID_ORIGIN
        result = vicgrid_tile_range(Bounds(left, top + 1, left + 1, top + 2), 2)
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
