import argparse
import gzip
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import psycopg2

from app.main import (
    _prefix,
    _version,
    build_ranges,
    process_tile,
    selected_columns,
    upload_json,
    validate_args,
)
from app.tiling import Bounds


class ValidationTests(unittest.TestCase):
    def make_args(self, **overrides):
        values = {
            "schema": "public",
            "layer": "planning_zones",
            "grid": "webmercator",
            "min_zoom": 0,
            "max_zoom": 12,
            "workers": 4,
            "max_tiles": 100,
            "prefix": "tiles",
            "version": "20260908T010203Z",
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_normalizes_prefix(self):
        args = self.make_args(prefix="/cache/tiles/")
        validate_args(args)
        self.assertEqual(args.prefix, "cache/tiles")

    def test_rejects_unsafe_identifier(self):
        with self.assertRaisesRegex(ValueError, "simple PostgreSQL identifier"):
            validate_args(self.make_args(layer="zones; DROP TABLE zones"))

    def test_rejects_invalid_zoom_range(self):
        with self.assertRaisesRegex(ValueError, "zoom range"):
            validate_args(self.make_args(grid="vicgrid", max_zoom=14))

    def test_prefix_and_version_validation(self):
        with self.assertRaises(ValueError):
            _prefix("tiles/../private")
        with self.assertRaises(ValueError):
            _version("contains/slash")


class MetadataTests(unittest.TestCase):
    def test_selects_fields_in_requested_order_without_duplicates(self):
        columns = (("id", "int4"), ("name", "varchar"), ("created", "date"))
        self.assertEqual(
            selected_columns(columns, "name,id,name"),
            (("name", "varchar"), ("id", "int4")),
        )

    def test_rejects_unknown_fields(self):
        with self.assertRaisesRegex(ValueError, "Unknown tile fields: missing"):
            selected_columns((("id", "int4"),), "id,missing")

    def test_ranges_are_limited_to_layer_extent(self):
        ranges = build_ranges(Bounds(-1, -1, 1, 1), "webmercator", 0, 2)
        self.assertEqual([item.count for item in ranges], [1, 4, 4])


class UploadTests(unittest.TestCase):
    def test_json_metadata_uses_server_side_encryption(self):
        s3 = Mock()
        upload_json(s3, "bucket", "path/manifest.json", {"ok": True}, "no-cache")
        kwargs = s3.put_object.call_args.kwargs
        self.assertEqual(kwargs["ContentType"], "application/json")
        self.assertEqual(kwargs["ServerSideEncryption"], "AES256")
        self.assertEqual(kwargs["CacheControl"], "no-cache")

    @patch("app.main.render_tile", return_value=b"")
    def test_empty_tile_is_uploaded(self, _render_tile):
        connection = Mock()
        connection.autocommit = True
        pool = Mock()
        pool.getconn.return_value = connection
        s3 = Mock()
        args = SimpleNamespace(
            bucket="bucket",
            schema="public",
            layer="planning_zones",
            grid="webmercator",
        )

        result = process_tile(pool, s3, Mock(), args, (), "tiles/version", (3, 4, 5))

        kwargs = s3.put_object.call_args.kwargs
        self.assertEqual(kwargs["Key"], "tiles/version/3/4/5.mvt")
        self.assertEqual(gzip.decompress(kwargs["Body"]), b"")
        self.assertEqual(kwargs["ContentEncoding"], "gzip")
        self.assertTrue(result.empty)

    @patch("app.main.time.sleep")
    @patch("app.main.render_tile", side_effect=(psycopg2.OperationalError("SSL EOF"), b"tile"))
    def test_transient_database_disconnect_retries_with_new_connection(self, render, sleep):
        failed_connection = Mock()
        failed_connection.autocommit = True
        replacement_connection = Mock()
        replacement_connection.autocommit = False
        pool = Mock()
        pool.getconn.side_effect = (failed_connection, replacement_connection)
        s3 = Mock()
        args = SimpleNamespace(
            bucket="bucket",
            schema="public",
            layer="planning_zones",
            grid="webmercator",
        )

        result = process_tile(pool, s3, Mock(), args, (), "tiles/version", (3, 4, 5))

        self.assertEqual(render.call_count, 2)
        pool.putconn.assert_any_call(failed_connection, close=True)
        pool.putconn.assert_any_call(replacement_connection)
        replacement_connection.set_session.assert_called_once_with(readonly=True, autocommit=True)
        sleep.assert_called_once_with(1)
        self.assertFalse(result.empty)
        self.assertEqual(gzip.decompress(s3.put_object.call_args.kwargs["Body"]), b"tile")


if __name__ == "__main__":
    unittest.main()
