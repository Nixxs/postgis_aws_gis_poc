import logging
from contextlib import asynccontextmanager
from pathlib import Path

from asgi_correlation_id import CorrelationIdMiddleware
from fastapi import FastAPI, HTTPException
from fastapi.exception_handlers import http_exception_handler
from fastapi.middleware.cors import CORSMiddleware  # Import CORS middleware
from fastapi.responses import FileResponse

from app.database import database
from app.routers.list_layers import router as list_layers
from app.routers.describe_layer import router as describe_layer
from app.routers.unique_values import router as unique_values
from app.routers.query import router as query
from app.routers.tiles import router as tiles
from app.routers.measure import router as measure_router
from app.config import config
from app.logging_conf import configure_logging

logger = logging.getLogger(__name__)


# CORS settings
origins = [
    config.FRONTEND_URL,  # Add production frontend domain at some point
]

@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_logging()
    logger.info("Starting api")
    await database.connect()
    yield
    await database.disconnect()

app = FastAPI(lifespan=lifespan)

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,  # Allow specific frontend origins
    allow_credentials=True,
    allow_methods=["*"],  # Allow all HTTP methods (GET, POST, PUT, DELETE, etc.)
    allow_headers=["*"],  # Allow all headers
)

app.add_middleware(CorrelationIdMiddleware)


@app.get("/", tags=["health"])
async def root():
    return {"service": "postgis-api", "status": "ok", "docs": "/docs"}


@app.get("/health", tags=["health"])
async def health():
    """Process health check used by the load balancer."""
    return {"status": "ok"}


@app.get("/ready", tags=["health"])
async def ready():
    """Readiness check that verifies the database connection."""
    try:
        await database.fetch_val("SELECT 1")
    except Exception as exc:
        logger.exception("Database readiness check failed")
        raise HTTPException(status_code=503, detail="Database unavailable") from exc
    return {"status": "ready"}


@app.get("/tile-demo", include_in_schema=False, response_class=FileResponse)
async def tile_demo():
    """Serve a minimal same-origin MapLibre demonstration page."""
    return FileResponse(Path(__file__).parent / "static" / "mvt-demo.html")

# Include routers
app.include_router(list_layers)
app.include_router(describe_layer)
app.include_router(unique_values)
app.include_router(query)
app.include_router(tiles)
app.include_router(measure_router)

@app.exception_handler(HTTPException)
async def http_exception_handler_logging(request, exc):
    logger.error(f"HTTPException: {exc.status_code} - {exc.detail}")
    return await http_exception_handler(request, exc)