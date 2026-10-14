#!/usr/bin/env python3
"""Ajustes do FreeYomi no código do OpenJDK Mobile antes de compilar.

1. iOS sem páginas executáveis: o HotSpot reserva o CodeCache como memória
   executável (mprotect com PROT_EXEC), o que o iOS recusa a apps comuns.
   O interpretador Zero não executa código gerado, então no iOS o commit é
   feito só com leitura e escrita.
Uso: apply.py <pasta do openjdk/mobile>
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def patch(rel, old, new, marker):
    p = root / rel
    s = p.read_text()
    if marker in s:
        print(f"{rel}: já aplicado")
        return
    if old not in s:
        sys.exit(f"{rel}: trecho não encontrado; o código do OpenJDK mudou")
    p.write_text(s.replace(old, new, 1))
    print(f"{rel}: aplicado")

patch(
    "src/hotspot/os/bsd/os_bsd.cpp",
    "bool os::pd_commit_memory(char* addr, size_t size, bool exec) {\n",
    "bool os::pd_commit_memory(char* addr, size_t size, bool exec) {\n"
    "#ifdef __IOS__\n"
    "  // FreeYomi: o Zero não executa código gerado e o iOS proíbe páginas executáveis.\n"
    "  exec = false;\n"
    "#endif\n",
    "FreeYomi: o Zero não executa código gerado",
)
