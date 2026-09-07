# postgis_aws_gis_poc
A template project for setting up an AWS hosted map application using open source technologies.

## API

### Prerequisites

- Python 3.12 (official [python.org](https://www.python.org/downloads/) build recommended). On Windows, verify the launcher can find it:

  ```powershell
  py -0p
  ```

  > Avoid MSYS2/MinGW Python — its interpreter is incompatible with PyPI's prebuilt wheels (e.g. `psycopg2-binary`) and will try to compile from source.

### Setup

All commands are run from the `api/` directory.

1. Create and activate a virtual environment:

   ```powershell
   cd api
   py -3.12 -m venv .venv
   .\.venv\Scripts\Activate.ps1
   ```

   On macOS/Linux:

   ```bash
   cd api
   python3.12 -m venv .venv
   source .venv/bin/activate
   ```

2. Install the dependencies:

   ```powershell
   python -m pip install --upgrade pip
   pip install -r requirements.txt
   ```

### run the database in docker

```
docker compose --env-file ../.env up -d
```

### Run the API

With the virtual environment activated, start the development server:

```powershell
uvicorn app.main:app --reload --host 0.0.0.0 --port 8001
```

The API will be available at http://127.0.0.1:8001 and the interactive docs at http://127.0.0.1:8001/docs.

### Endpoint reference

This reference describes the current source code, including the native Vicgrid
routes. A deployed instance only supports changes included in its last API
deployment; check its `/docs` or `/openapi.json` to confirm.

- Local API base URL: `http://127.0.0.1:8001`.
- Production API base URL: `https://r554gl2g2j.execute-api.ap-southeast-2.amazonaws.com`.
- POST request bodies are JSON; send `Content-Type: application/json`.
- `/api` is the frontend development proxy prefix, not part of the backend
  routes below. For example, the browser's `/api/measure` becomes `/measure`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | Service identity and documentation link |
| GET | `/health` | Process health check, without checking the database |
| GET | `/ready` | Database readiness check |
| GET | `/list-layers` | List spatial tables in the public schema |
| GET | `/describe-layer/{table_name}` | Attribute columns and feature count |
| POST | `/unique-values` | Attribute value suggestions for query builders |
| POST | `/query` | Attribute/spatial filtering, paging and count queries |
| POST | `/spatial-query` | Intersections with a drawn geometry and optional metre buffer |
| POST | `/measure` | Projected distance between two WGS84 positions |
| GET | `/tiles/{layer}/{z}/{x}/{y}.mvt` | Web Mercator vector tiles for MapLibre |
| GET | `/tiles/grids/vicgrid` | Native Vicgrid grid definition for OpenLayers |
| GET | `/tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt` | Native GDA2020 / Vicgrid vector tiles |
| GET | `/tile-demo` | Standalone MapLibre demonstration HTML (not listed in OpenAPI) |
| GET | `/docs` | FastAPI Swagger UI |
| GET | `/redoc` | FastAPI ReDoc documentation |
| GET | `/openapi.json` | Generated OpenAPI schema |
| GET | `/docs/oauth2-redirect` | Framework-provided Swagger OAuth redirect page; not a login API |

#### Health endpoints

- `/` returns `{"service":"postgis-api","status":"ok","docs":"/docs"}`.
- `/health` returns `{"status":"ok"}` with HTTP 200.
- `/ready` executes `SELECT 1` and returns `{"status":"ready"}` with HTTP 200,
  or HTTP 503 with `{"detail":"Database unavailable"}`.

#### Layer discovery and description

`GET /list-layers` takes no parameters and returns
`{"layers":["au_vic_dtp_planning_scheme_all", "..."]}`. It lists tables
registered in PostGIS `geometry_columns` in the `public` schema.

`GET /describe-layer/{table_name}?schema=public` accepts an optional `schema`
query parameter. It returns:

```json
{
  "layer": "example_layer",
  "feature_count": 42,
  "columns": [
    {"name": "id", "type": "integer", "nullable": false, "is_geometry": false},
    {"name": "geom", "type": "USER-DEFINED", "nullable": true, "is_geometry": true}
  ]
}
```

This is an illustrative response; actual names, types and counts come from the
database. Unknown spatial layers return HTTP 404.

#### Unique attribute values

`POST /unique-values` accepts:

| Body field | Required | Default / behavior |
| --- | --- | --- |
| `table` | Yes | Spatial table name (note: this endpoint uses `table`, not `layer`) |
| `field` | Yes | Attribute column; geometry columns are rejected |
| `schema` | No | `public` |
| `search` | No | No filter; nonblank text is used in a case-insensitive substring `LIKE` filter |
| `limit` | No | 50; clamped to 1–200 |

```json
{
  "table": "au_vic_dtp_planning_scheme_all",
  "field": "zone_code",
  "search": "DDO",
  "limit": 50
}
```

Returns `{"layer":"...","field":"zone_code","values":["DDO2"],"truncated":false}`.
Values are distinct, non-null and ordered by the column value. `truncated`
means the returned count reached the requested limit; it does not prove that
more values exist. Unknown layers return 404; invalid/geometry fields return 422.

#### Attribute and spatial queries

`POST /query` accepts:

| Body field | Required | Default / behavior |
| --- | --- | --- |
| `layer` | Yes | Spatial table name |
| `schema` | No | `public` |
| `where` | No | No attribute filter; `1=1` also means no filter |
| `outFields` | No | All non-geometry attributes; `*` or a comma-separated column list |
| `orderByFields` | No | No explicit ordering; e.g. `Shape_Area DESC, lga ASC` |
| `resultOffset` | No | 0; negative values are clamped to 0 |
| `resultRecordCount` | No | 200; clamped to 1–1000 |
| `returnCountOnly` | No | `false`; when true, return the total matching count without paging |
| `returnGeometry` | No | `false`; when true, force a GeoJSON response |
| `f` | No | `json`; accepts `json` or `geojson` |
| `geometry` | No | Bare GeoJSON geometry in WGS84 (EPSG:4326), `[longitude, latitude]` |
| `spatialRel` | No | `esriSpatialRelIntersects`; used when `geometry` is supplied |

Supported spatial relationships: `esriSpatialRelIntersects`,
`esriSpatialRelContains`, `esriSpatialRelWithin`, `esriSpatialRelCrosses`,
`esriSpatialRelOverlaps`, and `esriSpatialRelTouches`. Predicates are evaluated
as **layer geometry, input geometry**; for example, `Contains` means the layer
feature contains the supplied geometry. Input geometry is transformed to the
layer's SRID before filtering.

```json
{
  "layer": "au_vic_dtp_planning_scheme_all",
  "where": "\"zone_code\" = 'DDO2'",
  "outFields": "OBJECTID,zone_code",
  "orderByFields": "OBJECTID ASC",
  "resultOffset": 0,
  "resultRecordCount": 100,
  "f": "geojson"
}
```

Response modes:

- Default `json`: `{layer, count, resultOffset, resultRecordCount, fields, features}`;
  `features` is an array of attribute objects, without GeoJSON wrappers.
- `geojson` (or `returnGeometry: true`): a GeoJSON `FeatureCollection` with
  `features`, plus `layer`, `count`, `resultOffset` and `resultRecordCount`.
  Feature geometry is emitted in EPSG:4326 and attributes are in `properties`.
- `returnCountOnly: true`: `{"layer":"...","count":42}`.

Except for count-only requests, `count` is the number returned in the current
page, not the total matching count. Use an explicit stable `orderByFields` when
paging. `resultRecordCount` in the response is the applied page limit.

The `where` clause is SQL-like, with semicolons, comments and selected unsafe
SQL functions blocked. This is POC validation, **not a full SQL sandbox**.
Field names are checked against the layer schema. Invalid format, fields,
ordering or disallowed syntax return 422; user-caused SQL errors caught by the
query handler return 400; unknown layers return 404.

#### Drawn geometry and buffer intersections

`POST /spatial-query` accepts `layer` and a bare GeoJSON `geometry` (required),
plus `schema` (default `public`) and `buffer` (default 0 metres).

```json
{
  "layer": "au_vic_dtp_parcel",
  "geometry": {"type": "Point", "coordinates": [144.9631, -37.8136]},
  "buffer": 100
}
```

- Coordinates must be WGS84 (EPSG:4326). Send the geometry itself, not a
  GeoJSON Feature, FeatureCollection or string containing JSON.
- Buffer distances are clamped to 0–50,000 metres. Positive buffers use
  PostGIS `geography`, rather than approximating metres with degrees.
- The route intersects the layer with the resulting geometry and returns up
  to **1000 features**, including all attributes, as a GeoJSON FeatureCollection.
- Response extras are `layer`, `count`, `resultOffset` (0),
  `resultRecordCount` (1000), `bufferMeters` (applied buffer), and
  `queryGeometry` (the searched geometry in EPSG:4326, buffered if requested).
- This route currently does **not** expose `outFields`, pagination, `where`,
  or a selectable spatial relationship. Use `/query` for those options.

Unknown layers return 404; request-model validation errors return 422. Not all
malformed GeoJSON/PostGIS errors are currently translated into client errors;
some may surface as 500 responses.

#### Two-point distance measurement

`POST /measure` accepts exactly two coordinate pairs:

```json
{
  "start": [144.9631, -37.8136],
  "end": [144.9631, -37.8036]
}
```

Both positions are WGS84 `[longitude, latitude]` in degrees. Each pair must
have exactly two finite numbers, with longitude in −180…180 and latitude in
−90…90; missing or invalid positions return HTTP 422.

The server transforms both points to **GDA2020 / MGA zone 55 (EPSG:7855)** and
returns a projected 2D grid distance:

```json
{
  "distance": 1109.9241542897053,
  "units": "metres",
  "sourceCrs": "EPSG:4326",
  "measurementCrs": "EPSG:7855"
}
```

The example value is from a local test; transformation details may vary with
the installed PostGIS/PROJ environment. Zone 55 covers 144–150° E, including
Melbourne. Western Victoria is in zone 54; the endpoint does not automatically
select a zone. This is not a geodesic, road-route or terrain distance.

#### Coordinate systems and error responses

| Operation | Input / grid | Output |
| --- | --- | --- |
| `/query`, `/spatial-query` | EPSG:4326 GeoJSON when supplying geometry | EPSG:4326 geometry when returning GeoJSON |
| `/measure` | EPSG:4326 coordinate pairs | Distance in metres calculated in EPSG:7855 |
| Web Mercator tiles | Standard EPSG:3857 XYZ grid | MVT tile-local coordinates |
| Native Vicgrid tiles | Vicmap EPSG:7899 grid | MVT tile-local coordinates |

Handled API errors generally return `{"detail":"message"}`. FastAPI request
validation errors use a `detail` array describing invalid fields. Database or
other unhandled failures can return 500. Successful application routes return
200, including queries with no matches and empty vector tiles.

The backend currently has no authentication/authorization enforcement on these
routes. Frontend login-gated layers are a UI feature, not API access control.
CORS allows the configured `FRONTEND_URL`; CORS is not authentication.

### Vector tiles

Spatial layers are available as Mapbox Vector Tiles for MapLibre:

```text
GET /tiles/{layer}/{z}/{x}/{y}.mvt?schema=public&fields=id,name
```

The `fields` query parameter is optional and defaults to all non-geometry
columns. The MapLibre source's `source-layer` must match `{layer}`:

```javascript
map.addSource("my-layer", {
  type: "vector",
  tiles: ["http://127.0.0.1:8001/tiles/my_table/{z}/{x}/{y}.mvt"],
  minzoom: 0,
  maxzoom: 22,
});
```

`z` must be 0–22; `x` and `y` must be in `0..(2 ** z - 1)` (XYZ rows from
the top). `schema` defaults to `public`. Tiles have content type
`application/vnd.mapbox-vector-tile`, extent 4096 and buffer 64 tile-local
units. HTTP 200 with an empty body represents no features. Cache-Control is
`public, max-age=300`. Unknown layers return 404; unknown SRIDs, invalid
coordinates and unknown requested fields return 422.

### Native GDA2020 / Vicgrid tiles (OpenLayers)

The existing `/tiles/{layer}/{z}/{x}/{y}.mvt` endpoint remains Web Mercator
(EPSG:3857), with its existing zoom levels and MapLibre behavior unchanged.
For a map in **GDA2020 / Vicgrid (EPSG:7899)**, use:

```text
GET /tiles/grids/vicgrid
GET /tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt?schema=public&fields=id,name
```

The native endpoint transforms the source table geometry directly from its
registered PostGIS SRID to EPSG:7899 before clipping and MVT encoding. It does
not generate a Web Mercator tile and then reproject it. `fields` and `schema`
work as on the existing endpoint; the internal MVT layer name is `{layer}`.
Empty tiles return HTTP 200 with an empty body. Invalid coordinates or fields
return 422; unknown spatial tables return 404. Tiles retain the five-minute
public cache header. There is no new server-side tile cache or pre-generation.

**The native grid matches Vicmap WMTS, not the standard XYZ pyramid.** The
matrix snapshot in [api/app/tile_grids.py](api/app/tile_grids.py) was verified
against the live WMTS capabilities on 2026-09-07. Requests do not depend on
Vicmap's service availability. Key properties:

- Top-left origin: `[1786000, 3081000]` in easting/northing metres.
- Tile size: 512 pixels. MVT coordinate extent: 4096; buffer: 64 MVT units.
- API `z`: index 0–13; corresponding WMTS matrix IDs: `00`–`13`.
- `x` is the column; `y` is the row increasing southward from the top.
- Resolutions use the advertised scale denominators × 0.00028 metres/pixel.
- Matrix sizes and zoom steps are not all powers of two. For example, zoom 6
  is 160 columns × 80 rows. Use the returned `resolutions`, `sizes` and
  `matrixIds`, not `2 ** z` or Web Mercator zoom numbers.
- Disable horizontal wrapping (`wrapX: false`).

The grid metadata supplies `crs`, `origin`, `tileSize`, `resolutions`, `sizes`,
`matrixIds`, and `tileUrlTemplate`. The OpenLayers frontend should register
EPSG:7899, create its vector tile grid from those values, and set both its view
and vector tile source projection explicitly. MVT coordinates are tile-local;
the binary tile **does not contain an EPSG identifier**. This metadata endpoint
is a grid description, not a WMTS capabilities or TileJSON document.

Native basemaps available from the Vicmap WMTS service are `CARTO_VG2020`,
`AERIAL_VG2020` and `CARTO_OVERLAY_VG2020`, using matrix set `EPSG:7899`.
The raster WMTS layer can be configured from the service capabilities and the
same resolutions/origin. Existing `*_WM_256` layers use EPSG:3857 instead.

Query/spatial-query inputs and GeoJSON results remain WGS84 (EPSG:4326).
OpenLayers must transform drawn geometry to WGS84 before sending those calls
and transform results into the map view. Measurement still uses GDA2020 / MGA
zone 55 (EPSG:7855), which is distinct from the statewide Vicgrid projection.

#### Backend grid tests

Run from `api/` with the configured Python environment. Unit tests require no
database; the opt-in integration tests use the API's database settings and
create only a temporary table inside a rolled-back transaction. Use local
development database settings for these tests.

```powershell
python -m unittest discover -s tests -p test_tile_grids.py -v
$env:RUN_POSTGIS_TILE_TESTS = '1'
try {
    python -m unittest discover -s tests -p test_vicgrid_postgis.py -v
} finally {
    Remove-Item Env:RUN_POSTGIS_TILE_TESTS
}
```

Integration tests compare MVT bytes against independent PostGIS fixtures for
known tile-local coordinates, test buffer inclusion and empty tiles, and verify
that the Web Mercator endpoint still matches its original SQL output.

### connecting to the deployed aws database:

```powershell
docker run --rm -it `
  --mount "type=bind,source=$($PWD.Path)\global-bundle.pem,target=/global-bundle.pem,readonly" `
  postgres:16 `
  psql "host=dtp-aws-poc.c582u0iemihr.ap-southeast-2.rds.amazonaws.com port=5432 dbname=gis user=postgres sslmode=verify-full sslrootcert=/global-bundle.pem"
```