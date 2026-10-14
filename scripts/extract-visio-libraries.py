#!/usr/bin/env python3
"""Decode Visio library assets from a mounted Office Click-to-Run image.

Reads the culture manifest and its declared payload ranges. Never executes the
installer. Output must be a new directory; every block and file is hash-checked.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import io
import zlib


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def extract(mount, destination, names=None):
    if destination.exists():
        raise ValueError("Choose a new output directory; existing files are never replaced.")
    data_root = mount / "Office/Data"
    candidates = sorted(data_root.glob("*/s641033.cab"))
    if len(candidates) != 1:
        raise ValueError("Expected one x64 English-US culture manifest in this image.")
    cab = candidates[0]
    manifest = subprocess.check_output(["/usr/bin/tar", "-xOf", str(cab), "Stream.Platform.Culture.man.xml"])
    if len(manifest) > 16 * 1024 * 1024 or b"<!DOCTYPE" in manifest or b"<!ENTITY" in manifest:
        raise ValueError("Unsupported culture manifest.")
    root = ET.fromstring(manifest)
    if root.get("CompressionMethod") != "zlib":
        raise ValueError("Unsupported payload compression.")
    records = []
    taken = set()
    for entry in root.find("Files"):
        name = pathlib.PureWindowsPath(entry.get("Path", "")).name
        if pathlib.Path(name).suffix.lower() not in (".vssx", ".vstx"):
            continue
        if names and name.upper() not in names:
            continue
        if not name or "/" in name or "\\" in name or name.casefold() in taken:
            raise ValueError("Invalid or duplicate library filename.")
        taken.add(name.casefold())
        length = int(entry.get("LocalSizeInBytes", "-1"))
        if not 0 < length <= 16 * 1024 * 1024:
            raise ValueError("Unsupported library file size.")
        records.append((entry, name, length))
    if not records or len(records) > 2000 or sum(r[2] for r in records) > 256 * 1024 * 1024:
        raise ValueError("Unsupported library inventory size.")
    if names and taken != {n.casefold() for n in names}:
        raise ValueError("Some requested library names were not found.")
    payload = cab.parent / "stream.x64.en-us.dat"
    payload_size = payload.stat().st_size
    destination.mkdir(parents=True)
    results = []
    with payload.open("rb") as stream:
        for entry, name, length in records:
            data = bytearray()
            for block in sorted(entry.findall("Range"), key=lambda r: int(r.get("SourceOffset", "-1"))):
                start = int(block.get("FileOffset", "-1"))
                size = int(block.get("FileLength", "-1"))
                offset = int(block.get("SourceOffset", "-1"))
                decoded_size = int(block.get("SourceLength", "-1"))
                if start < 0 or size <= 0 or size > 32 * 1024 * 1024 or start + size > payload_size:
                    raise ValueError("Invalid compressed payload range.")
                if offset != len(data) or decoded_size <= 0 or offset + decoded_size > length:
                    raise ValueError("Overlapping, missing or oversized decoded range.")
                stream.seek(start)
                compressed = stream.read(size)
                if len(compressed) != size or digest(compressed) != block.get("SourceSHA256"):
                    raise ValueError("Compressed payload hash mismatch: " + name)
                decoder = zlib.decompressobj()
                decoded = decoder.decompress(compressed, decoded_size + 1)
                if len(decoded) != decoded_size or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                    raise ValueError("Invalid decoded payload: " + name)
                data.extend(decoded)
            if len(data) != length or digest(data) != entry.get("SHA256"):
                raise ValueError("Library file hash mismatch: " + name)
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                members = archive.infolist()
                if len(members) > 10000 or any(m.file_size > 16 * 1024 * 1024 for m in members) or sum(m.file_size for m in members) > 128 * 1024 * 1024:
                    raise ValueError("Oversized library ZIP content: " + name)
                if archive.testzip() is not None:
                    raise ValueError("Library ZIP checksum mismatch: " + name)
            (destination / name).write_bytes(data)
            results.append({"name": name, "bytes": length, "sha256": digest(data), "installerPath": entry.get("Path")})
    report = {"build": root.get("BuildNumber"), "culture": root.get("Culture"), "manifestSHA256": digest(manifest),
              "files": results, "totalBytes": sum(r["bytes"] for r in results), "count": len(results)}
    (destination / "extraction-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mount", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--name", action="append", help="Extract only these basenames; default is all VSSX/VSTX files")
    args = parser.parse_args()
    report = extract(args.mount.resolve(), args.destination.resolve(), {n.upper() for n in args.name} if args.name else None)
    print(json.dumps({k: v for k, v in report.items() if k != "files"}, indent=2))
