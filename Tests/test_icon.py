"""Verify the approved artwork is packaged intact, using only macOS build tools."""
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def png_size(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError(f"Not a PNG: {path}")
    return struct.unpack(">II", data[16:24])


@unittest.skipUnless(sys.platform == "darwin", "iconutil and AppKit require macOS")
class IconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="splash-finish-icon-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.output = Path(cls.temp.name)
        subprocess.run(["/usr/bin/swift", str(ROOT / "Scripts/render_icon.swift"), str(cls.output)],
                       cwd=cls.output, check=True, capture_output=True, timeout=120)

    def test_standard_layers_preserve_approved_artwork(self):
        iconset = self.output / "Icon.iconset"
        self.assertEqual(len(list(iconset.glob("*.png"))), 10)
        for points in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                suffix = "@2x" if scale == 2 else ""
                layer = iconset / f"icon_{points}x{points}{suffix}.png"
                pixels = points * scale
                with self.subTest(points=points, scale=scale):
                    self.assertEqual(png_size(layer), (pixels, pixels))
                    approved = ROOT / "Assets/AppIcon/png" / f"{pixels}.png"
                    self.assertEqual(layer.read_bytes(), approved.read_bytes())

    def test_icns_can_be_decoded_with_all_layers(self):
        archive = self.output / "Icon.icns"
        self.assertEqual(archive.read_bytes()[:4], b"icns")
        decoded = self.output / "decoded.iconset"
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", str(archive), "-o", str(decoded)],
                       check=True, capture_output=True, timeout=30)
        for layer in (self.output / "Icon.iconset").glob("*.png"):
            with self.subTest(layer=layer.name):
                self.assertEqual(png_size(decoded / layer.name), png_size(layer))


if __name__ == "__main__":
    unittest.main()
