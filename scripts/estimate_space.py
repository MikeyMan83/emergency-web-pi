#!/usr/bin/env python3
"""Estimate total storage required for ZIM files listed by torrent URLs.

This script reads a text file containing one URL per line. For each URL ending
with ".torrent", it probes the corresponding content URL (without ".torrent")
and tries to read size headers from the remote server.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request


def read_urls(path: pathlib.Path) -> list[str]:
    urls: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        urls.append(line)
    return urls


def human_size(num_bytes: int | None) -> str:
    if num_bytes is None:
        return "unknown"
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(num_bytes)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit in {"B", "KB"}:
                return f"{int(value)} {unit}"
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{num_bytes} B"


def probe_size(url: str, timeout: int = 20) -> tuple[int | None, str]:
    # First attempt: HEAD request for Content-Length.
    req = urllib.request.Request(url=url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content_length = resp.headers.get("Content-Length")
            if content_length and content_length.isdigit():
                return int(content_length), "HEAD:Content-Length"
    except urllib.error.HTTPError as exc:
        # Allow fallback attempt for servers that do not support HEAD cleanly.
        head_error = f"HEAD:{exc.code}"
    except Exception:
        head_error = "HEAD:error"
    else:
        head_error = "HEAD:no-length"

    # Second attempt: range GET and parse Content-Range bytes start-end/total.
    req = urllib.request.Request(url=url, method="GET", headers={"Range": "bytes=0-0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content_range = resp.headers.get("Content-Range", "")
            match = re.search(r"/([0-9]+)$", content_range)
            if match:
                return int(match.group(1)), "GET:Content-Range"
            content_length = resp.headers.get("Content-Length")
            if content_length and content_length.isdigit():
                return int(content_length), "GET:Content-Length"
            return None, f"{head_error},GET:no-length"
    except urllib.error.HTTPError as exc:
        return None, f"{head_error},GET:{exc.code}"
    except Exception:
        return None, f"{head_error},GET:error"


def map_to_content_url(source_url: str) -> str:
    if source_url.endswith(".torrent"):
        return source_url[: -len(".torrent")]
    return source_url


def infer_title(source_url: str) -> str:
    slug = source_url.rstrip("/").split("/")[-1]
    if slug.endswith(".torrent"):
        slug = slug[: -len(".torrent")]
    if slug.endswith(".zim"):
        slug = slug[: -len(".zim")]

    known = {
        "wikipedia_nl_all_nopic": "Wikipedia Dutch (no images)",
        "wikipedia_en_all_nopic": "Wikipedia English (no images)",
        "mdwiki_en_all_maxi": "MDWiki (medical encyclopedia)",
        "wikem_en_all_maxi": "WikEM (emergency medicine)",
        "survivalmanual_en_all_maxi": "Survival Manual",
        "ready.gov_en_all_maxi": "Ready.gov",
        "ifixit_en_all_maxi": "iFixit",
        "diy.stackexchange.com_en_all_maxi": "DIY Stack Exchange",
        "mechanics.stackexchange.com_en_all_maxi": "Mechanics Stack Exchange",
        "woodworking.stackexchange.com_en_all_maxi": "Woodworking Stack Exchange",
        "raspberrypi.stackexchange.com_en_all_maxi": "Raspberry Pi Stack Exchange",
    }
    if slug in known:
        return known[slug]
    return slug.replace("_", " ")


def build_data(input_path: pathlib.Path, repo_url: str) -> dict:
    urls = read_urls(input_path)
    rows: list[dict] = []
    total_known = 0
    unknown_count = 0

    for source_url in urls:
        content_url = map_to_content_url(source_url)
        size, method = probe_size(content_url)
        if size is None:
            unknown_count += 1
        else:
            total_known += size
        rows.append(
            {
                "source_url": source_url,
                "title": infer_title(source_url),
                "content_url": content_url,
                "size_bytes": size,
                "size_human": human_size(size),
                "probe_method": method,
            }
        )

    now = dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
    safety_target = int(total_known * 1.2) if total_known > 0 else 0
    is_complete = unknown_count == 0

    return {
        "generated_at": now,
        "source_list": input_path.as_posix(),
        "repository": repo_url,
        "item_count": len(rows),
        "known_count": len(rows) - unknown_count,
        "unknown_count": unknown_count,
        "total_known_bytes": total_known,
        "total_known_human": human_size(total_known),
        "recommended_min_sd_bytes": safety_target,
        "recommended_min_sd_human": human_size(safety_target),
        "is_complete": is_complete,
        "published_total_human": human_size(total_known) if is_complete else "withheld (incomplete)",
        "published_recommended_human": human_size(safety_target) if is_complete else "withheld (incomplete)",
        "rows": rows,
    }


def build_report(data: dict) -> str:
    lines: list[str] = []
    lines.append("# SD Space Estimate")
    lines.append("")
    lines.append(f"Source list: `{data['source_list']}`")
    lines.append(f"Generated: `{data['generated_at']}`")
    lines.append("")
    lines.append("This is an estimate from remote file-size headers. Real on-disk usage can differ slightly.")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- Items checked: `{data['item_count']}`")
    lines.append(f"- Known sizes: `{data['known_count']}`")
    lines.append(f"- Unknown sizes: `{data['unknown_count']}`")
    lines.append(f"- Published total size: `{data['published_total_human']}`")
    lines.append(f"- Published recommended minimum SD size: `{data['published_recommended_human']}`")
    lines.append(f"- Internal known subtotal: `{data['total_known_human']}`")
    if data["unknown_count"] > 0:
        lines.append(f"- Warning: total is incomplete because `{data['unknown_count']}` item(s) have unknown size")
    if data["known_count"] == 0:
        lines.append("- Warning: no remote size headers were available, so no reliable total could be calculated")
    elif data["known_count"] < data["item_count"]:
        lines.append("- Warning: partial total only; treat recommended SD size as a lower bound")
    lines.append("")
    lines.append("## Included Libraries")
    lines.append("")
    for row in data["rows"]:
        lines.append(f"- {row['title']}")
    lines.append("")
    lines.append("## Per Item")
    lines.append("")
    lines.append("| Library | Estimated Size | Probe Method | Source URL |")
    lines.append("|---|---:|---|---|")

    for row in data["rows"]:
        lines.append(f"| {row['title']} | {row['size_human']} | {row['probe_method']} | {row['source_url']} |")

    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append("- Private torrents, CDN behavior, or missing headers can produce `unknown` entries.")
    lines.append("- Keep at least 20% free SD space beyond known content for filesystem health.")
    lines.append(f"- Repository: {data['repository']}")
    lines.append("")
    return "\n".join(lines)


def update_readme_status(readme_path: pathlib.Path, data: dict) -> None:
    if not readme_path.exists():
        return

    text = readme_path.read_text(encoding="utf-8")
    start = "<!-- SPACE_ESTIMATE:START -->"
    end = "<!-- SPACE_ESTIMATE:END -->"
    block = "\n".join(
        [
            start,
            f"Published content size: **{data['published_total_human']}**",
            f"Published recommended minimum SD size: **{data['published_recommended_human']}**",
            f"Known subtotal (diagnostic): {data['total_known_human']}",
            f"Last estimate refresh: {data['generated_at']}",
            end,
        ]
    )

    pattern = re.compile(r"<!-- SPACE_ESTIMATE:START -->.*?<!-- SPACE_ESTIMATE:END -->", re.DOTALL)
    if pattern.search(text):
        updated = pattern.sub(block, text)
    else:
        marker = "HACS-style GitOps workflow for an offline-ready Raspberry Pi Kiwix library."
        if marker in text:
            updated = text.replace(marker, marker + "\n\n" + block, 1)
        else:
            updated = block + "\n\n" + text

    readme_path.write_text(updated, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Estimate required SD storage for ZIM list")
    parser.add_argument("--input", required=True, help="Path to URL list file")
    parser.add_argument("--output", required=True, help="Path to markdown report")
    parser.add_argument("--json-output", default="", help="Optional path to JSON output")
    parser.add_argument("--readme", default="", help="Optional path to README to update estimate status block")
    parser.add_argument("--repo-url", required=True, help="Repository URL for report footer")
    args = parser.parse_args()

    input_path = pathlib.Path(args.input)
    output_path = pathlib.Path(args.output)

    if not input_path.exists():
        print(f"Input file not found: {input_path}", file=sys.stderr)
        return 2

    data = build_data(input_path=input_path, repo_url=args.repo_url)
    report = build_report(data=data)
    output_path.write_text(report + "\n", encoding="utf-8")

    if args.json_output:
        json_output_path = pathlib.Path(args.json_output)
        json_output_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    if args.readme:
        update_readme_status(pathlib.Path(args.readme), data)

    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
