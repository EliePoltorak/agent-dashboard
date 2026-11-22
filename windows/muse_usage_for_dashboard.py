#!/usr/bin/env python3
"""
muse_usage_for_dashboard.py -- Muse Code usage for a quota dashboard (Windows)

Runs plain `muse usage` and parses its TEXT output into JSON.
No network calls, no API endpoint, no credentials read, no --json flag.

Usage (Windows, in PowerShell or cmd):
    python muse_usage_for_dashboard.py
    python muse_usage_for_dashboard.py --out muse_usage.json
    python muse_usage_for_dashboard.py --self-test

Output (stdout, or the --out file) is JSON like:
    {
      "provider": "muse_code",
      "source": "muse usage",
      "ok": true,
      "collected_at": "2026-11-21T18:30:00",
      "tier": "Power Usage",
      "five_hour_used_percent": 12.0,
      "five_hour_resets_at": "2026-11-21 23:00",
      "weekly_used_percent": 34.0,
      "weekly_resets_at": "2026-11-24 14:00",
      "raw": "<full text from `muse usage`>",
      "parse_notes": []
    }

Fields are null when the text does not contain them. `raw` is always
included, so the dashboard can fall back to it, and so a format change
in `muse usage` is visible instead of silently producing wrong numbers.

This parser is deliberately defensive: the exact wording of
`muse usage` is not documented and may change. It looks for the
5-hour and weekly allowances by keyword, not by fixed line numbers.
If it ever returns nulls for values you can see in the raw text,
paste me the raw text (with any account details removed) and I will
adjust the patterns.
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys

# Keywords that identify the two allowances. Keep them broad on purpose.
FIVE_HOUR_KEYS = ("5-hour", "5 hour", "5h", "session")
WEEKLY_KEYS = ("weekly", "week", "7-day", "7 day")


def _first_percent(line):
    m = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
    return float(m.group(1)) if m else None


def _find_percent(lines, keys):
    """First percentage on a line mentioning one of `keys`, else on the next line."""
    for i, line in enumerate(lines):
        low = line.lower()
        if any(k in low for k in keys):
            pct = _first_percent(line)
            if pct is not None:
                return pct
            if i + 1 < len(lines):
                pct = _first_percent(lines[i + 1])
                if pct is not None:
                    return pct
    return None


def _find_reset(lines, keys):
    """Text after 'reset' on a line mentioning one of `keys`, else any reset line."""
    for line in lines:
        low = line.lower()
        if "reset" in low and any(k in low for k in keys):
            return _clean_reset(line)
    for line in lines:
        if "reset" in line.lower():
            return _clean_reset(line)
    return None


def _clean_reset(line):
    # "Resets Nov 24 at 2:00 PM" -> "Nov 24 at 2:00 PM"
    # "Weekly limit resets ..." -> keep the tail after 'reset(s)'.
    m = re.search(r"resets?\s*(?:at\s*)?(.+)$", line, re.IGNORECASE)
    if m:
        return m.group(1).strip(" .:-")
    return line.strip()


def _find_tier(lines):
    for line in lines:
        low = line.lower()
        if "plan" in low or "tier" in low or "subscription" in low:
            # "Plan: Power Usage" / "Tier: Maximum" / "Current plan - Power"
            m = re.search(r"[:\-–—]\s*(.+)$", line)
            if m and m.group(1).strip():
                return m.group(1).strip()
    # Known Muse Code plan names, if they appear anywhere on their own.
    joined = " ".join(lines)
    for name in ("Maximum Usage", "Power Usage", "Maximum", "Power"):
        if name.lower() in joined.lower():
            return name
    return None


def parse_usage_text(raw):
    """Parse `muse usage` text. Returns a dict; unknown fields are None."""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    notes = []

    five = _find_percent(lines, FIVE_HOUR_KEYS)
    weekly = _find_percent(lines, WEEKLY_KEYS)

    # Fallback: if neither keyword matched but exactly two percentages
    # appear, in order, assume 5-hour then weekly -- and say so.
    if five is None and weekly is None:
        pcts = []
        for line in lines:
            pcts.extend(float(x) for x in re.findall(r"(\d+(?:\.\d+)?)\s*%", line))
        if len(pcts) == 2:
            five, weekly = pcts
            notes.append("No 5-hour/weekly labels found; assumed first % is 5-hour, second is weekly.")
        elif pcts:
            notes.append("Found %d percentage(s) but could not label them 5-hour/weekly." % len(pcts))

    five_reset = _find_reset(lines, FIVE_HOUR_KEYS)
    weekly_reset = _find_reset(lines, WEEKLY_KEYS)
    # If only one reset line exists, _find_reset returns it for both;
    # clear the duplicate unless the line mentions that allowance.
    if five_reset and five_reset == weekly_reset:
        five_line = next((l for l in lines if "reset" in l.lower()), "")
        if not any(k in five_line.lower() for k in FIVE_HOUR_KEYS):
            five_reset = None
        if not any(k in five_line.lower() for k in WEEKLY_KEYS):
            weekly_reset = None

    if five is None:
        notes.append("5-hour usage % not found in text.")
    if weekly is None:
        notes.append("Weekly usage % not found in text.")

    return {
        "provider": "muse_code",
        "source": "muse usage",
        "ok": True,
        "collected_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "tier": _find_tier(lines),
        "five_hour_used_percent": five,
        "five_hour_resets_at": five_reset,
        "weekly_used_percent": weekly,
        "weekly_resets_at": weekly_reset,
        "raw": raw,
        "parse_notes": notes,
    }


def run_muse_usage(timeout=60):
    """Run plain `muse usage`. Returns (returncode, stdout_text, error_message)."""
    exe = shutil.which("muse")
    if not exe:
        return None, "", "`muse` was not found on PATH. Install / log in to Muse Code first, then retry."
    try:
        proc = subprocess.run(
            [exe, "usage"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None, "", "`muse usage` timed out after %d seconds." % timeout
    except OSError as exc:
        return None, "", "Could not run `muse usage`: %s" % exc
    raw = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
    if proc.returncode != 0:
        return proc.returncode, raw.strip(), "`muse usage` exited with code %d." % proc.returncode
    return 0, raw.strip(), None


def self_test():
    """Check the parser against illustrative samples (not real output)."""
    samples = [
        (
            "Plan: Power Usage\n5-hour usage: 12% used\nResets at 11:00 PM\nWeekly usage: 34% used\nWeekly limit resets Nov 24 at 2:00 PM\n",
            12.0, 34.0, "Power Usage",
        ),
        (
            "Weekly: 61% used, resets Monday\n5 hour: 8% used\n",
            8.0, 61.0, None,
        ),
        (
            "Usage\n5-hour allowance 45%\nWeekly allowance 70%\n",
            45.0, 70.0, None,
        ),
    ]
    ok = True
    for raw, want_five, want_weekly, want_tier in samples:
        got = parse_usage_text(raw)
        good = (
            got["five_hour_used_percent"] == want_five
            and got["weekly_used_percent"] == want_weekly
            and got["tier"] == want_tier
        )
        print(("PASS" if good else "FAIL"), repr(raw[:40]), "->", got["five_hour_used_percent"], got["weekly_used_percent"], got["tier"])
        ok = ok and good
    print("self-test:", "OK" if ok else "FAILED")
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description="Parse `muse usage` text output into JSON for a quota dashboard.")
    parser.add_argument("--out", help="Write JSON to this file instead of stdout")
    parser.add_argument("--timeout", type=int, default=60, help="Seconds to wait for `muse usage` (default 60)")
    parser.add_argument("--self-test", action="store_true", help="Run the parser self-test and exit")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    code, raw, error = run_muse_usage(timeout=args.timeout)
    if error is not None:
        result = {
            "provider": "muse_code",
            "source": "muse usage",
            "ok": False,
            "collected_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "tier": None,
            "five_hour_used_percent": None,
            "five_hour_resets_at": None,
            "weekly_used_percent": None,
            "weekly_resets_at": None,
            "raw": raw,
            "error": error,
            "parse_notes": [],
        }
        text = json.dumps(result, indent=2, ensure_ascii=False)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(text)
        else:
            print(text)
        return 2 if code is None else code

    result = parse_usage_text(raw)
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
