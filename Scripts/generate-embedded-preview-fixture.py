#!/usr/bin/env python3
"""
Writes Packages/ShrikeKit/Tests/ShrikeCoreTests/Fixtures/embedded_preview.jpg:
a 2048 x 2048 JPEG with a 192 x 192 thumbnail in the EXIF IFD1 block.

Why not ImageIO: `kCGImageDestinationEmbedThumbnail` is skipped on some macOS
releases for small images, so the fixture is built with Pillow + piexif and
checked in. The test (FileImageSourceTests) reads the thumbnail back through
`loadEmbeddedPreview`.

Needs: pip3 install pillow piexif
"""

import io
from pathlib import Path

import piexif
from PIL import Image

OUT = (Path(__file__).resolve().parent.parent
       / "Packages" / "ShrikeKit" / "Tests" / "ShrikeCoreTests" / "Fixtures"
       / "embedded_preview.jpg")

SIZE = 2048
THUMB = 192


def gradient(size: int) -> Image.Image:
    """A diagonal blue-to-orange gradient, so the image is not flat."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    span = 2 * (size - 1)
    for y in range(size):
        for x in range(size):
            r = (x + y) * 255 // span
            px[x, y] = (r, 128, 255 - r)
    return img


def main() -> None:
    full = gradient(SIZE)

    thumb = full.resize((THUMB, THUMB))
    buf = io.BytesIO()
    thumb.save(buf, "JPEG", quality=80)

    exif = piexif.dump({
        "0th": {
            piexif.ImageIFD.Make: b"Shrike Test",
            piexif.ImageIFD.Model: b"Test Camera",
        },
        "1st": {
            piexif.ImageIFD.Compression: 6,
            piexif.ImageIFD.XResolution: (72, 1),
            piexif.ImageIFD.YResolution: (72, 1),
            piexif.ImageIFD.ResolutionUnit: 2,
        },
        "thumbnail": buf.getvalue(),
    })
    full.save(OUT, "JPEG", quality=85, exif=exif)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
