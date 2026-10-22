#!/usr/bin/env python3
# Diagnostic only: prints "<section> <size> <sha256>" for every section of an ELF file (32 or 64
# bit, little endian), so that two builds that differ can be compared section by section
# (.text, .rodata, .dynsym, .note.gnu.build-id, .comment...). Standard library only.
import hashlib
import struct
import sys


def sections(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[5] != 1:
        raise SystemExit(f"{path}: not a little-endian ELF file")
    is64 = data[4] == 2
    if is64:
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        fmt = "<IIQQQQIIQQ"
    else:
        shoff, = struct.unpack_from("<I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
        fmt = "<IIIIIIIIII"
    headers = [struct.unpack_from(fmt, data, shoff + i * shentsize) for i in range(shnum)]
    strtab = headers[shstrndx]
    str_off = strtab[4]
    for h in headers:
        name_off, sh_type, offset, size = h[0], h[1], h[4], h[5]
        end = data.index(b"\0", str_off + name_off)
        name = data[str_off + name_off:end].decode() or "<null>"
        body = b"" if sh_type == 8 else data[offset:offset + size]  # SHT_NOBITS: no bytes
        yield name, size, hashlib.sha256(body).hexdigest()


for path in sys.argv[1:]:
    for name, size, digest in sections(path):
        print(f"{name} {size} {digest}")
