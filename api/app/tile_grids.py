"""Vicmap WMTS EPSG:7899 grid snapshot, verified 2026-09-07.

Source: https://base.maps.vic.gov.au/service?SERVICE=WMTS&REQUEST=GetCapabilities&VERSION=1.0.0
No external service request is needed at API startup or for tile generation.
WMTS scale denominators use the OGC standard 0.28 mm pixel; CRS units are metres.
These resolutions are NOT a standard power-of-two XYZ pyramid.
"""

VICGRID_SRID = 7899
VICGRID_ORIGIN = (1786000.0, 3081000.0)  # easting, northing; top-left
VICGRID_TILE_SIZE = 512
VICGRID_SCALES = (
    7559538.928601667,
    3779769.4643008336,
    1889884.7321504168,
    944942.3660752084,
    472471.1830376042,
    236235.5915188021,
    94494.2366075208,
    47247.1183037604,
    23623.5591518802,
    9449.4236607521,
    4724.711830376,
    2362.355915188,
    1181.177957594,
    755.9538928602,
)
VICGRID_SIZES = (
    (2, 1), (4, 2), (8, 4), (16, 8), (32, 16), (64, 32),
    (160, 80), (320, 160), (640, 320), (1600, 800),
    (3200, 1600), (6400, 3200), (12800, 6400), (20000, 10000),
)
VICGRID_RESOLUTIONS = tuple(scale * 0.00028 for scale in VICGRID_SCALES)
VICGRID_MAX_ZOOM = len(VICGRID_SCALES) - 1


def vicgrid_tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """Return xmin, ymin, xmax, ymax in EPSG:7899. Rows increase southward."""
    if not 0 <= z <= VICGRID_MAX_ZOOM:
        raise ValueError(f"Vicgrid z must be between 0 and {VICGRID_MAX_ZOOM}")
    width, height = VICGRID_SIZES[z]
    if not (0 <= x < width and 0 <= y < height):
        raise ValueError(f"Vicgrid zoom {z}: x must be 0..{width - 1}, y must be 0..{height - 1}")
    span = VICGRID_TILE_SIZE * VICGRID_RESOLUTIONS[z]
    left, top = VICGRID_ORIGIN
    return left + x * span, top - (y + 1) * span, left + (x + 1) * span, top - y * span


def vicgrid_metadata() -> dict:
    """OpenLayers-ready grid values; matrixIds map API z to WMTS identifiers."""
    return {
        "id": "vicgrid",
        "crs": "EPSG:7899",
        "name": "GDA2020 / Vicgrid",
        "units": "metres",
        "axisOrder": "east,north",
        "tileMatrixSet": "EPSG:7899",
        "origin": VICGRID_ORIGIN,
        "tileSize": VICGRID_TILE_SIZE,
        "resolutions": VICGRID_RESOLUTIONS,
        "matrixIds": [f"{z:02d}" for z in range(len(VICGRID_SCALES))],
        "sizes": VICGRID_SIZES,
        "minZoom": 0,
        "maxZoom": VICGRID_MAX_ZOOM,
        "rowDirection": "down",
        "wrapX": False,
        "tileUrlTemplate": "/tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt",
        "wmtsCapabilitiesUrl": "https://base.maps.vic.gov.au/service?SERVICE=WMTS&REQUEST=GetCapabilities&VERSION=1.0.0",
    }