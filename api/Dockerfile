# FastAPI + PostGIS query API. Runs under gunicorn with uvicorn workers.
# Build for linux/amd64 to match Fargate (see infra/deploy.ps1):
#   docker build --platform linux/amd64 --provenance=false -t gis-postgis-api .
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install deps first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code.
COPY app/ ./app/

EXPOSE 8000

# Config comes entirely from environment variables (see app/config.py); there is
# no .env file baked into the image. DB_HOST=localhost because the postgis
# container shares this task's network namespace (awsvpc).
CMD ["gunicorn", "app.main:app", \
     "-k", "uvicorn.workers.UvicornWorker", \
     "-b", "0.0.0.0:8000", \
     "-w", "2", \
     "--timeout", "60", \
     "--access-logfile", "-"]
