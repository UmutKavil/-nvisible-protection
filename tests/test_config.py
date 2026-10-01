import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parents[1] / "core"))
from config import load_config


class ConfigTests(unittest.TestCase):
    def test_loads_comments_and_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guardian.conf"
            path.write_text("# comment\nINTERFACE=eth0\nPORT=80\n", encoding="utf-8")
            self.assertEqual(load_config(str(path)), {"INTERFACE": "eth0", "PORT": "80"})


if __name__ == "__main__":
    unittest.main()
