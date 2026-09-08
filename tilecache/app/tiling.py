"""Pure tile-grid calculations shared by the tile-cache batch job."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterator

WEB_MERCATOR_LIMIT = 20_037_508.342789244
VICGRID_ORIGIN = (1_786_000.0, 3_081_000.0)
VICGRID_TILE_SIZE = 512
VICGRID_SCALES = (
    7_559_538.928601667,
    3_779_769.4643008336,
    1_889_884.7321504168,
    944_942.3660752084,
    472_471.1830376042,
    236_235.5915188021,
    94_494.2366075208,
    47_247.1183037604,
    23_623.5591518802,
    9_449.4236607521,
    4_724.711830376,
    2_362.355915188,
    1_181.177957594,
    755.9538928602,
)
VICGRID_SIZES = (
    (2, 1), (4, 2), (8, 4), (16, 8), (32, 16), (64, 32),
    (160, 80), (320, 160), (640, 320), (1600, 800),
    (3200, 1600), (6400, 3200), (12800, 6400), (20000, 10000),
)
VICGRID_RESOLUTIONS = tuple(scale * 0.00028 for scale in VICGRID_SCALES)
VICGRID_MAX_ZOOM = len(VICGRID_SCALES) - 1


@dataclass(frozen=True)
class Bounds:
    xmin: float
    ymin: float
    xmax: float
    ymax: float

    def __post_init__(self) -> None:
        values = (self.xmin, self.ymin, self.xmax, self.ymax)
        if not all(math.isfinite(value) for value in values):
            raise ValueError("Bounds must be finite")
        if self.xmin >= self.xmax or self.ymin >= self.ymax:
            raise ValueError("Bounds must have positive width and height")


@dataclass(frozen=True)
class TileRange:
    z: int
    min_x: int
    max_x: int
    min_y: int
    max_y: int

    @property
    def count(self) -> int:
        return (self.max_x - self.min_x + 1) * (self.max_y - self.min_y + 1)

    def tiles(self) -> Iterator[tuple[int, int, int]]:
        for x in range(self.min_x, self.max_x + 1):
            for y in range(self.min_y, self.max_y + 1):
                yield self.z, x, y


def _clamped_range(
    z: int,
    raw_min_x: int,
    raw_max_x: int,
    raw_min_y: int,
    raw_max_y: int,
    width: int,
    height: int,
) -> TileRange | None:
    min_x = max(0, raw_min_x)
    max_x = min(width - 1, raw_max_x)
    min_y = max(0, raw_min_y)
    max_y = min(height - 1, raw_max_y)
    if min_x > max_x or min_y > max_y:
        return None
    return TileRange(z, min_x, max_x, min_y, max_y)


def _exclusive_upper_index(value: float) -> int:
    nearest = round(value)
    if math.isclose(value, nearest, rel_tol=1e-12, abs_tol=1e-12):
        return nearest - 1
    return math.floor(value)


def web_mercator_tile_range(bounds: Bounds, z: int) -> TileRange | None:
    """Return XYZ tiles intersecting bounds expressed in EPSG:3857."""
    if not 0 <= z <= 22:
        raise ValueError("Web Mercator zoom must be between 0 and 22")

    size = 1 << z
    world = WEB_MERCATOR_LIMIT * 2
    raw_min_x = math.floor((bounds.xmin + WEB_MERCATOR_LIMIT) / world * size)
    raw_max_x = _exclusive_upper_index((bounds.xmax + WEB_MERCATOR_LIMIT) / world * size)
    raw_min_y = math.floor((WEB_MERCATOR_LIMIT - bounds.ymax) / world * size)
    raw_max_y = _exclusive_upper_index((WEB_MERCATOR_LIMIT - bounds.ymin) / world * size)
    return _clamped_range(z, raw_min_x, raw_max_x, raw_min_y, raw_max_y, size, size)


def web_mercator_tile_bounds(z: int, x: int, y: int) -> Bounds:
    size = 1 << z
    if not 0 <= z <= 22 or not (0 <= x < size and 0 <= y < size):
        raise ValueError("Invalid Web Mercator tile coordinate")
    span = WEB_MERCATOR_LIMIT * 2 / size
    return Bounds(
        -WEB_MERCATOR_LIMIT + x * span,
        WEB_MERCATOR_LIMIT - (y + 1) * span,
        -WEB_MERCATOR_LIMIT + (x + 1) * span,
        WEB_MERCATOR_LIMIT - y * span,
    )


def vicgrid_tile_range(bounds: Bounds, z: int) -> TileRange | None:
    """Return native EPSG:7899 tiles intersecting the supplied bounds."""
    if not 0 <= z <= VICGRID_MAX_ZOOM:
        raise ValueError(f"Vicgrid zoom must be between 0 and {VICGRID_MAX_ZOOM}")

    width, height = VICGRID_SIZES[z]
    span = VICGRID_TILE_SIZE * VICGRID_RESOLUTIONS[z]
    left, top = VICGRID_ORIGIN
    raw_min_x = math.floor((bounds.xmin - left) / span)
    raw_max_x = _exclusive_upper_index((bounds.xmax - left) / span)
    raw_min_y = math.floor((top - bounds.ymax) / span)
    raw_max_y = _exclusive_upper_index((top - bounds.ymin) / span)
    return _clamped_range(z, raw_min_x, raw_max_x, raw_min_y, raw_max_y, width, height)


def vicgrid_tile_bounds(z: int, x: int, y: int) -> Bounds:
    if not 0 <= z <= VICGRID_MAX_ZOOM:
        raise ValueError(f"Vicgrid zoom must be between 0 and {VICGRID_MAX_ZOOM}")
    width, height = VICGRID_SIZES[z]
    if not (0 <= x < width and 0 <= y < height):
        raise ValueError("Invalid Vicgrid tile coordinate")
    span = VICGRID_TILE_SIZE * VICGRID_RESOLUTIONS[z]
    left, top = VICGRID_ORIGIN
    return Bounds(
        left + x * span,
        top - (y + 1) * span,
        left + (x + 1) * span,
        top - y * span,
    )
