-- Run once against the DTP `gis` database before importing layers.
CREATE EXTENSION IF NOT EXISTS postgis;

SELECT PostGIS_Full_Version();
