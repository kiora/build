#!/usr/bin/env python3
import pathlib
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} <openclash.lua>")

path = pathlib.Path(sys.argv[1])
s = path.read_text(encoding="utf-8")

# The LuCI status endpoint calls coremetacv() frequently. Upstream executes the
# large Mihomo core with `-v` here just to obtain a version string. On Newifi D1
# (256 MB RAM) that can briefly create a second large Mihomo process while the
# real OpenClash core is running. Keep the endpoint but make it non-executing.
pattern = re.compile(
    r"local function coremetacv\(\)\n.*?\nend\n\n(?=local function)",
    re.S,
)
replacement = 'local function coremetacv()\n\treturn "unknown"\nend\n\n'

m = pattern.search(s)
if not m:
    raise SystemExit("coremetacv() function block not found; refusing unsafe patch")

old = m.group(0)
if old == replacement:
    print("OpenClash LuCI coremetacv low-memory patch already present")
    raise SystemExit(0)

if " -v " not in old and "-v 2>" not in old:
    raise SystemExit("coremetacv() no longer contains expected -v probe; review upstream before patching")

s2, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit(f"expected one coremetacv() replacement, got {n}")

path.write_text(s2, encoding="utf-8")
print("Patched OpenClash LuCI coremetacv(): disabled executable core version probe")
