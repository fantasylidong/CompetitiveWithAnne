#!/usr/bin/env python3
"""Summarize 12-SI matrix waves: completion, spawn time, and pairwise clustering."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from collections import Counter
from pathlib import Path


PROBE_POS_RE = re.compile(
    r"\[NavMatrix\] ProbeSpawn seq=(?P<seq>\d+) .*?"
    r"pos=\((?P<x>-?\d+(?:\.\d+)?) (?P<y>-?\d+(?:\.\d+)?) (?P<z>-?\d+(?:\.\d+)?)\)"
)
SCORE_BUDGET_RE = re.compile(
    r"\[SCORE BUDGET\] near=(?P<near>\d+)/(?P<near_cap>\d+) "
    r"mid=(?P<mid>\d+)/(?P<mid_cap>\d+) far=(?P<far>\d+)/(?P<far_cap>\d+) "
    r"accepted=(?P<accepted>\d+) budget=(?P<budget>\d+) "
    r"inspected=(?P<inspected>\d+) expensive=(?P<expensive>\d+)"
)
PAIR_THRESHOLDS = (150.0, 180.0, 250.0, 400.0, 600.0)


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = round((len(ordered) - 1) * pct)
    return ordered[index]


def pairwise_stats(points: list[tuple[float, float, float]]) -> dict:
    if len(points) < 2:
        return {
            "pairs": 0,
            "min": None,
            "p50": None,
            "avg": None,
            **{f"lt_{int(threshold)}": 0 for threshold in PAIR_THRESHOLDS},
        }
    distances = []
    counts = {threshold: 0 for threshold in PAIR_THRESHOLDS}
    for i, left in enumerate(points):
        for right in points[i + 1:]:
            dx = left[0] - right[0]
            dy = left[1] - right[1]
            dz = left[2] - right[2]
            dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            distances.append(dist)
            for threshold in PAIR_THRESHOLDS:
                if dist < threshold:
                    counts[threshold] += 1
    return {
        "pairs": len(distances),
        "min": round(min(distances), 1),
        "p50": round(percentile(distances, 0.50) or 0.0, 1),
        "avg": round(sum(distances) / len(distances), 1),
        **{f"lt_{int(threshold)}": counts[threshold] for threshold in PAIR_THRESHOLDS},
    }


def load_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def parse_bool(value: str | bool | None) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes"}


def parse_float(value: str | float | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def collect_raw_logs(root: Path) -> list[Path]:
    return sorted(root.rglob("*.log")) + sorted((root / "raw").glob("*")) if (root / "raw").exists() else sorted(root.rglob("*"))


def extract_probe_points(text: str) -> list[tuple[float, float, float]]:
    points = []
    seen = set()
    for match in PROBE_POS_RE.finditer(text):
        seq = int(match.group("seq"))
        if seq in seen:
            continue
        seen.add(seq)
        points.append((float(match.group("x")), float(match.group("y")), float(match.group("z"))))
    return points


def summarize_budgets(text: str) -> dict:
    near = mid = far = accepted = 0
    rows = 0
    for match in SCORE_BUDGET_RE.finditer(text):
        rows += 1
        near += int(match.group("near"))
        mid += int(match.group("mid"))
        far += int(match.group("far"))
        accepted += int(match.group("accepted"))
    if rows == 0:
        return {"samples": 0}
    return {
        "samples": rows,
        "avg_near": round(near / rows, 2),
        "avg_mid": round(mid / rows, 2),
        "avg_far": round(far / rows, 2),
        "avg_accepted": round(accepted / rows, 2),
        "near_share": round(near / max(accepted, 1), 3),
        "mid_share": round(mid / max(accepted, 1), 3),
        "far_share": round(far / max(accepted, 1), 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()

    records: list[dict] = []
    raw_texts: list[str] = []
    seen_raw: set[Path] = set()
    for root in args.roots:
        csv_paths = [root] if root.suffix == ".csv" else list(root.rglob("results.csv"))
        if root.name == "results.csv":
            csv_paths = [root]
        for csv_path in csv_paths:
            if csv_path.exists():
                records.extend(load_csv(csv_path))
        search_root = root.parent if root.suffix == ".csv" else root
        for path in search_root.rglob("*.log"):
            resolved = path.resolve()
            if resolved in seen_raw:
                continue
            seen_raw.add(resolved)
            try:
                raw_texts.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue

    complete = [parse_bool(row.get("complete_12")) for row in records]
    wave_ms = [value for value in (parse_float(row.get("server_wave_ms")) for row in records) if value is not None]
    last_ms = [value for value in (parse_float(row.get("last_spawn_ms")) for row in records) if value is not None]
    wall_ms = [value for value in (parse_float(row.get("wall_ms")) for row in records) if value is not None]
    unique_nav = [value for value in (parse_float(row.get("unique_nav")) for row in records) if value is not None]
    errors = Counter(row.get("error") or "" for row in records if row.get("error"))

    pair_mins: list[float] = []
    close_counts = {threshold: [] for threshold in PAIR_THRESHOLDS}
    clustered_waves = 0
    probe_waves = 0
    for text in raw_texts:
        # Split by result markers when a file contains multiple waves
        chunks = re.split(r"\[NavMatrix\] End .* result requested=", text)
        bodies = chunks if len(chunks) == 1 else chunks[:-1]
        for body in bodies:
            points = extract_probe_points(body)
            if len(points) < 8:
                continue
            probe_waves += 1
            stats = pairwise_stats(points)
            if stats["min"] is not None:
                pair_mins.append(stats["min"])
            for threshold in PAIR_THRESHOLDS:
                close_counts[threshold].append(stats[f"lt_{int(threshold)}"])
            if stats["lt_180"] >= 6 or stats["lt_250"] >= 10:
                clustered_waves += 1

    budget = summarize_budgets("\n".join(raw_texts))
    report = {
        "cases": len(records),
        "complete_12": sum(complete),
        "complete_rate": round(sum(complete) / len(records), 3) if records else None,
        "server_wave_ms": {
            "n": len(wave_ms),
            "min": round(min(wave_ms), 1) if wave_ms else None,
            "p50": round(percentile(wave_ms, 0.50) or 0.0, 1) if wave_ms else None,
            "p95": round(percentile(wave_ms, 0.95) or 0.0, 1) if wave_ms else None,
            "max": round(max(wave_ms), 1) if wave_ms else None,
            "avg": round(statistics.mean(wave_ms), 1) if wave_ms else None,
            "over_3000": sum(value > 3000 for value in wave_ms),
            "over_8000": sum(value > 8000 for value in wave_ms),
        },
        "last_spawn_ms": {
            "p50": round(percentile(last_ms, 0.50) or 0.0, 1) if last_ms else None,
            "p95": round(percentile(last_ms, 0.95) or 0.0, 1) if last_ms else None,
            "max": round(max(last_ms), 1) if last_ms else None,
        },
        "unique_nav": {
            "avg": round(statistics.mean(unique_nav), 2) if unique_nav else None,
            "p50": round(percentile(unique_nav, 0.50) or 0.0, 2) if unique_nav else None,
        },
        "pairwise": {
            "waves": probe_waves,
            "min_p50": round(percentile(pair_mins, 0.50) or 0.0, 1) if pair_mins else None,
            "min_p05": round(percentile(pair_mins, 0.05) or 0.0, 1) if pair_mins else None,
            "clustered_waves": clustered_waves,
            **{
                f"avg_pairs_lt_{int(threshold)}": round(statistics.mean(close_counts[threshold]), 2)
                if close_counts[threshold] else None
                for threshold in PAIR_THRESHOLDS
            },
        },
        "score_budget": budget,
        "errors": dict(errors),
        "slowest": sorted(
            (
                {
                    "map": row.get("map"),
                    "percent": row.get("requested_percent"),
                    "server_wave_ms": parse_float(row.get("server_wave_ms")),
                    "complete_12": parse_bool(row.get("complete_12")),
                    "error": row.get("error") or "",
                }
                for row in records
            ),
            key=lambda item: (item["server_wave_ms"] is None, -(item["server_wave_ms"] or 0.0)),
        )[:12],
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
