import os
import sys
import unittest
import importlib.util
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "web"))
sys.path.insert(0, str(Path(__file__).parents[1] / "storage"))


@unittest.skipUnless(importlib.util.find_spec("flask"), "Flask is not installed")
class ApiSecurityTests(unittest.TestCase):
    def test_api_requires_real_bearer_token_and_health_is_minimal(self) -> None:
        with patch.dict(os.environ, {"GUARDIAN_API_TOKEN": "test-token"}):
            import api

            client = api.app.test_client()
            self.assertEqual(client.get("/health").json, {"status": "ok"})
            self.assertEqual(client.get("/api/stats").status_code, 401)
            self.assertEqual(
                client.get(
                    "/api/stats",
                    headers={"Authorization": "Bearer ******"},
                ).status_code,
                401,
            )
            self.assertEqual(
                client.get(
                    "/api/stats",
                    headers={"Authorization": "Bearer test-token"},
                ).status_code,
                200,
            )
