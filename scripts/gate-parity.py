#!/usr/bin/env python3
# gate-parity.py — the aggregation engine behind `gate-status.sh --parity`
# (PRD-build-gate-route-parity-ledger, R3/R7/R8/R9). Reads tick journal
# `gate` lines on stdin (one or more concatenated journal .md files — the
# caller resolves which files, this script only parses lines) and prints a
# producer x route table: runs, pass, block, pass_rate, last_block_ts.
#
# A "producer" here is a name in a gate line's own `phases=<name>:<val>,...`
# field (PRD-build-gate-phase-timing) minus the aggregate `gate` phase
# itself and the `unattributed` bookkeeping entry phases_field sometimes
# appends — the 8 named gate steps plus the 17-producer `receipts`
# aggregate (extended-receipts.sh's own per-file granularity lives in
# target/autobuilder/receipts/*.json, not in the journal; this ledger
# reports at journal granularity, same as every other --parity consumer).
# `val`: `skip` -> this run never invoked the producer, excluded entirely;
# `defer` -> counted as a pass (a scope-deferred receipt is rewritten to
# pass on disk before `autobuilder gate` reads it — functionally a pass by
# the time the aggregate verdict is computed); a trailing `!` -> block;
# anything else (a plain second count) -> pass.
#
# Route is read once per line from that line's own `route=<value>` field
# (added by this same PRD) and applied to every producer parsed from that
# line — GATE_ROUTE is one decision for the whole gate run (extend-gate.sh
# resolves it once via cargo_route_current(), before producer 1 runs), so
# there is no per-producer route to disagree with it. A line with no
# `route=` field at all (Migration/compatibility: written before this PRD
# landed) is bucketed under `route=unknown` and left out of --diff-local's
# local-vs-burst comparison (unknown is neither).
import sys
import re
import json

LINE_RE = re.compile(
    r'^(?P<ts>\S+)\s+gate\s+(?P<crate>\S+)\s+(?P<outcome>pass|block|delta-pass)\s+\((?P<body>.*)\)'
)


def parse_args(argv):
    opts = {
        "since": None,
        "producer": None,
        "json": False,
        "min_runs": 3,
        "diff_local": False,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--since":
            opts["since"] = argv[i + 1]
            i += 2
        elif a == "--producer":
            opts["producer"] = argv[i + 1]
            i += 2
        elif a == "--json":
            opts["json"] = True
            i += 1
        elif a == "--min-runs":
            opts["min_runs"] = int(argv[i + 1])
            i += 2
        elif a == "--diff-local":
            opts["diff_local"] = True
            i += 1
        else:
            i += 1
    return opts


def collect(lines, opts):
    producers = {}  # (name, route) -> {runs, pass, block, last_block_ts}
    for raw in lines:
        line = raw.rstrip("\n")
        m = LINE_RE.match(line)
        if not m:
            continue
        ts = m.group("ts")
        if opts["since"] and ts < opts["since"]:
            continue
        body = m.group("body")
        phases_m = re.search(r"phases=([^\s)]+)", body)
        if not phases_m:
            continue
        route_m = re.search(r"route=([^\s)]+)", body)
        route = route_m.group(1) if route_m else "unknown"
        for pair in phases_m.group(1).split(","):
            if ":" not in pair:
                continue
            name, val = pair.split(":", 1)
            # "gate" is the aggregate tally, not a producer; "unattributed"
            # and "route-stamp" are extend-gate.sh's own bookkeeping
            # phases (phase-timing accounting and this PRD's receipt-
            # stamp sweep, respectively) — neither is one of the 25 gate
            # producers a parity report attributes a block to.
            if name in ("gate", "unattributed", "route-stamp"):
                continue
            if opts["producer"] and name != opts["producer"]:
                continue
            if val == "skip":
                continue
            key = (name, route)
            rec = producers.setdefault(
                key, {"runs": 0, "pass": 0, "block": 0, "last_block_ts": None}
            )
            rec["runs"] += 1
            if val.endswith("!"):
                rec["block"] += 1
                if rec["last_block_ts"] is None or ts > rec["last_block_ts"]:
                    rec["last_block_ts"] = ts
            else:
                rec["pass"] += 1
    return producers


def to_rows(producers, min_runs):
    rows = []
    for (name, route), rec in producers.items():
        runs = rec["runs"]
        passn = rec["pass"]
        blockn = rec["block"]
        rate = round(passn / runs, 4) if runs else 0.0
        rows.append(
            {
                "producer": name,
                "route": route,
                "runs": runs,
                "pass": passn,
                "block": blockn,
                "pass_rate": rate,
                "last_block_ts": rec["last_block_ts"] or "",
                "eligible_for_worst": runs >= min_runs,
            }
        )
    rows.sort(key=lambda r: (r["producer"], r["route"]))
    return rows


def diff_local_rows(rows, min_runs):
    by_prod = {}
    for r in rows:
        by_prod.setdefault(r["producer"], {})[r["route"]] = r
    out = []
    for prod, byroute in sorted(by_prod.items()):
        local_r = byroute.get("local")
        if not local_r or local_r["runs"] < min_runs:
            continue
        for route, r in sorted(byroute.items()):
            if not route.startswith("burst:"):
                continue
            if r["runs"] < min_runs:
                continue
            delta = local_r["pass_rate"] - r["pass_rate"]
            if delta > 0.15:
                out.append(
                    {
                        "producer": prod,
                        "local_pass_rate": local_r["pass_rate"],
                        "route": route,
                        "route_pass_rate": r["pass_rate"],
                        "delta": round(delta, 4),
                    }
                )
    return out


def main():
    opts = parse_args(sys.argv[1:])
    producers = collect(sys.stdin, opts)
    rows = to_rows(producers, opts["min_runs"])

    if opts["diff_local"]:
        out = diff_local_rows(rows, opts["min_runs"])
        if opts["json"]:
            print(json.dumps(out))
        else:
            if not out:
                print(
                    "gate-status --parity --diff-local: no producer regressed "
                    ">0.15 vs local (min-runs=%d)" % opts["min_runs"]
                )
            for o in out:
                print(
                    "%s: local=%.2f %s=%.2f delta=%.2f"
                    % (
                        o["producer"],
                        o["local_pass_rate"],
                        o["route"],
                        o["route_pass_rate"],
                        o["delta"],
                    )
                )
        return 0

    if opts["json"]:
        print(json.dumps(rows))
        return 0

    if not rows:
        print("gate-status --parity: no matching gate lines")
        return 0

    print(
        "%-22s %-16s %5s %5s %6s %9s %s"
        % ("producer", "route", "runs", "pass", "block", "pass_rate", "last_block_ts")
    )
    for r in rows:
        print(
            "%-22s %-16s %5d %5d %6d %9.2f %s"
            % (
                r["producer"],
                r["route"],
                r["runs"],
                r["pass"],
                r["block"],
                r["pass_rate"],
                r["last_block_ts"] or "-",
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
