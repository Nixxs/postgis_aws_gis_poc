"""HTTP integration tests against a running API backed by PostGIS.

Run with unittest discovery; set MEASURE_TEST_API_URL to override localhost.
"""

import json
import os
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class MeasureTests(unittest.TestCase):
    base_url = os.environ.get("MEASURE_TEST_API_URL", "http://127.0.0.1:8001").rstrip("/")

    def post(self, payload):
        request = Request(
            f"{self.base_url}/measure",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=30) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def test_same_position_is_zero(self):
        status, body = self.post({"start": [144.9631, -37.8136], "end": [144.9631, -37.8136]})
        self.assertEqual(status, 200)
        self.assertEqual(body["distance"], 0)
        self.assertEqual(body["units"], "metres")
        self.assertEqual(body["sourceCrs"], "EPSG:4326")
        self.assertEqual(body["measurementCrs"], "EPSG:7855")

    def test_melbourne_distance_and_symmetry(self):
        start, end = [144.9631, -37.8136], [144.9631, -37.8036]
        status, forward = self.post({"start": start, "end": end})
        reverse_status, reverse = self.post({"start": end, "end": start})
        self.assertEqual(status, 200)
        self.assertEqual(reverse_status, 200)
        # 0.01 degree of latitude here is about 1.11 km, not degrees or Web Mercator metres.
        self.assertGreater(forward["distance"], 1100)
        self.assertLess(forward["distance"], 1120)
        self.assertAlmostEqual(forward["distance"], reverse["distance"], places=6)

    def test_invalid_positions_are_rejected(self):
        for position in ([145], [145, -38, 10], [181, -38], [145, -91],
                         [-38, 145], ["NaN", -38], [145, "Infinity"], None):
            for field in ("start", "end"):
                with self.subTest(position=position, field=field):
                    payload = {"start": [145, -38], "end": [145, -38]}
                    payload[field] = position
                    status, _ = self.post(payload)
                    self.assertEqual(status, 422)

    def test_missing_position_is_rejected(self):
        status, _ = self.post({"start": [145, -38]})
        self.assertEqual(status, 422)


if __name__ == "__main__":
    unittest.main()