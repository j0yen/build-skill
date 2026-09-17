#!/usr/bin/env python3
"""reviewer-receipt-resolve.py — PRD-build-reviewer-receipt-primary.

Decides whether the reviewer subagent's own receipt file
(target/autobuilder/receipts/reviewer-agent.json, per its prompt's "##
Output" contract) is FRESH enough to be the reviewer phase's authoritative
verdict (R1), and separately balanced-decodes the subagent's raw stdout
for a fallback object (R2) so extend-gate.sh's run_reviewer() never has to
choose between the two inline in bash.

Usage:
    reviewer-receipt-resolve.py <receipt_path> <raw_stdout_path> <head_sha> <prepare_floor_epoch>

Prints one JSON object to stdout:
    {
      "receipt_exists": bool,
      "receipt_schema_ok": bool,
      "receipt_head": <head_sha or null>,
      "receipt_reviewed_at": <"<ISO8601>Z" or null>,
      "receipt_decision": <"pass"|"concern"|"block" or null>,
      "receipt_reasons": [...],
      "fresh": bool,
      "stdout_object_found": bool,
      "stdout_decision": <str or null>,
      "stdout_reasons": [...]
    }

A receipt is "fresh" (R1) when: schema == autobuilder.reviewer_agent_receipt.v1,
head_sha == the gated head, AND reviewed_at (or file mtime when reviewed_at
is absent/unparseable) is at or after <prepare_floor_epoch> (the phase's
own `prepare` call, captured by the caller BEFORE the review subagent ran
— so a receipt left over from a previous gate on the same head can never
read as fresh for THIS run).

Stdout is decoded with json.JSONDecoder().raw_decode from every '{' in the
text (R2) — not the greedy `\\{.*\\}` regex this replaces, which grabs from
the FIRST '{' to the LAST '}' in the whole blob and breaks the moment any
prose around the JSON contains its own brace characters (AC4).
"""
import json
import os
import sys
import datetime

SCHEMA = "autobuilder.reviewer_agent_receipt.v1"


def _iso_to_epoch(s):
    if not s:
        return None
    try:
        dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None


def _epoch_to_iso(epoch):
    try:
        return datetime.datetime.fromtimestamp(
            epoch, tz=datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None


def _balanced_objects(text):
    """Yield every top-level JSON object decodable starting at each '{' in
    text, in order — a '}' anywhere else in surrounding prose (AC4) never
    breaks this, unlike a greedy regex from the first '{' to the last '}'."""
    dec = json.JSONDecoder()
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "{":
            try:
                obj, _end = dec.raw_decode(text, i)
                if isinstance(obj, dict):
                    yield obj
            except ValueError:
                pass
        i += 1


def main():
    if len(sys.argv) != 5:
        print("usage: reviewer-receipt-resolve.py <receipt> <raw> <head_sha> <prepare_floor_epoch>", file=sys.stderr)
        return 2
    receipt_path, raw_path, head_sha, floor_arg = sys.argv[1:5]
    try:
        floor = float(floor_arg)
    except ValueError:
        floor = 0.0

    result = {
        "receipt_exists": False,
        "receipt_schema_ok": False,
        "receipt_head": None,
        "receipt_reviewed_at": None,
        "receipt_decision": None,
        "receipt_reasons": [],
        "fresh": False,
        "stdout_object_found": False,
        "stdout_decision": None,
        "stdout_reasons": [],
    }

    if os.path.isfile(receipt_path):
        result["receipt_exists"] = True
        try:
            with open(receipt_path, "r") as f:
                obj = json.load(f)
        except Exception:
            obj = None
        if isinstance(obj, dict) and obj.get("schema") == SCHEMA:
            result["receipt_schema_ok"] = True
            result["receipt_head"] = obj.get("head_sha")
            result["receipt_decision"] = obj.get("decision")
            result["receipt_reasons"] = obj.get("block_reasons") or []
            ts = _iso_to_epoch(obj.get("reviewed_at"))
            if ts is None:
                try:
                    ts = os.path.getmtime(receipt_path)
                except OSError:
                    ts = None
                result["receipt_reviewed_at"] = _epoch_to_iso(ts) if ts is not None else None
            else:
                result["receipt_reviewed_at"] = obj.get("reviewed_at")
            if ts is not None and result["receipt_head"] == head_sha and ts >= floor:
                result["fresh"] = True

    if os.path.isfile(raw_path):
        try:
            with open(raw_path, "r", errors="replace") as f:
                raw_text = f.read()
        except Exception:
            raw_text = ""
        for candidate in _balanced_objects(raw_text):
            if candidate.get("schema") == SCHEMA:
                result["stdout_object_found"] = True
                result["stdout_decision"] = candidate.get("decision")
                result["stdout_reasons"] = candidate.get("block_reasons") or []
                result["_stdout_object"] = candidate
                break

    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
