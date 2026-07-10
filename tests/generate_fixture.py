#!/usr/bin/env python3
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def perspective_coefficients(destination, source):
    matrix = []
    vector = []
    for (x, y), (u, v) in zip(destination, source):
        matrix.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        matrix.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        vector.extend([u, v])
    return np.linalg.solve(np.asarray(matrix, dtype=float), np.asarray(vector, dtype=float))


def main():
    output = Path(__file__).resolve().parent / "斜拍发票测试.jpg"
    canvas = Image.new("RGB", (1600, 1200), (83, 88, 96))
    background = ImageDraw.Draw(canvas)
    for y in range(0, 1200, 40):
        shade = 83 + (y // 40) % 2 * 5
        background.rectangle((0, y, 1600, y + 40), fill=(shade, shade + 4, shade + 9))

    invoice = Image.new("RGB", (900, 1300), "white")
    draw = ImageDraw.Draw(invoice)
    font = ImageFont.load_default(size=32)
    small = ImageFont.load_default(size=23)
    draw.rectangle((20, 20, 880, 1280), outline=(35, 35, 35), width=4)
    draw.text((300, 70), "INVOICE", fill=(20, 20, 20), font=font)
    draw.text((60, 145), "Invoice No: 20260711001", fill=(30, 30, 30), font=small)
    draw.text((60, 200), "Date: 2026-07-11", fill=(30, 30, 30), font=small)
    draw.line((60, 265, 840, 265), fill=(40, 40, 40), width=3)
    rows = [
        ("Service A", "1", "320.00"),
        ("Service B", "2", "180.00"),
        ("Materials", "1", "96.00"),
        ("Tax", "", "35.76"),
    ]
    y = 330
    for name, qty, price in rows:
        draw.text((70, y), name, fill=(30, 30, 30), font=small)
        draw.text((560, y), qty, fill=(30, 30, 30), font=small)
        draw.text((690, y), price, fill=(30, 30, 30), font=small)
        draw.line((60, y + 45, 840, y + 45), fill=(175, 175, 175), width=2)
        y += 105
    draw.text((520, 850), "TOTAL", fill=(20, 20, 20), font=font)
    draw.text((690, 850), "811.76", fill=(20, 20, 20), font=font)
    draw.rectangle((80, 1030, 340, 1190), outline=(180, 30, 30), width=8)
    draw.text((125, 1085), "STAMP", fill=(180, 30, 30), font=font)

    # Simulate an uneven, warm phone-camera exposure so the regression test
    # also checks scanner-style lighting correction and colour retention.
    pixels = np.asarray(invoice, dtype=np.float32)
    x = np.linspace(0.0, 1.0, invoice.width, dtype=np.float32)[None, :, None]
    y = np.linspace(0.0, 1.0, invoice.height, dtype=np.float32)[:, None, None]
    illumination = 0.64 + 0.34 * x + 0.05 * y
    warm_tint = np.asarray([1.04, 0.97, 0.86], dtype=np.float32)[None, None, :]
    pixels = np.clip(pixels * illumination * warm_tint, 0, 255).astype(np.uint8)
    invoice = Image.fromarray(pixels, mode="RGB")

    destination = [(280, 80), (1320, 190), (1450, 1040), (140, 1110)]
    source = [(0, 0), (899, 0), (899, 1299), (0, 1299)]
    coefficients = perspective_coefficients(destination, source)

    warped = invoice.transform(
        canvas.size,
        Image.Transform.PERSPECTIVE,
        coefficients,
        resample=Image.Resampling.BICUBIC,
        fillcolor=(83, 88, 96),
    )
    mask_source = Image.new("L", invoice.size, 255)
    mask = mask_source.transform(
        canvas.size,
        Image.Transform.PERSPECTIVE,
        coefficients,
        resample=Image.Resampling.BICUBIC,
        fillcolor=0,
    )
    canvas.paste(warped, (0, 0), mask)
    canvas.save(output, quality=94)
    print(output)


if __name__ == "__main__":
    main()
