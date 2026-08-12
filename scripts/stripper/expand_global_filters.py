#!/usr/bin/env python3

import argparse
import sys
from pathlib import Path


BEGIN_PREFIX = b"; BEGIN GENERATED GLOBAL FILTERS: "
END_MARKER = b"; END GENERATED GLOBAL FILTERS\n"
DIVIDER = b"; ====================================================="
ALWAYS_GLOBAL_SECTIONS = {
    b"ITEM DENSITY FIX",
    b"WEAPON SKINS",
    b"T2 WEAPON SPAWN FIX",
    b"PILL CABINET MAX OVERRIDE",
    b"ITEM PICKUP FIX",
    b"COMPETITIVE ITEM SPAWNS",
}


def strip_generated_block(data: bytes) -> bytes:
    if not data.startswith(BEGIN_PREFIX):
        return data

    end = data.find(END_MARKER)
    if end < 0:
        raise ValueError("generated block has no end marker")

    body = data[end + len(END_MARKER) :]
    if body.startswith(b"\n"):
        body = body[1:]
    return body


def inherited_from(map_name: str, names: set[str]) -> str | None:
    for index, character in enumerate(map_name):
        if character == "_" and map_name[:index] in names:
            return map_name[:index]
    return None


def split_source(source: bytes) -> tuple[bytes, bytes]:
    lines = source.splitlines(keepends=True)
    starts: list[int] = []
    for index in range(len(lines) - 1):
        if lines[index].rstrip(b"\r\n") == DIVIDER and lines[index + 1].startswith(b"; =="):
            starts.append(index)

    if not starts or starts[0] != 0:
        raise ValueError("could not identify global filter sections")

    starts.append(len(lines))
    always_global: list[bytes] = []
    map_only: list[bytes] = []
    for section_index in range(len(starts) - 1):
        begin = starts[section_index]
        end = starts[section_index + 1]
        section = b"".join(lines[begin:end])
        title = lines[begin + 1].strip().strip(b";= ")
        target = always_global if title in ALWAYS_GLOBAL_SECTIONS else map_only
        target.append(section.rstrip(b"\r\n") + b"\n")

    return b"".join(always_global), b"".join(map_only)


def expected_map_data(mode: str, map_source: bytes, map_path: Path, names: set[str]) -> bytes:
    original = strip_generated_block(map_path.read_bytes())
    if inherited_from(map_path.stem, names) is not None:
        return original

    begin = BEGIN_PREFIX + mode.encode("ascii") + b"\n"
    normalized_source = map_source.rstrip(b"\r\n") + b"\n"
    separator = b"\n" if original else b""
    return begin + normalized_source + END_MARKER + separator + original


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    source_root = script_dir / "global_filters"
    runtime_root = repo_root / "cfg" / "stripper"
    failures: list[str] = []

    mode = "zonemod_anne"
    source_path = source_root / f"{mode}.cfg"
    mode_root = runtime_root / mode
    runtime_global = mode_root / "global_filters.cfg"
    maps_root = mode_root / "maps"
    source = source_path.read_bytes()
    always_global, map_source = split_source(source)
    map_paths = sorted(maps_root.glob("*.cfg"))
    names = {path.stem for path in map_paths}

    if args.check:
        if not runtime_global.is_file() or runtime_global.read_bytes() != always_global:
            failures.append(f"{runtime_global}: generated global content is stale")
    else:
        runtime_global.write_bytes(always_global)

    for map_path in map_paths:
        try:
            expected = expected_map_data(mode, map_source, map_path, names)
        except ValueError as error:
            failures.append(f"{map_path}: {error}")
            continue

        current = map_path.read_bytes()
        if args.check:
            if current != expected:
                failures.append(f"{map_path}: generated content is stale")
        elif current != expected:
            map_path.write_bytes(expected)

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    action = "verified" if args.check else "expanded"
    print(f"Stripper global filters {action} successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
