FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /opt/tilecache

COPY requirements.txt .
RUN pip install --requirement requirements.txt

COPY app ./app

USER 65534:65534
ENTRYPOINT ["python", "-m", "app.main"]
