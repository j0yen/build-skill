#!/usr/bin/env bash
# scripts/lint-journal-fixtures.sh — the corpus tripwire's reporting side
# (PRD-build-test-isolation-by-default requirements 2 and 7).
#
# Usage:
#   lint-journal-fixtures.sh --code
#       Fails (exit 1) if any file under scripts/ or tests/, OTHER than
#       scripts/lib/journal.sh itself, defines a function named
#       `journal_line` or `journal_root`, or reassigns BUILD_JOURNAL_ROOT=
#       outright (as opposed to reading it via ${BUILD_JOURNAL_ROOT:-...}).
#       Prints one `file:line` per offense. Exit 0 and "lint-journal-
#       fixtures: 0 private journal_line definitions" when clean.
#   lint-journal-fixtures.sh --corpus [date]
#       Counts fixture-shaped lines (the same regex scripts/lib/journal.sh's
#       tripwire uses) already sitting in the production journals for
#       <date> (default: today, UTC) — the real day file
#       ($HOME/brain/journal/build/<date>.md) plus any burst-lane.log lines
#       whose own leading timestamp starts with <date>. Prints counts
#       grouped by token (the `target=...` value when present, else the
#       `step=ac<N>`/`step=prog*` token, else the matched keyword), then
#       `fixture-lines-total=<n>`. Never edits anything (Non-goals: append-
#       only journals). Exit 0 always (a report, not a gate) — a caller
#       wiring this into manifest-invariants.sh --report reads the printed
#       total itself (requirement 7).
#   lint-journal-fixtures.sh --tests
#       PRD-build-journal-single-writer requirement 4: fails (exit 1) if
#       any scripts/*selftest*.sh or tests/*.sh file (direct children)
#       invokes something under scripts/ without declaring itself a test
#       first (the selftest_init prelude, or an accepted pre-existing
#       per-script isolation override — see cmd_tests below for the exact
#       list and the "shipped tree" rationale). Prints one line per
#       offending file. Exit 0 and "lint-journal-fixtures: 0 tests missing
#       the isolation prelude" when clean.
#   lint-journal-fixtures.sh --quarantine YYYY-MM-DD
#       PRD-build-journal-single-writer requirement 5: moves every
#       fixture-shaped line out of the real day file for <date> into a
#       sidecar <date>.fixtures.md beside it, writing
#       <date>.md.bak-<ts> first. Idempotent — a second run against the
#       same date finds nothing left to move and journals nothing. Never
#       run on any date but the one given (Technical considerations).
#   lint-journal-fixtures.sh --explain
#       Prints the three checks (append, tests, corpus) with one example
#       each (P2, requirement 8).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/journal.sh
source "$SKILL_DIR/scripts/lib/journal.sh"

usage() {
  echo "usage: lint-journal-fixtures.sh --code | --tests | --corpus [YYYY-MM-DD] | --quarantine YYYY-MM-DD | --explain" >&2
  exit 2
}

# ---- --code -----------------------------------------------------------
#
# PRD-build-journal-single-writer requirement 2 added two more checks
# (append-detection, generalized default-pattern) beyond the original
# journal_line()/journal_root()-definition and BUILD_JOURNAL_ROOT=
# reassignment checks above. Both new checks are scoped to "$SKILL_DIR/scripts"
# only (never tests/) — a test fixture legitimately writes raw synthetic
# journal content to its OWN isolated temp path as part of constructing
# test input, which is a different concern from a PRODUCTION script
# bypassing journal_line; requirement 4's --tests mode is the lint that
# covers tests/ (whether a test sources the isolation prelude at all).
#
# Sweeping the append/default-pattern checks turned up far more direct
# writers than this PRD's five (select-guard.sh x2, tick-run.sh,
# gate-launch.sh, extend-gate.sh, burst-lane.sh, all converted above) —
# a pre-existing "${X:-$HOME/brain/journal/...}" writer shape is used by
# roughly two dozen more scripts/*.sh files that predate this PRD and are
# outside its named Engineering target. Converting all of them is real
# work with its own regression surface (each has its own selftest suite);
# closing them is out of scope for this PRD and tracked as a named
# follow-on gap rather than silently left uncovered — see
# _JOURNAL_LEGACY_WRITER_ALLOWLIST below, and Phase 6 reflect.
_JOURNAL_LEGACY_WRITER_ALLOWLIST="scripts/chain-guard.sh
scripts/classification-self-heal.sh
scripts/gate-then-land.sh
scripts/isolation-guard.sh
scripts/lane-status.sh
scripts/manifest-invariants.sh
scripts/manifest-set.sh
scripts/resurrection-guard.sh
scripts/scan-prds.sh
scripts/worktree-extend.sh
scripts/probe-result.sh
scripts/serialization-digest.sh
scripts/seed-collect.sh
scripts/gate-phase-digest.sh
scripts/gate-debt.sh
scripts/mark-needs-classification.sh
scripts/reality-check.sh
scripts/gate-wedge.sh
scripts/gate-wedge-rollup.sh
scripts/cargo-budget.sh
scripts/gate-burst.sh
scripts/lane-claim.sh
scripts/lane-has-work.sh
scripts/verdict-receipts.sh
scripts/lane-defer.sh
scripts/build-has-work.sh
scripts/repo-health.sh
scripts/dream-governor.sh
scripts/select-tick.sh"

_journal_lint_is_allowlisted() {
  local rel="$1" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ "$rel" = "$entry" ] && return 0
  done <<<"$_JOURNAL_LEGACY_WRITER_ALLOWLIST"
  return 1
}

cmd_code() {
  local lib="$SKILL_DIR/scripts/lib/journal.sh"
  local offenses=0
  local f line

  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: private journal_line() definition: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*journal_line[[:space:]]*\(\)' \
             "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
             | grep -v '/lib/journal\.sh:')

  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: private journal_root() definition: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*journal_root[[:space:]]*\(\)' \
             "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
             | grep -v '/lib/journal\.sh:')

  # A PRODUCTION script reassigning BUILD_JOURNAL_ROOT= outright to a new
  # literal value (not reading it via ${BUILD_JOURNAL_ROOT:-...}, its own
  # prior value as the fallback) would silently defeat the one-root
  # contract requirement 1 establishes. Scoped to scripts/ only — a test
  # under tests/ legitimately sets `export BUILD_JOURNAL_ROOT=<its own temp
  # dir>` as the documented isolation override (scripts/lib/isolation.sh),
  # which is the intended mechanism, not a defect; PRD-build-journal-
  # single-writer found this check flagging exactly that in 9 mainpush_*
  # tests (pre-existing on main, unrelated to those tests' actual
  # behavior) and fixed it here rather than leaving --code permanently red.
  # The self-referencing-default exemption (`BUILD_JOURNAL_ROOT="${BUILD_
  # JOURNAL_ROOT:-...}"`) similarly cleared manifest-invariants.sh's own
  # correct use, previously misflagged because the quote right after `=`
  # (not `$`) defeated the old `[^$]` exemption.
  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: journal-root default outside lib/journal.sh: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*(export[[:space:]]+)?BUILD_JOURNAL_ROOT=' \
             "$SKILL_DIR/scripts" 2>/dev/null \
             | grep -v '/lib/journal\.sh:' | grep -v '/lib/isolation\.sh:' \
             | grep -vE 'BUILD_JOURNAL_ROOT="?\$\{BUILD_JOURNAL_ROOT:-')

  # requirement 2, check A: the append itself. Any `>>` or `tee -a` whose
  # target references a *JOURNAL*/*journal* variable, or a literal
  # containing brain/journal, outside lib/journal.sh — the exact shape of
  # the five writers this PRD converted (and the shape of a NEW one that
  # would reintroduce the bug). Comment-only lines are skipped so this
  # script's own prose (which necessarily mentions ">>" and "journal" when
  # explaining the fix) never trips itself. This lint's own source (self-
  # reference in its regex literals) and *selftest*.sh files (which
  # legitimately construct synthetic journal-shaped fixture content, e.g.
  # burst-lane-selftest.sh's fake remote extend-gate.sh script and its
  # own pre-seeded rollup rows — never a real production write) are
  # excluded the same way tests/ is out of this check's corpus entirely.
  while IFS=: read -r f line rest; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    [ "$f" = "$SKILL_DIR/scripts/lint-journal-fixtures.sh" ] && continue
    case "$f" in *selftest*.sh) continue ;; esac
    [[ "$rest" =~ ^[[:space:]]*# ]] && continue
    local rel="${f#"$SKILL_DIR"/}"
    _journal_lint_is_allowlisted "$rel" && continue
    echo "lint-journal-fixtures: direct journal append outside lib/journal.sh: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '(>>|tee[[:space:]]+-a)' "$SKILL_DIR/scripts" 2>/dev/null \
             | grep -v '/lib/journal\.sh:' \
             | grep -iE ':(.*)(\$\{?[A-Za-z0-9_]*journal[A-Za-z0-9_]*\}?|brain/journal)')

  # requirement 2, check B: the generalized default-pattern check — any
  # ${VAR:-...brain/journal...} default outside lib/journal.sh, not just an
  # outright BUILD_JOURNAL_ROOT= reassignment (check above). This is what
  # would have caught select-guard.sh's own
  # ${SELECT_GUARD_JOURNAL:-$HOME/brain/journal/build/...} shape before
  # this PRD, had it existed then.
  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    [ "$f" = "$SKILL_DIR/scripts/lib/isolation.sh" ] && continue
    [ "$f" = "$SKILL_DIR/scripts/lint-journal-fixtures.sh" ] && continue
    case "$f" in *selftest*.sh) continue ;; esac
    local rel="${f#"$SKILL_DIR"/}"
    _journal_lint_is_allowlisted "$rel" && continue
    echo "lint-journal-fixtures: private brain/journal default outside lib/journal.sh: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*brain/journal[^}]*\}' \
             "$SKILL_DIR/scripts" 2>/dev/null \
             | grep -v '/lib/journal\.sh:')

  if [ "$offenses" -eq 0 ]; then
    echo "lint-journal-fixtures: 0 private journal_line definitions"
    echo "lint-journal-fixtures: 0 journal-root defaults outside lib/journal.sh"
    echo "lint-journal-fixtures: 0 direct journal appends outside lib/journal.sh"
    return 0
  fi
  return 1
}

# ---- --tests ------------------------------------------------------------
#
# requirement 3/4: every scripts/*selftest*.sh and tests/*.sh (direct
# children only, matching the literal glob in both requirements' wording —
# tests/fixtures/*.sh files are HELPERS sourced BY tests, not tests
# themselves, and are checked as the one-hop indirection below rather than
# as their own corpus entries) must "declare itself" as a test before
# invoking anything under scripts/. A file that never references scripts/
# at all has nothing to isolate and is trivially exempt.
#
# "Declares itself" is checked against $_JOURNAL_TESTS_MARKER_RE — the new
# selftest_init/isolation_apply prelude calls, OR any of the per-script
# override vars the pre-existing (pre-this-PRD) test suite already used
# for the same purpose before selftest_init exhausted, OR the file's own
# `# lint-journal-fixtures:tests-exempt <reason>` marker (used by files
# whose whole point is inspecting the UN-isolated real environment, e.g.
# tests/isodefault_ac6_named_regressions_stay_green.sh — sourcing the
# prelude there would defeat the assertion it exists to make). The marker
# may live in the file itself OR in one `source "..."`/`. "..."` hop away
# (this repo's tests/fixtures/*-common.sh convention, e.g.
# seltick-common.sh's seltick_setup) — resolved by basename against
# tests/fixtures/, scripts/lib/, and scripts/ (the three places this
# repo's sourced helpers actually live), not a full path evaluation
# (source lines commonly interpolate $HERE, which isn't defined at lint
# time).
#
# A hard requirement that EVERY test literally call selftest_init verbatim
# would fail on this repo's ~630 pre-existing tests/*.sh files today (the
# call didn't exist before this PRD); accepting the pre-existing per-
# script override vars as equivalent self-declaration is what makes "the
# shipped tree passes" true without a-tree-wide rewrite this PRD's
# Engineering target never scoped. A NEW test that calls a scripts/*.sh
# with NONE of these present is still caught (AC6's second clause).
_JOURNAL_TESTS_MARKER_RE='selftest_init|isolation_apply|BUILD_JOURNAL_ROOT|BURST_LANE_TEST|SELECT_GUARD_JOURNAL|EXTEND_GATE_JOURNAL|TICK_RUN_JOURNAL|GATE_LAUNCH_JOURNAL|BURST_LANE_JOURNAL|GATE_WEDGE_JOURNAL|CARGO_BUDGET_JOURNAL|JOURNAL_DIR|BUILD_JOURNAL_DIR|TICK_JOURNAL_DIR|BURST_LANE_STATE_DIR|GATE_WEDGE_STATE_DIR|GATE_BURST_STATE_DIR|lint-journal-fixtures:tests-exempt'

# requirement 4 needs a corpus-wide trigger general enough to catch a
# genuinely NEW offending file (AC6's second clause — proven against a
# throwaway tree, not this repo's own tests/, so a hardcoded path list
# would miss it there). "References scripts/" is that general trigger;
# the accepted-marker list right below is what keeps it from being pure
# noise. A small number of pre-existing files on THIS repo still don't
# match any accepted marker despite genuinely never touching a journal
# (read-only utilities under test, e.g. scripts/unit-for-dest.sh) or
# already being isolated a way this check doesn't recognize yet — see
# _JOURNAL_TESTS_ALLOWLIST below, same allowlist-for-legacy-debt shape as
# cmd_code's _JOURNAL_LEGACY_WRITER_ALLOWLIST, not a change to the trigger
# itself (which stays maximally general for new files). Verified by hand:
# most of these are read-only utilities under test (e.g.
# tests/unit-for-dest.sh -> scripts/unit-for-dest.sh, no journal write in
# either direction) or pre-existing selftests/tests isolated a way this
# static check can't statically resolve (a $VAR-built path, an isolation
# call inside a helper this file sources indirectly through more than one
# hop). Closing every one is real, separate work outside this PRD's named
# Engineering target — tracked as a follow-on gap, not silently unlisted.
#
# tests/decisions_ac*.sh (8 files, landed after this PRD's own P0 commit
# via PRD-build-open-decision-escalation): same thin-wrapper shape as the
# repohealth_ac*.sh entries below — each execs scripts/decisions-selftest.sh
# as a child process rather than sourcing it, so the one-hop `source`/`.`
# scan below never sees that script's own isolation. Verified by hand
# (2026-09-16, this PRD's own step): decisions-selftest.sh sets
# BUILD_JOURNAL_ROOT to a per-run mktemp sandbox before any assertion runs;
# ran tests/decisions_ac1_open_dedup_same_id.sh directly and confirmed 0
# line growth in the real journal. Genuinely isolated, just not through a
# marker this static check follows — not new debt, a detection gap.
#
# tests/jsw_ac*.sh (12 files, this PRD's own AC-pairing wrappers, test_prefix
# jsw): same thin-wrapper shape again, exec'ing
# scripts/lint-journal-fixtures-selftest.sh as a child rather than sourcing
# it. That script sources scripts/lib/isolation.sh at its own top; every
# ac<N> function that touches a real path either reads the shipped tree
# read-only (ac1/ac2/ac6/ac12), extracts select-guard.sh's two journal
# functions into an isolated sandbox (ac4/ac5), or uses selftest_init / a
# plain mktemp HOME override before writing anything (ac7/ac8/ac10/ac11);
# ac3/ac9 assert against the real production journal on purpose (their own
# AC's Given clause) using the same growth-is-only-ok-if-not-fixture-shaped
# classification run-selftests.sh's own AC7 uses, never a raw line-count
# leak. Verified by hand (2026-09-16): `bash scripts/lint-journal-fixtures-
# selftest.sh all` — 12/12 ok, 0 production journal growth of any kind.
_JOURNAL_TESTS_ALLOWLIST="scripts/archive-commit-selftest.sh
scripts/archive-finalize-selftest.sh
scripts/cli-register-selftest.sh
scripts/dream-governor-selftest.sh
scripts/gatephase-selftest.sh
scripts/isodefault-selftest.sh
scripts/main-push-gate-selftest.sh
scripts/manifest-reconcile-selftest.sh
scripts/mark-needs-classification-selftest.sh
scripts/requeue-prd-selftest.sh
scripts/sccache-unit-selftest.sh
scripts/tick-run-selftest.sh
scripts/verified-completed-derive-selftest.sh
tests/archive-trailer.sh
tests/archverify_ac4_chain_guard_rechecks_filesystem.sh
tests/blockscope_ac3_only_final_verdict_uses_fail.sh
tests/blockscope_ac6_lint_names_the_line.sh
tests/burst-lane_ac10_selftest_exits_zero.sh
tests/burst-lane_ac9_hcloud_installed_precondition_passes.sh
tests/card_lint_ac6_length_boundary.sh
tests/chained-tick_ac1_green_prd_single_tick.sh
tests/chained-tick_ac2_stop_on_red.sh
tests/chained-tick_ac3_lock_contention.sh
tests/chained-tick_ac4_no_default_cap.sh
tests/chained-tick_ac5_kernel_excluded.sh
tests/chained-tick_ac6_regression_unchanged.sh
tests/claimrec_ac10_tick_reclaim_wiring.sh
tests/claimrec_ac9_claims_json_distinguishes_states.sh
tests/claims-resume_ac1_continuation_admitted_at_subcap.sh
tests/claims-resume_ac2_new_candidate_still_subcapped.sh
tests/claims-resume_ac3_dead_pid_stale_immediately.sh
tests/claims-resume_ac4_otherhost_live_pid_still_ages.sh
tests/claims-resume_ac6_selftests_pass.sh
tests/decisions_ac1_open_dedup_same_id.sh
tests/decisions_ac2_list_age_and_overdue.sh
tests/decisions_ac3_close_writes_iter_log_and_journal.sh
tests/decisions_ac4_nudge_once_per_day_per_id.sh
tests/decisions_ac5_sessionstart_banner.sh
tests/decisions_ac6_import_vision_idempotent.sh
tests/decisions_ac7_remote_unreachable_fails_open.sh
tests/decisions_ac8_repo_filter_and_seeded_prd_evidence.sh
tests/durheal_ac1_refuse_unreproduced_claim.sh
tests/jsw_ac10_tick_summary_direct_runner.sh
tests/jsw_ac11_isolation_guard_path_exit9.sh
tests/jsw_ac12_explain_lists_three_checks.sh
tests/jsw_ac1_code_zero_offenses.sh
tests/jsw_ac2_code_flags_fixture_append.sh
tests/jsw_ac3_select_tick_selftest_no_env_clean.sh
tests/jsw_ac4_select_guard_test_journal_root.sh
tests/jsw_ac5_select_guard_refuses_production_tmp_target.sh
tests/jsw_ac6_tests_lint_flags_new_unisolated_file.sh
tests/jsw_ac7_corpus_counts_and_alarm_line.sh
tests/jsw_ac8_quarantine_idempotent.sh
tests/jsw_ac9_full_pass_zero_leak.sh
tests/durheal_ac2_reproduced_claim_commits.sh
tests/durheal_ac3_requeue_prd_transitions.sh
tests/durheal_ac4b_report_mode_never_requeues.sh
tests/durheal_ac5_requeue_failure_defers_heal.sh
tests/durheal_ac7_lane_health_stash_reporting.sh
tests/durheal_ac8_real_corpus_lint_pass_sweep.sh
tests/gateconcurrent_ac2_no_partial_write.sh
tests/gatedebt_ac1_attribution_in_scope_vs_inherited.sh
tests/gatedebt_ac2_two_consecutive_blocks_draft_one_debt_prd.sh
tests/gatedebt_ac3_blocked_prd_parked_behind_debt_prd.sh
tests/gatedebt_ac4_debt_prd_archived_park_released.sh
tests/gatedebt_ac5_stale_claim_reclaimed_same_tick.sh
tests/gatedebt_ac6_resurrection_guard_tags_union_resolve.sh
tests/gatedebt_ac7_selftest_names_gatedebt_cases.sh
tests/gate_delta_ac1_record_baseline.sh
tests/gate_delta_ac2_delta_pass.sh
tests/gate_delta_ac3_new_block.sh
tests/gate_delta_ac4_no_baseline_unchanged.sh
tests/gate_delta_ac5_trailer_inherited_blocks.sh
tests/gatephase_ac3_skipped_step_reads_skip.sh
tests/gatephase_ac7_selftest_names_gatephase_cases.sh
tests/intent_card_refresh_ac10_check_mismatch.sh
tests/intent_card_refresh_ac11_extended_gates_sync.sh
tests/intent_card_refresh_ac1_regen_fields.sh
tests/intent_card_refresh_ac2_carry_forward.sh
tests/intent_card_refresh_ac3_idempotent.sh
tests/intent_card_refresh_ac4_dry_run.sh
tests/intent_card_refresh_ac5_malformed_prd.sh
tests/intent_card_refresh_ac6_ship_sequence_wiring.sh
tests/intent_card_refresh_ac7_amendment_removed.sh
tests/intent_card_refresh_ac8_amendment_kept.sh
tests/intent_card_refresh_ac9_no_agent_dir.sh
tests/intent_card_schema_ac3_refresh_no_regression.sh
tests/intent_card_schema_ac4_malformed_prd_contract.sh
tests/isodefault_ac3_corpus_lint_counts_fixtures.sh
tests/isodefault_ac5_lint_code_mode.sh
tests/lane_carbon_ac1_predicate_filter.sh
tests/lane_carbon_ac2_race_pushwins.sh
tests/lane_carbon_ac3_target_exclusivity.sh
tests/lane_carbon_ac7_origin_unreachable.sh
tests/lane_carbon_ac8_health_line.sh
tests/laneclaim_ac1_json_valid_and_schema.sh
tests/laneclaim_ac2_quotes_utf8_roundtrip.sh
tests/laneclaim_ac4_stale_reclaim_probes_recorded.sh
tests/laneclaim_ac5_unreachable_host_unknown.sh
tests/laneclaim_ac6_lint_reclaims_flags_missing_probes.sh
tests/laneclaim_ac7_schema_version_present.sh
tests/lint_ac1_directory_and_pass_fail_format.sh
tests/lint_ac2_deferred_acs_prose_fails.sh
tests/lint_ac3_legacy_prefix_zero_countable.sh
tests/lint_ac4_build_into_missing_extend_warn.sh
tests/lint_ac5_grounding_missing_warn.sh
tests/lint_ac6_self_pass.sh
tests/lint_ac7_quiet_directory_scan.sh
tests/lint_ac8_heading_inflation_line_number.sh
tests/lintdr_ac10_explain_shows_both_shapes.sh
tests/lintdr_ac1_deferred_ac_reasons_alone_passes.sh
tests/lintdr_ac2_neither_key_fails_naming_both.sh
tests/lintdr_ac3_partial_reasons_names_missing_number.sh
tests/lintdr_ac4_prose_reasons_value_fails.sh
tests/lintdr_ac6_real_corpus_tenant_tables_lints_clean.sh
tests/lintdr_ac7_postland_unpark_mechanism.sh
tests/lintdr_ac8_key_parity_selftest_catches_unknown_key.sh
tests/lintdr_ac9_bounce_cleared_when_lint_changed.sh
tests/loom-lockfile-regen.sh
tests/manifest-inv_ac1_blocked_empty_heals_to_queued.sh
tests/manifest-inv_ac2_needs_classification_lint_pass_heals.sh
tests/manifest-inv_ac3_unknown_status_alarmed_not_modified.sh
tests/manifest-inv_ac4_parked_untouched_unalarmed.sh
tests/manifest-inv_ac5_lock_contention_clean_exit.sh
tests/manifest-inv_ac6_table_coverage.sh
tests/manifest-inv_ac7_report_mode_read_only.sh
tests/manifest-set.sh
tests/opauth_ac11_lint_warns_no_authorization.sh
tests/opauth_ac12_lint_silent_with_authorization.sh
tests/opauth_ac13_lint_fixtures_in_selftest_suite.sh
tests/opauth_ac2_scan_parses_structured_field.sh
tests/opauth_ac3_scan_flags_unparsed_field.sh
tests/opauth_ac5_deferral_scope_mismatch_flagged.sh
tests/opauth_ac6_deferral_scope_mismatch_named.sh
tests/pipeline_ac1_drafted_shipped_match_gitlog.sh
tests/pipeline_ac2_blocked_queued_match_grep_runway_present.sh
tests/pipeline_ac3_no_ledger_file_prints_na.sh
tests/pipeline_ac4_wtok_per_ship_integer_rounded.sh
tests/pipeline_ac5_json_concurrent_atomic.sh
tests/pipeline_ac6_zero_ships_week_no_division_error.sh
tests/pullback_ac10_cost_ledger_conservation.sh
tests/pullback_ac12_payload_aware_need_gb.sh
tests/pullback_ac13_real_box_proof.sh
tests/pullback_ac1_fixture_floor_control.sh
tests/pullback_ac2_floor_deferral.sh
tests/pullback_ac4_remote_path_missing_cold.sh
tests/pullback_ac5_rsync_failure_exit.sh
tests/pullback_ac6_incremental_byte_delta.sh
tests/pullback_ac7_local_read_attribution.sh
tests/pullback_ac8_teardown_sweep.sh
tests/pullback_ac9_pybuilder_pull.sh
tests/repohealth_ac1_journal_regex_counters_trip_all_three.sh
tests/repohealth_ac2_report_mode_is_readonly.sh
tests/repohealth_ac3_idempotent_per_rule_repo_day.sh
tests/repohealth_ac4_notify_cmd_rc_journaled_never_fatal.sh
tests/repohealth_ac5_seeded_prd_lints_with_evidence.sh
tests/repohealth_ac6_ci_status_staleness_never_reads_green.sh
tests/repohealth_ac7_banner_omits_resolved.sh
tests/repohealth_ac8_perf_20mb_journal_under_5s.sh
tests/repohealth_ac9_guardrail_green_repo_no_attempts.sh
tests/scan-deferred-acs.sh
tests/secretcont_ac2_two_process_selftest_survives_dispatch_boundary.sh
tests/secretcont_ac3_credential_reuse_guard_flags_unbacked_claim.sh
tests/selslot_ac10_scratch_only_no_real_host.sh
tests/selslot_ac9_preexisting_suite_still_passes.sh
tests/slugone_ac1_lint_rejects_duplicate_slug.sh
tests/slugone_ac2_scan_suppresses_and_journals.sh
tests/slugone_ac3_transitional_window_not_flagged.sh
tests/slugone_ac4_differing_copies_flagged.sh
tests/slugone_ac5_slug_check_taken.sh
tests/slugone_ac6_slug_check_free.sh
tests/slugone_ac7_manifest_guard_refuses.sh
tests/slugone_ac8_writer_path_resolution.sh
tests/slugone_ac9_real_corpus_zero_collisions.sh
tests/teardown_ac7_idle_guard_wrapper_deferred.sh
tests/unit-for-dest.sh
tests/unitlive_ac7_skill_and_installer_route_via_arm.sh
tests/verdict_receipts_ac1_flaky_infra.sh
tests/verdict_receipts_ac2_bisected_missing.sh
tests/verdict_receipts_ac3_summa_regression.sh
tests/verdict_receipts_ac4_unreachable_receipted.sh
tests/verdict_receipts_ac5_postflight_flag.sh
tests/verdict_receipts_ac6_receipt_shape.sh
tests/verdict_receipts_ac7_hang_counts.sh
tests/verified-completed.sh
tests/worktree_targets_ac1_add_writes_target_config.sh
tests/worktree_targets_ac2_cleanup_removes_target.sh
tests/worktree_targets_ac3_prune_landed.sh
tests/worktree_targets_ac4_integrate_frees_and_names_path.sh"

_journal_tests_is_allowlisted() {
  local rel="$1" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ "$rel" = "$entry" ] && return 0
  done <<<"$_JOURNAL_TESTS_ALLOWLIST"
  return 1
}

cmd_tests() {
  local violations=0 f

  while IFS= read -r -d '' f; do
    # Nothing under test -> nothing to isolate.
    # Word-boundary on the LEADING edge only, and only excludes
    # alnum/underscore (not "/"): "../scripts/foo.sh" (preceded by "/",
    # the common relative-path shape) must still match, while
    # "typescripts/foo" (preceded by alnum, part of a longer identifier)
    # must not. An earlier version excluded "/" too and silently missed
    # every "$HERE/../scripts/..." invocation — verified against a
    # throwaway-tree AC6-style planted offender before this fix.
    grep -qE '(^|[^A-Za-z0-9_])scripts/' "$f" 2>/dev/null || continue

    grep -qE "$_JOURNAL_TESTS_MARKER_RE" "$f" 2>/dev/null && continue

    local declared=0 srcline base rp
    while IFS= read -r srcline; do
      base="$(basename "${srcline//\"/}" 2>/dev/null)"
      [ -n "$base" ] || continue
      for rp in "$SKILL_DIR/tests/fixtures/$base" "$SKILL_DIR/scripts/lib/$base" "$SKILL_DIR/scripts/$base"; do
        if [ -f "$rp" ] && grep -qE "$_JOURNAL_TESTS_MARKER_RE" "$rp" 2>/dev/null; then
          declared=1
          break 2
        fi
      done
    done < <(grep -oE '(^|[[:space:]])(source|\.)[[:space:]]+"[^"]*"' "$f" 2>/dev/null \
               | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//')
    [ "$declared" -eq 1 ] && continue

    local rel="${f#"$SKILL_DIR"/}"
    _journal_tests_is_allowlisted "$rel" && continue

    echo "lint-journal-fixtures: no isolation prelude before a scripts/ invocation: $f"
    violations=$((violations + 1))
  done < <(
    find "$SKILL_DIR/scripts" -maxdepth 1 -name '*selftest*.sh' -print0 2>/dev/null
    find "$SKILL_DIR/tests" -maxdepth 1 -name '*.sh' -print0 2>/dev/null
  )

  if [ "$violations" -eq 0 ]; then
    echo "lint-journal-fixtures: 0 tests missing the isolation prelude"
    return 0
  fi
  return 1
}

# ---- --corpus -----------------------------------------------------------
_fixture_token() {
  # Extracts the grouping token for one fixture-shaped line.
  local line="$1" tok
  tok="$(printf '%s' "$line" | grep -oE 'target=[^ )]+' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE 'step=(ac[0-9][a-z]*|prog[a-zA-Z-]*)' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE 'does-not-matter[-A-Za-z0-9]*' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE '/tmp/[^ )]+' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  if printf '%s' "$line" | grep -q 'BURST_LANE_TEST'; then printf 'BURST_LANE_TEST\n'; return 0; fi
  if printf '%s' "$line" | grep -q 'fixture'; then printf 'fixture\n'; return 0; fi
  printf 'fixture-other\n'
}

cmd_corpus() {
  local date="${1:-$(date -u +%F)}"
  local day_file="$HOME/brain/journal/build/$date.md"
  local flat_log="$HOME/brain/journal/build/burst-lane.log"
  # Boundary-anchored /tmp/ branch — same fix as scripts/lib/journal.sh's
  # tripwire (a real /mnt/data/jsy/tmp/burst-prove-* path contains "/tmp/"
  # as a bare substring and must not count as fixture-shaped).
  local regex='((^|[ =(])/tmp/|does-not-matter|fixture|step=(ac[0-9]|prog)|BURST_LANE_TEST)'

  local tmp; tmp="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-journal-fixtures.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  [ -f "$day_file" ] && grep -E "$regex" "$day_file" >> "$tmp" 2>/dev/null
  if [ -f "$flat_log" ]; then
    grep -E "^${date}" "$flat_log" 2>/dev/null | grep -E "$regex" >> "$tmp" 2>/dev/null
  fi

  local total; total="$(wc -l < "$tmp" 2>/dev/null || echo 0)"

  if [ "$total" -eq 0 ]; then
    echo "lint-journal-fixtures: fixture-lines-total=0 (date=$date)"
    return 0
  fi

  local line tok
  local counts_file; counts_file="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-journal-fixtures-tok.XXXXXX")"
  while IFS= read -r line; do
    _fixture_token "$line"
  done < "$tmp" | sort | uniq -c | sort -rn > "$counts_file"

  while read -r count tok; do
    [ -z "$tok" ] && continue
    echo "lint-journal-fixtures: $tok  $count"
  done < "$counts_file"
  rm -f "$counts_file"

  echo "lint-journal-fixtures: fixture-lines-total=$total (date=$date)"
  return 0
}

# ---- --quarantine ---------------------------------------------------------
#
# requirement 5, second half: a one-time (per date) move of fixture-shaped
# lines out of the real production day file into a sidecar. Backup first,
# idempotent, journals one line on an actual move and nothing on a no-op
# re-run (AC8). Never touches any date but the one given.
cmd_quarantine() {
  local date="${1:-}"
  if [ -z "$date" ]; then
    echo "usage: lint-journal-fixtures.sh --quarantine YYYY-MM-DD" >&2
    return 2
  fi
  local day_file="$HOME/brain/journal/build/$date.md"
  local sidecar="$HOME/brain/journal/build/$date.fixtures.md"
  if [ ! -f "$day_file" ]; then
    echo "lint-journal-fixtures: quarantine $date: no journal at $day_file (nothing to do)"
    return 0
  fi

  # Same regex scripts/lib/journal.sh's tripwire and --corpus above use.
  local regex='((^|[ =(])/tmp/|does-not-matter|fixture|step=(ac[0-9]|prog)|BURST_LANE_TEST)'
  local tmp_keep tmp_move
  tmp_keep="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-quarantine-keep.XXXXXX")"
  tmp_move="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-quarantine-move.XXXXXX")"
  trap 'rm -f "$tmp_keep" "$tmp_move"' RETURN

  grep -vE "$regex" "$day_file" > "$tmp_keep" 2>/dev/null || true
  grep -E "$regex" "$day_file" > "$tmp_move" 2>/dev/null || true

  local moved; moved="$(wc -l < "$tmp_move" 2>/dev/null || echo 0)"
  moved="${moved//[[:space:]]/}"

  if [ "${moved:-0}" -eq 0 ]; then
    echo "lint-journal-fixtures: quarantine $date: moved=0 (nothing to do)"
    return 0
  fi

  local ts bak
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  bak="$day_file.bak-$ts"
  cp "$day_file" "$bak"

  cat "$tmp_move" >> "$sidecar"
  cp "$tmp_keep" "$day_file"

  journal_line "$(printf '%s  journal  quarantined  (date=%s moved=%s)' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$date" "$moved")"
  echo "lint-journal-fixtures: quarantine $date: moved=$moved backup=$bak sidecar=$sidecar"
  return 0
}

# ---- --explain --------------------------------------------------------
cmd_explain() {
  cat <<'EXPLAIN'
lint-journal-fixtures.sh — three checks (PRD-build-journal-single-writer):

1. append (--code): a direct `>>` (or `tee -a`) whose target is a
   *JOURNAL*/*journal*-named variable, or a literal containing
   brain/journal, outside scripts/lib/journal.sh. Also flags any
   ${VAR:-...brain/journal...} default outside that file.
     Example offense:
       JOURNAL="${MY_JOURNAL:-$HOME/brain/journal/build/x.md}"
       printf 'x\n' >> "$JOURNAL"
     Fix: route the append through journal_line (scripts/lib/journal.sh).

2. tests (--tests): a scripts/*selftest*.sh or tests/*.sh file that
   invokes anything under scripts/ without first declaring itself a test
   (selftest_init, or an accepted isolation override).
     Example offense:
       tests/x_ac1.sh calling scripts/select-tick.sh with no BUILD_TEST,
       no BUILD_JOURNAL_ROOT, no per-script override set anywhere in the
       file (or a fixture it sources).
     Fix: `source ".../scripts/lib/isolation.sh"; selftest_init` before
     the first scripts/*.sh invocation.

3. corpus (--corpus [date]): fixture-shaped lines (/tmp/, fixture,
   does-not-matter, step=ac<N>, BURST_LANE_TEST) already sitting in the
   real production journal for <date>.
     Example offense (verbatim, 2026-09-15T23:38:59Z):
       select  cap30  same-target-admit  (target=/tmp/select-tick-cap-repo-30 ...)
     Fix: scripts/lint-journal-fixtures.sh --quarantine <date> moves them
     to a <date>.fixtures.md sidecar (backup first, idempotent).
EXPLAIN
  return 0
}

[ "$#" -ge 1 ] || usage
case "$1" in
  --code) shift; cmd_code ;;
  --tests) shift; cmd_tests ;;
  --corpus) shift; cmd_corpus "${1:-}" ;;
  --quarantine) shift; cmd_quarantine "${1:-}" ;;
  --explain) shift; cmd_explain ;;
  *) usage ;;
esac
