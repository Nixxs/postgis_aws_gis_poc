"""Verify database driver selection without connecting to PostgreSQL."""

import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sqlalchemy


class DatabaseDriverTests(unittest.TestCase):
    def load_database(self, url):
        config_module = SimpleNamespace(
            config=SimpleNamespace(DATABASE_URL=url, DB_FORCE_ROLL_BACK=False)
        )
        source = Path(__file__).resolve().parents[1] / "app" / "database.py"
        with patch.dict("sys.modules", {"app.config": config_module}):
            # Engine creation imports the real installed driver; suppress only
            # create_all's network access, not dialect selection.
            with patch.object(sqlalchemy.MetaData, "create_all") as create_all:
                state = runpy.run_path(str(source))
        create_all.assert_called_once_with(state["engine"])
        self.addCleanup(state["engine"].dispose)
        return state

    def test_sync_driver_explicit_async_url_unchanged(self):
        url = "postgresql://test:unused@localhost:5432/gis"
        state = self.load_database(url)
        self.assertEqual(state["engine"].dialect.driver, "psycopg2")
        self.assertEqual(state["engine"].dialect.dbapi.__name__, "psycopg2")
        self.assertEqual(str(state["database"].url), url)

    def test_driver_change_preserves_url_components(self):
        url = "postgresql://test:unused%40value@localhost:5432/gis?sslmode=require"
        state = self.load_database(url)
        self.assertEqual(state["engine"].url.password, "unused@value")
        self.assertEqual(state["engine"].url.query["sslmode"], "require")
        self.assertEqual(str(state["database"].url), url)


if __name__ == "__main__":
    unittest.main()