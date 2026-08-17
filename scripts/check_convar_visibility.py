#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = REPO_ROOT / "addons" / "sourcemod" / "scripting"

EXCLUDED_PREFIXES = (
    "archive/",
    "disabled/",
    "dev_plugins/",
    "sourcemod/",
)
EXCLUDED_PATHS = {
    "optional/AnneHappy/infected_control26-07.sp",
}
EXCLUDED_DIRS = (
    "optional/AnneHappy/infected_control26-07/",
)

PUBLIC_ALLOWLIST = {
    "anne_round_wipe_count": "optional/AnneHappy/server.sp",
}

TOKEN_RE = re.compile(r"\bFCVAR_NOTIFY\b")
CREATE_RE = re.compile(
    r'CreateConVar\s*\(\s*"(?P<name>[^"]+)"(?P<body>.*?)\);',
    re.DOTALL,
)
SUPPRESSION_RE = re.compile(r"&\s*~\s*(?P<token>FCVAR_NOTIFY)\b")


def is_excluded(relative_path: str) -> bool:
    return (
        relative_path in EXCLUDED_PATHS
        or relative_path.startswith(EXCLUDED_PREFIXES)
        or relative_path.startswith(EXCLUDED_DIRS)
    )


def source_files() -> list[Path]:
    output = subprocess.check_output(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
    )
    files: list[Path] = []
    source_prefix = SOURCE_ROOT.relative_to(REPO_ROOT).as_posix() + "/"
    for raw_path in output.split(b"\0"):
        if not raw_path:
            continue
        relative_path = raw_path.decode("utf-8", errors="surrogateescape")
        if not relative_path.startswith(source_prefix):
            continue
        if not relative_path.endswith((".sp", ".inc")):
            continue
        path = REPO_ROOT / relative_path
        if path.is_file() and not path.is_symlink():
            files.append(path)
    return sorted(files)


def code_mask(text: str) -> bytearray:
    """Mark SourcePawn code while excluding comments and quoted literals."""
    mask = bytearray(b"\x01" * len(text))
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            if end == -1:
                end = len(text)
            mask[index:end] = b"\x00" * (end - index)
            index = end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = len(text) if end == -1 else end + 2
            mask[index:end] = b"\x00" * (end - index)
            index = end
            continue
        if text[index] in {'"', "'"}:
            quote = text[index]
            end = index + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                    continue
                end += 1
                if text[end - 1] == quote:
                    break
            mask[index:end] = b"\x00" * (end - index)
            index = end
            continue
        index += 1
    return mask


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def main() -> int:
    violations: list[str] = []
    seen_public: set[str] = set()

    for path in source_files():
        relative_path = path.relative_to(SOURCE_ROOT).as_posix()
        if is_excluded(relative_path):
            continue

        text = path.read_text(encoding="utf-8")
        mask = code_mask(text)
        allowed_offsets: set[int] = set()

        for match in CREATE_RE.finditer(text):
            if not mask[match.start()]:
                continue
            name = match.group("name")
            expected_path = PUBLIC_ALLOWLIST.get(name)
            if expected_path != relative_path:
                continue

            for token in TOKEN_RE.finditer(match.group(0)):
                token_offset = match.start() + token.start()
                if not mask[token_offset]:
                    continue
                allowed_offsets.add(token_offset)
                seen_public.add(name)

        # Temporarily clearing NOTIFY and restoring a complete flags snapshot is
        # compatible with the policy because it can only reduce visibility.
        for match in SUPPRESSION_RE.finditer(text):
            token_offset = match.start("token")
            if mask[token_offset]:
                allowed_offsets.add(token_offset)

        for token in TOKEN_RE.finditer(text):
            if not mask[token.start()]:
                continue
            if token.start() in allowed_offsets:
                continue

            line = line_number(text, token.start())
            source_line = text.splitlines()[line - 1].strip()
            violations.append(f"{relative_path}:{line}: {source_line}")

    for name, expected_path in PUBLIC_ALLOWLIST.items():
        if name not in seen_public:
            violations.append(
                f"{expected_path}: allowlisted ConVar {name!r} is missing FCVAR_NOTIFY"
            )

    if violations:
        print("ConVar visibility policy violations:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        return 1

    print(
        "ConVar visibility policy passed: only allowlisted public ConVars use "
        "FCVAR_NOTIFY."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
