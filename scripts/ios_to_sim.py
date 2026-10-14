#!/usr/bin/env python3
"""Marca bibliotecas estáticas arm64 de iPhone como arm64 de simulador.

Em Apple Silicon o código de máquina do simulador é o mesmo do aparelho; só
muda a plataforma gravada em LC_BUILD_VERSION (2 = iOS, 7 = iOS Simulator).
Este script altera esse campo em cada objeto Mach-O dentro do arquivo .a,
no próprio lugar, sem mudar tamanhos (a tabela de símbolos continua válida).
Uso: ios_to_sim.py entrada.a saída.a
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS, PLATFORM_IOSSIMULATOR = 2, 7


def patch_macho(buf, start):
    magic, _cpu, _sub, _ftype, ncmds, _size, _flags, _res = struct.unpack_from("<IiiIIIII", buf, start)
    if magic != MH_MAGIC_64:
        return 0, 0
    off = start + 32
    patched = old_style = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", buf, off + 8)[0]
            if platform == PLATFORM_IOS:
                struct.pack_into("<I", buf, off + 8, PLATFORM_IOSSIMULATOR)
                patched += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            old_style += 1
        off += cmdsize
    return patched, old_style


def main(src, dst):
    buf = bytearray(open(src, "rb").read())
    if buf[:8] != b"!<arch>\n":
        patched, old = patch_macho(buf, 0)
        open(dst, "wb").write(buf)
        print(f"{src}: objeto único, {patched} alterado(s)")
        return
    off = 8
    objects = patched_total = old_total = 0
    while off + 60 <= len(buf):
        header = buf[off:off + 60]
        name = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode().strip())
        data = off + 60
        name_len = 0
        if name.startswith("#1/"):
            name_len = int(name[3:])
        member = data + name_len
        if member + 4 <= len(buf) and struct.unpack_from("<I", buf, member)[0] == MH_MAGIC_64:
            objects += 1
            p, o = patch_macho(buf, member)
            patched_total += p
            old_total += o
        off = data + size
        if off % 2:
            off += 1
    open(dst, "wb").write(buf)
    print(f"{src}: {objects} objetos, {patched_total} marcados como simulador, {old_total} com LC_VERSION_MIN (não alterados)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
