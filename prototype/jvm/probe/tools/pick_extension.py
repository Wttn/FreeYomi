#!/usr/bin/env python3
"""Baixa uma extensão de teste (pt-BR, segura, extensions-lib 1.5+) de um índice index.json
e grava extension.jar + extension.txt (classe principal, lida do AndroidManifest do .jar)."""
import io, json, re, sys, urllib.request, zipfile

index_url, out = sys.argv[1], sys.argv[2]
data = json.load(urllib.request.urlopen(index_url, timeout=60))
exts = data["extensionList"]["extensions"]
def ok(e):
    langs = {s.get("language") for s in e.get("sources", [])}
    return (langs == {"pt-BR"} and e.get("contentWarning") in ("CONTENT_WARNING_SAFE", 1)
            and e.get("resources", {}).get("jarUrl") and float(e.get("extensionLib", "0")) >= 1.5)
for e in [x for x in exts if ok(x)][:10]:
    jar = urllib.request.urlopen(e["resources"]["jarUrl"], timeout=120).read()
    z = zipfile.ZipFile(io.BytesIO(jar))
    manifest = z.read("AndroidManifest.xml").decode("utf-8", "replace")
    m = re.search(r'android:name="tachiyomi\.extension\.class"\s+android:value="([^"]+)"', manifest)
    if not m:
        continue
    cls = m.group(1)
    if cls.startswith("."):
        pkg = re.search(r'package="([^"]+)"', manifest).group(1)
        cls = pkg + cls
    open(f"{out}/extension.jar", "wb").write(jar)
    open(f"{out}/extension.txt", "w").write(cls)
    print(f"{e['name']} {e['versionName']} ({e['packageName']}) classe {cls}, {len(jar)} bytes")
    break
else:
    sys.exit("nenhuma extensão adequada")
