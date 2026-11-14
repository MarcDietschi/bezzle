#!/usr/bin/env python3
"""Says how far apart two folders of pictures are, the Mac's and Windows' of the same designs
(depth-agreement.sh): for each PNG of the same name in both, the largest difference of a channel,
the mean, and the share of channels more than 2 and more than 8 apart, of 255, colours counted as
they lie under their alpha. With a third folder, the difference magnified eight times is written
there as <name>-difference.png.

    depth-compare.py <the Mac's folder> <Windows' folder> [folder for the differences]

Reads and writes PNG itself (8 bits a channel, not interlaced), so it needs nothing installed."""
import os
import struct
import sys
import zlib


def read(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'{path} is not a PNG')
    at, parts, head, palette, clear = 8, [], None, None, None
    while at < len(data):
        length, kind = struct.unpack('>I4s', data[at:at + 8])
        body = data[at + 8:at + 8 + length]
        if kind == b'IHDR':
            head = struct.unpack('>IIBBBBB', body)
        elif kind == b'PLTE':
            palette = body
        elif kind == b'tRNS':
            clear = body
        elif kind == b'IDAT':
            parts.append(body)
        at += 12 + length
    width, height, depth, colour, _, _, interlaced = head
    if depth != 8 or interlaced:
        raise ValueError(f'{path}: {depth} bits a channel, interlaced {interlaced}: not read here')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    raw = zlib.decompress(b''.join(parts))
    stride = width * channels
    before = bytearray(stride)
    pixels = bytearray(width * height * 4)
    for y in range(height):
        start = y * (stride + 1)
        way = raw[start]
        line = bytearray(raw[start + 1:start + 1 + stride])
        if way == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif way == 2:
            for i in range(stride):
                line[i] = (line[i] + before[i]) & 255
        elif way == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + before[i]) >> 1)) & 255
        elif way == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = before[i]
                c = before[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        before = line
        row = y * width * 4
        if colour == 6:
            pixels[row:row + stride] = line
        elif colour == 2:
            for x in range(width):
                pixels[row + x * 4:row + x * 4 + 3] = line[x * 3:x * 3 + 3]
                pixels[row + x * 4 + 3] = 255
        elif colour == 0:
            for x in range(width):
                v = line[x]
                pixels[row + x * 4:row + x * 4 + 4] = bytes((v, v, v, 255))
        elif colour == 4:
            for x in range(width):
                v = line[x * 2]
                pixels[row + x * 4:row + x * 4 + 4] = bytes((v, v, v, line[x * 2 + 1]))
        else:
            for x in range(width):
                k = line[x]
                pixels[row + x * 4:row + x * 4 + 3] = palette[k * 3:k * 3 + 3]
                pixels[row + x * 4 + 3] = clear[k] if clear and k < len(clear) else 255
    return width, height, pixels


def write(path, width, height, pixels):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    lines = b''.join(b'\x00' + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(lines, 6)) + chunk(b'IEND', b''))


def under(pixels):
    """Colours as they lie under their alpha."""
    out = bytearray(pixels)
    for i in range(0, len(out), 4):
        a = out[i + 3]
        if a != 255:
            out[i] = (out[i] * a + 127) // 255
            out[i + 1] = (out[i + 1] * a + 127) // 255
            out[i + 2] = (out[i + 2] * a + 127) // 255
    return out


def compare(mac, windows, differences=None):
    names = sorted(n for n in os.listdir(mac) if n.endswith('.png'))
    worst = 0
    print('picture\tpixels\tlargest\tmean\tover 2\tover 8')
    for name in names:
        other = os.path.join(windows, name)
        if not os.path.exists(other):
            print(f'{name}\tnot drawn on Windows')
            worst = 255
            continue
        w, h, a = read(os.path.join(mac, name))
        w2, h2, b = read(other)
        if (w, h) != (w2, h2):
            print(f'{name}\t{w}x{h} on the Mac, {w2}x{h2} on Windows')
            worst = 255
            continue
        a, b = under(a), under(b)
        apart = bytes(abs(x - y) for x, y in zip(a, b))
        largest = max(apart)
        worst = max(worst, largest)
        count = len(apart)
        print(f'{name}\t{w}x{h}\t{largest}\t{sum(apart) / count:.3f}\t{100 * sum(1 for d in apart if d > 2) / count:.2f}%'
              f'\t{100 * sum(1 for d in apart if d > 8) / count:.2f}%')
        if differences:
            os.makedirs(differences, exist_ok=True)
            shown = bytearray(len(apart))
            for i in range(0, len(apart), 4):
                shown[i] = min(255, apart[i] * 8)
                shown[i + 1] = min(255, apart[i + 1] * 8)
                shown[i + 2] = min(255, max(apart[i + 2], apart[i + 3]) * 8)
                shown[i + 3] = 255
            write(os.path.join(differences, name[:-4] + '-difference.png'), w, h, shown)
    return worst


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    compare(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
