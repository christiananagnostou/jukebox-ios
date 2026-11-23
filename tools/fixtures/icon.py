#!/usr/bin/env python3
import json, math, struct, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIZE = 1024
BACKGROUND, FOREGROUND = (23, 23, 31), (168, 193, 235)

def covered(x, y):
    if abs(math.hypot(x - 8, y - 18) - 4) <= 1:
        return True
    for ax, ay, bx, by in [(12, 18, 12, 2), (12, 2, 19, 6)]:
        vx, vy = bx - ax, by - ay
        t = max(0, min(1, ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)))
        if (x - ax - t * vx) ** 2 + (y - ay - t * vy) ** 2 <= 1:
            return True
    return False

def build():
    scale, inset = SIZE * .64 / 24, SIZE * .18
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)
        for x in range(SIZE):
            n = sum(covered((x + (sx + .5) / 4 - inset) / scale,
                            (y + (sy + .5) / 4 - inset) / scale)
                    for sy in range(4) for sx in range(4))
            rows.extend(round(a + (b - a) * n / 16) for a, b in zip(BACKGROUND, FOREGROUND))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    result = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
    catalog = ROOT / 'App/Assets.xcassets'
    icon = catalog / 'AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    (catalog / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    (icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    (icon / 'AppIcon.png').write_bytes(result)
