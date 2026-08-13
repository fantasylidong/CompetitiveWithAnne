#!/usr/bin/env python3
"""Analyze the cloud58 2026-07 vs 2026-08 infected distance A/B run."""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import re
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean


CLASSES = ("smoker", "boomer", "hunter", "spitter", "jockey", "charger")
CLASS_BY_ID = {index + 1: name for index, name in enumerate(CLASSES)}
EXPECTED_CLASSES = {name: 2 for name in CLASSES}
METRICS = ("team_min_distance", "team_max_distance", "nearest_nav_distance")

PROBE_RE = re.compile(
    r"\[NavMatrix\] ProbeSpawn seq=(?P<seq>\d+) .*?class=(?P<class>[1-6]) .*?"
    r"teamMinDistance=(?P<team_min>-?\d+(?:\.\d+)?) .*?"
    r"teamMaxDistance=(?P<team_max>-?\d+(?:\.\d+)?) .*?"
    r"nearestNavDistance=(?P<nav>N/A|-?\d+(?:\.\d+)?)"
)
SPAWN_RE = re.compile(
    r"\[SpawnWave\]\[Spawn\] wave=(?P<wave>\d+) seq=(?P<seq>\d+) "
    r"result=success .*?mode=(?P<mode>\S+) "
    r"class=(?P<class>\S+) .*?teamMinDistance=(?P<team_min>-?\d+(?:\.\d+)?) .*?"
    r"teamMaxDistance=(?P<team_max>-?\d+(?:\.\d+)?) .*?"
    r"navDistance=(?P<nav>N/A|-?\d+(?:\.\d+)?)"
)
API_RE = re.compile(
    r"\[FALLBACK API\] class=(?P<class>\S+) target=\d+ tries=(?P<tries>\d+) "
    r"result=(?P<result>hit|miss|cap_reject|safety_reject)"
)
DIRECTOR_CAP_RE = re.compile(
    r"\[SpawnPerf\]\[DirectorCap\] stage=(?P<stage>request|actual) .*?"
    r"class=(?P<class>\S+) .*?result=rejected"
)


def load_results(path: Path) -> list[dict]:
    records = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            record = json.loads(line)
            record["_results_path"] = str(path)
            records.append(record)
    return records


def load_tree(root: Path) -> list[dict]:
    records = []
    for path in sorted(root.rglob("results.jsonl")):
        records.extend(load_results(path))
    return records


def key(record: dict) -> tuple[str, int]:
    return record["map"], int(record["requested_percent"])


def exact_quota(counts: dict | None) -> bool:
    return counts == EXPECTED_CLASSES


def valid_probe(record: dict) -> bool:
    return record.get("probe_samples") == 12 and exact_quota(record.get("probe_classes"))


def valid_production(record: dict) -> bool:
    return record.get("spawn_success") == 12 and exact_quota(record.get("classes"))


def local_raw_path(record: dict) -> Path | None:
    raw = record.get("raw_log")
    if not raw:
        return None
    results_path = Path(record["_results_path"])
    candidate = results_path.parent / "raw" / Path(raw).name
    return candidate if candidate.exists() else None


def parse_probe(record: dict) -> list[dict]:
    path = local_raw_path(record)
    if path is None:
        return []
    groups = []
    samples = []
    previous_seq = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PROBE_RE.search(line)
        if not match:
            continue
        seq = int(match.group("seq"))
        if samples and seq <= previous_seq:
            groups.append(samples)
            samples = []
        previous_seq = seq
        nav = match.group("nav")
        nav_distance = None if nav == "N/A" else float(nav)
        if nav_distance is not None and nav_distance < 0.0:
            nav_distance = None
        samples.append(
            {
                "class": CLASS_BY_ID[int(match.group("class"))],
                "team_min_distance": float(match.group("team_min")),
                "team_max_distance": float(match.group("team_max")),
                "nearest_nav_distance": nav_distance,
            }
        )
    if samples:
        groups.append(samples)
    expected_count = record.get("probe_samples")
    expected_classes = record.get("probe_classes")
    matching = [
        group
        for group in groups
        if len(group) == expected_count and Counter(sample["class"] for sample in group) == expected_classes
    ]
    return matching[-1] if matching else (groups[-1] if groups else [])


def parse_production(record: dict) -> list[dict]:
    path = local_raw_path(record)
    if path is None:
        return []
    groups = []
    samples = []
    previous = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = SPAWN_RE.search(line)
        if not match:
            continue
        marker = (int(match.group("wave")), int(match.group("seq")))
        if samples and previous is not None and (marker[0] != previous[0] or marker[1] <= previous[1]):
            groups.append(samples)
            samples = []
        previous = marker
        nav = match.group("nav")
        samples.append(
            {
                "class": match.group("class"),
                "mode": match.group("mode"),
                "team_min_distance": float(match.group("team_min")),
                "team_max_distance": float(match.group("team_max")),
                "internal_nav_distance": None if nav == "N/A" else float(nav),
            }
        )
    if samples:
        groups.append(samples)
    expected_count = record.get("spawn_success")
    expected_classes = record.get("classes")
    matching = [
        group
        for group in groups
        if len(group) == expected_count and Counter(sample["class"] for sample in group) == expected_classes
    ]
    return matching[-1] if matching else (groups[-1] if groups else [])


def parse_api(record: dict) -> tuple[list[dict], list[dict], list[dict]]:
    path = local_raw_path(record)
    if path is None:
        return [], [], []
    calls = []
    director = []
    cap_rejects = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        api_match = API_RE.search(line)
        if api_match:
            calls.append(
                {
                    "class": api_match.group("class"),
                    "tries": int(api_match.group("tries")),
                    "result": api_match.group("result"),
                }
            )
        cap_match = DIRECTOR_CAP_RE.search(line)
        if cap_match:
            cap_rejects.append(
                {"class": cap_match.group("class"), "stage": cap_match.group("stage")}
            )
        spawn_match = SPAWN_RE.search(line)
        if spawn_match and spawn_match.group("mode").endswith("director_range"):
            director.append(
                {
                    "class": spawn_match.group("class"),
                    "team_min_distance": float(spawn_match.group("team_min")),
                    "team_max_distance": float(spawn_match.group("team_max")),
                }
            )
    return calls, director, cap_rejects


def quantile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * p
    low = math.floor(index)
    high = math.ceil(index)
    if low == high:
        return ordered[low]
    fraction = index - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def stats(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "min": None, "p50": None, "p95": None, "max": None, "avg": None}
    return {
        "count": len(values),
        "min": round(min(values), 3),
        "p50": round(quantile(values, 0.50), 3),
        "p95": round(quantile(values, 0.95), 3),
        "max": round(max(values), 3),
        "avg": round(mean(values), 3),
    }


def bootstrap_mean_ci(values: list[float], seed: int, rounds: int = 10000) -> list[float | None]:
    if not values:
        return [None, None]
    rng = random.Random(seed)
    size = len(values)
    estimates = []
    for _ in range(rounds):
        estimates.append(sum(values[rng.randrange(size)] for _ in range(size)) / size)
    return [round(quantile(estimates, 0.025), 3), round(quantile(estimates, 0.975), 3)]


def choose_first(records: list[dict], predicate) -> dict | None:
    for record in records:
        if predicate(record):
            return record
    return None


def grouped(records: list[dict]) -> dict[tuple[str, int], list[dict]]:
    result = defaultdict(list)
    for record in records:
        result[key(record)].append(record)
    return result


def summarize_paired(
    paired_samples: dict[tuple[str, int], tuple[list[dict], list[dict]]],
    metric: str,
    seed: int,
) -> dict:
    old_values = []
    current_values = []
    cell_deltas = []
    class_deltas = defaultdict(list)
    class_old = defaultdict(list)
    class_current = defaultdict(list)
    wins = 0
    ties = 0
    for old_samples, current_samples in paired_samples.values():
        old_metric = [sample[metric] for sample in old_samples if sample.get(metric) is not None]
        current_metric = [sample[metric] for sample in current_samples if sample.get(metric) is not None]
        old_values.extend(old_metric)
        current_values.extend(current_metric)
        old_cell = mean(old_metric)
        current_cell = mean(current_metric)
        delta = old_cell - current_cell
        cell_deltas.append(delta)
        wins += delta > 0
        ties += delta == 0
        for class_name in CLASSES:
            old_class = [sample[metric] for sample in old_samples if sample["class"] == class_name and sample.get(metric) is not None]
            current_class = [sample[metric] for sample in current_samples if sample["class"] == class_name and sample.get(metric) is not None]
            class_old[class_name].extend(old_class)
            class_current[class_name].extend(current_class)
            if len(old_class) == 2 and len(current_class) == 2:
                class_deltas[class_name].append(mean(old_class) - mean(current_class))
    old_avg = mean(old_values)
    current_avg = mean(current_values)
    result = {
        "paired_cells": len(cell_deltas),
        "old": stats(old_values),
        "current": stats(current_values),
        "old_minus_current_cell_mean": round(mean(cell_deltas), 3),
        "relative_to_current_percent": round((old_avg - current_avg) / current_avg * 100.0, 3),
        "bootstrap_95_ci": bootstrap_mean_ci(cell_deltas, seed),
        "old_farther_cell_rate_percent": round(wins / len(cell_deltas) * 100.0, 3),
        "tie_cell_rate_percent": round(ties / len(cell_deltas) * 100.0, 3),
        "by_class": {},
    }
    for class_index, class_name in enumerate(CLASSES):
        deltas = class_deltas[class_name]
        old_class_avg = mean(class_old[class_name])
        current_class_avg = mean(class_current[class_name])
        result["by_class"][class_name] = {
            "paired_cells": len(deltas),
            "old": stats(class_old[class_name]),
            "current": stats(class_current[class_name]),
            "old_minus_current_mean": round(mean(deltas), 3),
            "relative_to_current_percent": round(
                (old_class_avg - current_class_avg) / current_class_avg * 100.0, 3
            ),
            "bootstrap_95_ci": bootstrap_mean_ci(deltas, seed + class_index + 1),
            "old_farther_cell_rate_percent": round(sum(value > 0 for value in deltas) / len(deltas) * 100.0, 3),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    old_main = load_results(root / "anne_distance_ab_2607_every5_final_20260811" / "results.jsonl")
    old_retests = load_tree(root / "anne_distance_ab_2607_retests_20260812")
    current_main = load_results(root / "anne_distance_ab_2608_every5_final_20260812" / "results.jsonl")
    current_retests = load_tree(root / "anne_distance_ab_2608_clean_retests_20260812")
    current_retests += load_results(
        root / "anne_distance_ab_2608_retest_c10m5_5_20260812" / "results.jsonl"
    )

    old_main_by_key = {key(record): record for record in old_main}
    current_main_by_key = {key(record): record for record in current_main}
    old_retests_by_key = grouped(old_retests)
    current_retests_by_key = grouped(current_retests)

    old_selected = {}
    for cell, record in old_main_by_key.items():
        selected = record if valid_probe(record) else choose_first(old_retests_by_key[cell], valid_probe)
        if selected:
            old_selected[cell] = selected

    current_selected = {}
    current_probe_selected = {}
    current_probe_override = {("c1m1_hotel", 65), ("c1m1_hotel", 70), ("c1m1_hotel", 75)}
    current_retest_override = {("c10m5_houseboat", 5), ("c13m4_cutthroatcreek", 95)}
    for cell, record in current_main_by_key.items():
        if cell in current_probe_override:
            selected = choose_first(current_retests_by_key[cell], valid_probe)
            if selected:
                current_selected[cell] = (selected, "probe")
                current_probe_selected[cell] = selected
            continue
        if cell in current_retest_override:
            selected = choose_first(current_retests_by_key[cell], valid_production)
        else:
            selected = record if valid_production(record) else choose_first(
                current_retests_by_key[cell], valid_production
            )
        if selected:
            current_selected[cell] = (selected, "production")
        probe_selected = selected if selected and valid_probe(selected) else (
            record if valid_probe(record) else choose_first(current_retests_by_key[cell], valid_probe)
        )
        if probe_selected:
            current_probe_selected[cell] = probe_selected

    common_cells = sorted(set(old_selected) & set(current_probe_selected))
    paired_3d = {}
    paired_nav = {}
    detail_rows = []
    for cell in common_cells:
        old_record = old_selected[cell]
        current_record = current_probe_selected[cell]
        old_samples = parse_probe(old_record)
        current_samples = parse_probe(current_record)
        if len(old_samples) != 12 or len(current_samples) != 12:
            raise RuntimeError(f"unexpected 3D sample count for {cell}: {len(old_samples)}/{len(current_samples)}")
        paired_3d[cell] = (old_samples, current_samples)

        current_probe_record = current_probe_selected.get(cell)
        current_probe_samples = parse_probe(current_probe_record) if current_probe_record else []
        old_nav_complete = len(old_samples) == 12 and Counter(s["class"] for s in old_samples) == EXPECTED_CLASSES
        current_nav_complete = (
            len(current_probe_samples) == 12
            and Counter(s["class"] for s in current_probe_samples) == EXPECTED_CLASSES
        )
        if old_nav_complete and current_nav_complete:
            old_numeric = [s for s in old_samples if s["nearest_nav_distance"] is not None]
            current_numeric = [s for s in current_probe_samples if s["nearest_nav_distance"] is not None]
            if len(old_numeric) == 12 and len(current_numeric) == 12:
                paired_nav[cell] = (old_samples, current_probe_samples)

        detail_rows.append(
            {
                "map": cell[0],
                "progress": cell[1],
                "old_source": "main" if old_record is old_main_by_key[cell] else "retest",
                "current_source": "main" if current_record is current_main_by_key[cell] else "retest",
                "old_team_min_avg": round(mean(s["team_min_distance"] for s in old_samples), 3),
                "current_team_min_avg": round(mean(s["team_min_distance"] for s in current_samples), 3),
                "old_team_max_avg": round(mean(s["team_max_distance"] for s in old_samples), 3),
                "current_team_max_avg": round(mean(s["team_max_distance"] for s in current_samples), 3),
                "old_nav_numeric": sum(s["nearest_nav_distance"] is not None for s in old_samples),
                "current_nav_numeric": sum(
                    s["nearest_nav_distance"] is not None for s in current_probe_samples
                ),
                "paired_nav": cell in paired_nav,
            }
        )

    result = {
        "contract": {
            "maps": 57,
            "progress_points": 19,
            "requested_cells": 1083,
            "class_quota": EXPECTED_CLASSES,
            "teleport_cvar_during_test": 0,
            "team_distance": "actual SI origin to live survivor eye, 3D Euclidean",
            "observer_nav_distance": "minimum directed path distance from actual SI Nav to each live survivor target Nav",
            "larger_is_farther": True,
            "preferred_direction": "smaller",
        },
        "coverage": {
            "old_main_strict_complete": sum(record.get("complete_12") is True for record in old_main),
            "current_main_strict_complete": sum(record.get("complete_12") is True for record in current_main),
            "old_valid_after_retests": len(old_selected),
            "current_generation_valid_after_retests": len(current_selected),
            "current_observer_valid_after_retests": len(current_probe_selected),
            "paired_3d_cells": len(common_cells),
            "paired_3d_spawns": len(common_cells) * 12,
            "paired_nav_cells": len(paired_nav),
            "paired_nav_spawns": len(paired_nav) * 12,
            "old_observer_nav_numeric": sum(row["old_nav_numeric"] for row in detail_rows),
            "current_observer_nav_numeric": sum(row["current_nav_numeric"] for row in detail_rows),
            "observer_nav_expected": len(common_cells) * 12,
            "old_cells_with_nav_unavailable": [
                [row["map"], row["progress"]]
                for row in detail_rows
                if row["old_nav_numeric"] < 12
            ],
            "current_cells_with_nav_unavailable": [
                [row["map"], row["progress"]]
                for row in detail_rows
                if row["current_nav_numeric"] < 12
            ],
            "shared_fixture_failure": ["c5m5_bridge", 10],
            "old_persistent_spawn_or_quota_failures": [
                ["c1m1_hotel", 20],
                ["c3m1_plankcountry", 45],
                ["c3m1_plankcountry", 50],
                ["c3m1_plankcountry", 80],
                ["c5m5_bridge", 5],
            ],
        },
        "paired": {
            "team_min_distance": summarize_paired(paired_3d, "team_min_distance", 260701),
            "team_max_distance": summarize_paired(paired_3d, "team_max_distance", 260702),
            "observer_nav_distance": summarize_paired(paired_nav, "nearest_nav_distance", 260703),
        },
    }

    # Current Director/API behavior uses one selected run per runnable cell.
    api_records = {}
    for cell, record in current_main_by_key.items():
        if cell == ("c5m5_bridge", 10):
            continue
        if cell in current_retest_override:
            selected = choose_first(current_retests_by_key[cell], valid_production)
            if selected:
                api_records[cell] = selected
        else:
            api_records[cell] = record
    api_calls = []
    director_spawns = []
    director_cap_rejects = []
    for record in api_records.values():
        calls, spawns, cap_rejects = parse_api(record)
        api_calls.extend(calls)
        director_spawns.extend(spawns)
        director_cap_rejects.extend(cap_rejects)
    by_class = {}
    for class_name in CLASSES:
        class_calls = [call for call in api_calls if call["class"] == class_name]
        class_spawns = [spawn for spawn in director_spawns if spawn["class"] == class_name]
        by_class[class_name] = {
            "calls": len(class_calls),
            "hits": sum(call["result"] == "hit" for call in class_calls),
            "misses": sum(call["result"] == "miss" for call in class_calls),
            "request_cap_rejects": sum(call["result"] == "cap_reject" for call in class_calls),
            "request_safety_rejects": sum(call["result"] == "safety_reject" for call in class_calls),
            "actual_cap_rejects": sum(
                reject["stage"] == "actual" and reject["class"] == class_name
                for reject in director_cap_rejects
            ),
            "successes": len(class_spawns),
            "team_min_distance": stats([spawn["team_min_distance"] for spawn in class_spawns]),
            "team_max_distance": stats([spawn["team_max_distance"] for spawn in class_spawns]),
        }
    result["current_director_api"] = {
        "cells": len(api_records),
        "calls": len(api_calls),
        "hits": sum(call["result"] == "hit" for call in api_calls),
        "misses": sum(call["result"] == "miss" for call in api_calls),
        "request_cap_rejects": sum(call["result"] == "cap_reject" for call in api_calls),
        "request_safety_rejects": sum(call["result"] == "safety_reject" for call in api_calls),
        "actual_cap_rejects": sum(reject["stage"] == "actual" for reject in director_cap_rejects),
        "tries_7": sum(call["tries"] == 7 for call in api_calls),
        "tries_12": sum(call["tries"] == 12 for call in api_calls),
        "successful_director_spawns": len(director_spawns),
        "team_min_distance": stats([spawn["team_min_distance"] for spawn in director_spawns]),
        "team_max_distance": stats([spawn["team_max_distance"] for spawn in director_spawns]),
        "by_class": by_class,
    }

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "analysis.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    with (args.output / "paired_cells.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(detail_rows[0]))
        writer.writeheader()
        writer.writerows(detail_rows)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
