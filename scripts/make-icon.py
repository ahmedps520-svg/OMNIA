"""Renders OMNIA's app icon (1024x1024 RGB PNG, no alpha) with analytic anti-aliasing.

The mark: three frosted glass discs whose overlap forms one luminous center.
Every model, one mind. Matches OmniaMark in the app. Pure standard library.
"""
import math
import struct
import sys
import zlib

SIZE = 1024
DISC_SCALE = 0.215      # disc radius / icon size   (see OmniaMark.swift)
OFFSET_SCALE = 0.115    # distance of each disc center from the mark center


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        handle.write(chunk(b"IEND", b""))


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


WHITE = (246, 248, 252)
TINTS = [(206, 222, 250), (224, 229, 238), (188, 206, 247)]   # top, lower-left, lower-right


def render(path, variant):
    top, bottom = ((38, 41, 47), (12, 13, 16)) if variant == "standard" else ((26, 28, 33), (6, 7, 9))
    cx, cy = SIZE / 2, SIZE / 2 + SIZE * 0.01
    r = SIZE * DISC_SCALE
    offset = SIZE * OFFSET_SCALE
    discs = []
    for index, angle in enumerate((90, 210, 330)):
        a = math.radians(angle)
        discs.append((cx + offset * math.cos(a), cy - offset * math.sin(a), TINTS[index]))
    rim = SIZE * 0.0042

    rows = []
    for py in range(SIZE):
        row = bytearray()
        y = py + 0.5
        base_bg = mix(top, bottom, (y / SIZE) ** 1.1)
        for px in range(SIZE):
            x = px + 0.5
            color = base_bg

            # Soft contact shadow under the group.
            sd = math.hypot((x - cx) / 1.25, y - (cy + SIZE * 0.06))
            color = mix(color, (0, 0, 0), 0.38 * math.exp(-((sd / (SIZE * 0.25)) ** 2)))

            inside_count = 0.0
            for dx_c, dy_c, tint in discs:
                d = math.hypot(x - dx_c, y - dy_c)
                coverage = clamp(r - d + 0.5)
                if coverage <= 0:
                    continue
                inside_count += coverage
                # Frosted body: brighter toward the top, like light entering glass.
                vertical = clamp((dy_c + r - y) / (2 * r))
                body = 0.10 + 0.09 * vertical ** 1.4
                color = mix(color, tint, coverage * body)

                # Edge lighting: bright specular rim on the upper-left, dim refraction edge lower-right.
                edge = clamp(1 - (r - d) / (rim * 3.2))
                angle = math.atan2(dy_c - y, x - dx_c)          # y up
                light = 0.5 + 0.5 * math.cos(angle - math.radians(125))
                color = mix(color, WHITE, coverage * edge * (0.12 + 0.62 * light ** 2))
                color = mix(color, (0, 0, 0), coverage * edge * 0.18 * (1 - light))

            # Where all three meet: one luminous center.
            if inside_count >= 2.99:
                center_d = math.hypot(x - cx, y - cy)
                glow = clamp(1 - center_d / (r * 0.75))
                color = mix(color, mix(WHITE, TINTS[0], 0.25), 0.16 + 0.22 * glow)
            elif inside_count >= 1.99:
                color = mix(color, WHITE, 0.05)

            row.extend(int(round(clamp(c / 255) * 255)) for c in color)
        rows.append(row)
    write_png(path, SIZE, SIZE, rows)


if __name__ == "__main__":
    out_dir = sys.argv[1]
    render(f"{out_dir}/AppIcon.png", "standard")
    render(f"{out_dir}/AppIcon-Dark.png", "dark")
    print("ok")
