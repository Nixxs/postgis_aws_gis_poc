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

## OpenLayers frontend (independent sibling)

The React/OpenLayers application is separate from the original React/MapLibre
application. Both use the shared API; neither frontend replaces the other.

| | Original MapLibre | Native OpenLayers |
| --- | --- | --- |
| Development URL | http://localhost:5173 | http://localhost:5174 (strict port) |
| Package | [frontend/package.json](frontend/package.json) | [frontend-ol/package.json](frontend-ol/package.json) |
| Independent layer/basemap configuration | [frontend/public/config.json](frontend/public/config.json) | [frontend-ol/public/config.json](frontend-ol/public/config.json) |
| Deployment script | [infra/deploy-frontend.ps1](infra/deploy-frontend.ps1) | [infra/deploy-frontend-ol.ps1](infra/deploy-frontend-ol.ps1) |
| Map/tile projection | EPSG:3857 | EPSG:7899 (GDA2020 / Vicgrid) |

The OpenLayers sibling retains the same layer controls, attribute queries,
spatial queries, buffer intersections, result tables, feature information,
location controls and two-point measurement workflow. Mock login is
**demo / demo**. It only gates UI visibility, including restricted basemaps and
parcels; it is **not security**, and the shared API does not enforce that login.

### Local development and configuration

Use Node.js 22 LTS or newer and npm 9+. Unit tests use native `node:test` and its
mocking APIs; the separate browser suite uses Playwright. This sibling uses
patched Vite 6.4.3 build tools without upgrading the original frontend. Start the
local API on port **8001** as described above, with the native grid and vector
tile endpoints available. Install this sibling's own locked dependencies:

```powershell
# From the repository root
cd frontend-ol
npm ci
```

Set [frontend-ol/.env.development](frontend-ol/.env.development) for local API
development (the available keys are also listed in
[frontend-ol/.env.example](frontend-ol/.env.example)):

```dotenv
VITE_QUERY_API_URL=/api
VITE_TILE_API_URL=/api
VITE_CONFIG_URL=/config.json
VITE_DEV_API_URL=http://127.0.0.1:8001
```

`VITE_QUERY_API_URL` is the base for query/schema requests;
`VITE_TILE_API_URL` is the base for native MVT and relative grid-metadata URLs.
`VITE_CONFIG_URL` selects this application's configuration, defaulting to its
own `/config.json`. `VITE_DEV_API_URL` is the development proxy target only:
Vite strips `/api` before forwarding to the backend. To test a deployed API
through the local proxy, change only that target to its HTTPS API base URL.
Restart Vite after environment changes. Do not place credentials in `VITE_*`
values; they are public frontend settings.

```powershell
# From frontend-ol
npm run dev
```

Open http://localhost:5174; the original frontend can remain on port 5173.
For a standalone production build, supply real API bases through
`VITE_QUERY_API_URL` and `VITE_TILE_API_URL`, not the development-only `/api`
proxy. The deployment script below supplies both automatically.

```powershell
# From frontend-ol, with the intended production API environment configured
npm run build
npm test
# Run just the projection/grid/API-contract suite:
node --test tests/projections.test.mjs
```

The native Node tests bundle the real TypeScript/OpenLayers code with esbuild
using `write: false` and import a data URL; no generated test modules, live
database or WMTS connection are required.
[frontend-ol/tests/projections.test.mjs](frontend-ol/tests/projections.test.mjs)
covers the PostGIS coordinate fixture (1 mm tolerance), WGS84 point/polygon and
query-result round trips, the original 1109.9241542897053 m measurement scenario
(1 cm tolerance), invalid/zero/symmetric measurements, all 14 matrix levels,
tile bounds and URL conventions, parcel zoom translation and mocked query/API
contracts. A throwing `fetch` stub verifies local measurement does not access
the network. [frontend-ol/tests/drawing.test.mjs](frontend-ol/tests/drawing.test.mjs)
additionally exercises real OL drawing interactions, completion/cancellation,
mode switching, navigation suppression and cleanup.

For live Chromium integration checks, keep the API running with the planning
layer loaded and ensure the Vicmap WMTS service is reachable:

```powershell
# From frontend-ol; install the test browser once
npx playwright install chromium
npm run test:browser
```

The browser suite starts or reuses the frontend on http://127.0.0.1:5174 and
checks native raster/vector requests, two-click measurement with no `/measure`
traffic, WGS84 drawing and spatial-query submission, result-table selection,
login-gated parcel zoom visibility and sidebar resizing. Screenshots and failure
traces are generated under the ignored test-results directory. The unit suite
contains 23 tests and the browser suite contains 6 integration tests.

### Native map, query boundary and measurement accuracy

- The **view, drawn sketches, raster WMTS and native MVT sources use EPSG:7899**.
  Startup fetches `GET /tiles/grids/vicgrid`; the backend supplies all matrix
  metadata, including origin, tile size, resolutions, sizes and matrix IDs.
  Both raster and vector grids use those values, with wrapping disabled.
  This is the non-power-of-two Vicmap snapshot described in the endpoint
  reference above, not a hard-coded Web Mercator pyramid in the map component.
- Native raster basemaps use Vicmap WMTS `CARTO_VG2020` and `AERIAL_VG2020`
  with matrix set `EPSG:7899` (`CARTO_OVERLAY_VG2020` is also available).
  Raster requests use matrix identifiers `00`–`13`; vectors use integer `z`
  in `/tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt`. The map does not reproject the
  original EPSG:3857 tile endpoint. A missing/invalid metadata response is
  shown as an error with Retry: deploy the native backend endpoints first.
- There is **no reprojected OSM fallback**. Disabling all native basemaps leaves
  a blank background behind enabled vectors, sketches and query results.
- `/query` and `/spatial-query` retain their **EPSG:4326 GeoJSON boundary**:
  native drawn points/polygons are transformed to `[longitude, latitude]`
  before submission; returned features and `queryGeometry` are transformed
  back into EPSG:7899 for display. No query API contract changes are required.
- OpenLayers measurement is **client-side planar distance in EPSG:7855**
  (GDA2020 / MGA zone 55), transforming the two fixed native EPSG:7899
  endpoints locally. It makes **no `/measure` calls**, including Retry, and
  reports metres, not geodesic, terrain or route distance. The existing server
  `/measure` endpoint remains available to the original frontend. Zone 55 is
  not automatically changed to zone 54 for western Victoria.
- WGS84 conversions use a **null datum transformation**, not a survey-grade
  or coordinate-epoch-aware WGS84/GDA2020 transformation. The numeric tests
  establish agreement with recorded fixtures, not survey/epoch accuracy.

Native matrix indices **0–13 are unrelated to legacy MapLibre zoom numbers**.
Copied `minZoom`/`maxZoom` settings keep the original **512-pixel** MapLibre
scale by translating approximate ground resolution at the current latitude:

$$
r = \frac{78271.51696402048\cos(\varphi)}{2^{z_{\mathrm{legacy}}}}
\quad\text{metres/pixel}
$$

Here $\varphi$ is latitude in radians. This is an approximate visibility/fit
translation, not an exact projection-scale correction. For example, parcel
`minZoom: 14` becomes a view resolution between native levels **8 and 9** near
Melbourne, not an attempt to request native matrix 14. The lower zoom bound
is inclusive and the upper bound exclusive.

### Separate AWS deployment (instructions only)

**No OpenLayers AWS deployment has been executed as part of this change, and
no new OpenLayers CloudFront URL has been issued or verified.** The existing
MapLibre deployment and endpoint documentation above remain applicable.

Prerequisites: deploy the shared backend's `/tiles/grids/vicgrid` and
`/tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt` routes first; verify them on the intended
API, not just in local source. Install the sibling dependencies with `npm ci`
before deployment. [infra/deploy-frontend-ol.ps1](infra/deploy-frontend-ol.ps1)
**does not install dependencies** or invoke the original frontend deployer.

Use [infra/.env.example](infra/.env.example) as the settings reference and
choose a private deployment configuration through the script's `-ConfigFile`
parameter (default: the infra dotenv configuration). Preserve existing API,
database and original frontend settings. The OL deployer reads these settings
from that file, **not inherited `FRONTEND_OL_*` shell variables**:

| Setting | Purpose / default |
| --- | --- |
| `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCOUNT_ID` | Required AWS settings; account identity is checked before build/resource changes |
| `FRONTEND_OL_API_URL` | Required shared production **HTTPS API base URL** for a normal build; supply the actual API URL, not either frontend URL; no credentials, query or fragment |
| `FRONTEND_OL_BUCKET` | Separate private S3 bucket; blank defaults to `gis-postgis-frontend-ol-<verified AWS account ID>` |
| `FRONTEND_OL_CLOUDFRONT_COMMENT` | Separate distribution lookup comment; default `gis-postgis-frontend-ol` |
| `FRONTEND_OL_OAC_NAME` | Separate Origin Access Control; default `gis-postgis-frontend-ol-oac` |
| `FRONTEND_OL_URL` | Leave blank until the new distribution origin is known; then use it to extend API CORS |

Bucket, distribution comment and OAC must differ from the original frontend's
configured and default resources; the script checks for resource sharing.
During build it sets both `VITE_QUERY_API_URL` and `VITE_TILE_API_URL` from
`FRONTEND_OL_API_URL`, and `VITE_CONFIG_URL=/config.json` for the sibling's own
configuration. It restores the prior build environment afterwards. Uploads
and invalidation target the separate OL distribution. `-SkipBuild` reuses
existing output; it does not verify the API URLs embedded in that output.

```powershell
# From the repository root, only when ready to deploy to AWS
.\infra\deploy-frontend-ol.ps1
# Alternatively, pass your private settings file using -ConfigFile.
```

After a successful deployment, set `FRONTEND_OL_URL` in the same configuration
to the printed `https://<distribution>.cloudfront.net` origin (no path).
**Keep `FRONTEND_URL` unchanged** for MapLibre, then redeploy the shared API
with [infra/deploy-api.ps1](infra/deploy-api.ps1) using the same `-ConfigFile`:
it adds the OL origin alongside the existing origin in CORS. Leaving
`FRONTEND_OL_URL` blank preserves single-frontend access. CORS is not
authentication. Allow time for CloudFront deployment and cache invalidation.


### URLS
Open Layers Frontend: https://d2fwf1q6xmjgmr.cloudfront.net/
Maplibre Frontend: https://d3m770p4wtb32m.cloudfront.net/
Backend API URL: https://r554gl2g2j.execute-api.ap-southeast-2.amazonaws.com/health