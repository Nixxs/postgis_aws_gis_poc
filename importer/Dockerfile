FROM ghcr.io/osgeo/gdal:ubuntu-small-3.13.3

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY import.sh /usr/local/bin/import-data
RUN chmod 0755 /usr/local/bin/import-data

ENTRYPOINT ["/usr/local/bin/import-data"]
