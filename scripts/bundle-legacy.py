#!/usr/bin/env python3
"""Bundle the native libvisio reader and relocate only copies of its dependencies."""
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

def copy_file(source, destination):
    destination = pathlib.Path(destination)
    if destination.exists():
        destination.unlink()
    shutil.copy2(source, destination)

app = pathlib.Path(sys.argv[1]).resolve()
tools = [shutil.which(name) for name in ("vsd2xhtml", "vss2xhtml")]
if not all(tools):
    raise SystemExit("Legacy VSD support requires libvisio at build time: brew install libvisio")
helpers = app / "Contents/Helpers"
frameworks = app / "Contents/Frameworks"
licenses = app / "Contents/Resources/Licenses"
for directory in (helpers, frameworks, licenses):
    directory.mkdir(parents=True, exist_ok=True)
bundled_helpers = []
queue = []
for tool in tools:
    helper = helpers / pathlib.Path(tool).name
    copy_file(tool, helper)
    bundled_helpers.append(helper)
    queue.append((pathlib.Path(tool).resolve(), helper))
copied = {}
records = []
while queue:
    source, destination = queue.pop(0)
    output = subprocess.check_output(["otool", "-L", str(source)], text=True)
    if destination.suffix == ".dylib":
        subprocess.run(["install_name_tool", "-id", "@rpath/" + destination.name, str(destination)], check=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (")[0]
        if dependency.startswith("@loader_path/"):
            dependency_source = source.parent / dependency.removeprefix("@loader_path/")
        elif dependency.startswith("@rpath/"):
            dependency_source = source.parent / dependency.removeprefix("@rpath/")
            if not dependency_source.exists():
                raise SystemExit(f"Cannot resolve bundled library dependency {dependency} in {source}")
        elif dependency.startswith(("/opt/homebrew/", "/usr/local/")):
            dependency_source = pathlib.Path(dependency)
        else:
            continue
        canonical = dependency_source.resolve(strict=True)
        if canonical == source:
            continue
        if canonical not in copied:
            target = frameworks / dependency_source.name
            if target.exists() and target.resolve() != canonical:
                target.unlink()
            copy_file(canonical, target)
            copied[canonical] = target
            queue.append((canonical, target))
            records.append({"source": str(canonical), "bundled": target.name})
        target = copied[canonical]
        new_path = "@loader_path/" + ("../Frameworks/" if destination.parent == helpers else "") + target.name
        subprocess.run(["install_name_tool", "-change", dependency, new_path, str(destination)], check=True)
for library in copied.values():
    subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
for helper in bundled_helpers:
    subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True)

prefixes = {"libvisio": "/opt/homebrew/opt/libvisio", "librevenge": "/opt/homebrew/opt/librevenge", "icu": "/opt/homebrew/opt/icu4c@78"}
for name, prefix in prefixes.items():
    directory = pathlib.Path(prefix).resolve()
    if not directory.exists():
        continue
    candidates = list(directory.glob("COPYING*")) + list(directory.glob("LICENSE*")) + list(directory.glob("license*"))
    candidates += list(directory.glob("share/icu/*/LICENSE*"))
    for file in candidates:
        if file.is_file():
            copy_file(file, licenses / (name + "-" + file.name))
zip_license = pathlib.Path(".build/checkouts/ZIPFoundation/LICENSE")
if zip_license.exists():
    copy_file(zip_license, licenses / "ZIPFoundation-LICENSE")
(licenses / "SOURCES.txt").write_text(
    "libvisio 0.1.11 (MPL 2.0): https://dev-www.libreoffice.org/src/libvisio/libvisio-0.1.11.tar.xz\n"
    "librevenge 0.0.6 (MPL 2.0/LGPL): https://downloads.sourceforge.net/project/libwpd/librevenge/librevenge-0.0.6/librevenge-0.0.6.tar.xz\n"
    "ICU 78.3 (Unicode License): https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz\n"
    "ZIPFoundation 0.9.20 (MIT): https://github.com/weichsel/ZIPFoundation/tree/0.9.20\n"
    "Library source code was not modified. The bundle script relocates copies of Mach-O load paths.\n"
)
(licenses / "Bundled-Libraries.json").write_text(json.dumps(records, indent=2) + "\n")
# Declare the actual deployment floor of the bundled reader, not just Swift's floor.
plist_path = app / "Contents/Info.plist"
with plist_path.open("rb") as file:
    info = plistlib.load(file)
versions = [info.get("LSMinimumSystemVersion", "13.0")]
for binary in [*bundled_helpers, *copied.values()]:
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    versions.extend(re.findall(r"\bminos\s+([0-9.]+)", commands))
floor = max(versions, key=lambda version: tuple(int(x) for x in version.split(".")))
info["LSMinimumSystemVersion"] = floor
with plist_path.open("wb") as file:
    plistlib.dump(info, file)
print(f"Bundle requires macOS {floor} or later")
print(f"Bundled legacy reader and {len(copied)} native libraries")
