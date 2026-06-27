#!/bin/bash
# run_suite.sh — single test-suite lifecycle (prepare → run → parse → coverage).
#
# This file is SOURCED (not executed) by run_coverage.sh so that the
# PASS / FAIL variables it sets are visible to the caller.
#
# Expected inputs (set by caller before sourcing):
#   suite_id, display_name, type, runner_path, runner_args
#
# Expected globals already defined:
#   CATALOG_REPO, COV_DIR, LOG_DIR, SQL_OUT_DIR, RESULTS_DIR
#   DATADIR, PORT, GCOVR_OPTIONS, VERBOSE, SKIP_DB_RESTART

run_one_suite() {
    local suite_id="$1"
    local display_name="$2"
    local type="$3"
    local runner_path="$4"
    local runner_args="$5"

    # ── 1. Create output directories ─────────────────────────────────────
    ensure_dir "$COV_DIR/$suite_id"
    ensure_dir "$SQL_OUT_DIR/$suite_id"
    ensure_dir "$LOG_DIR"

    # ── 2. Prepare: clean gcda baseline, start DB if needed ──────────────
    if [ "$SKIP_DB_RESTART" != "true" ]; then
        case "$type" in
            sql_script)
                gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>/dev/null || true
                sleep 1
                clean_gcda
                mkdir -p /tmp/iceberg_warehouse
                gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
                sleep 1
                ;;
            binary)
                clean_gcda
                ;;
        esac
    fi

    # ── 3. Run the test ──────────────────────────────────────────────────
    local runner_log="$LOG_DIR/${suite_id}_runner.log"
    local runner_full="$CATALOG_REPO/test/$runner_path"
    local runner_exit=0

    # Temporarily disable set -e; test failures are expected and handled below.
    set +e
    if [ "$VERBOSE" = true ]; then
        case "$type" in
            sql_script)
                (cd "$CATALOG_REPO" && bash "$runner_full" $runner_args) 2>&1 | tee "$runner_log"
                runner_exit="${PIPESTATUS[0]}"
                ;;
            binary)
                "$runner_full" $runner_args 2>&1 | tee "$runner_log"
                runner_exit="${PIPESTATUS[0]}"
                ;;
        esac
    else
        case "$type" in
            sql_script)
                (cd "$CATALOG_REPO" && bash "$runner_full" $runner_args) > "$runner_log" 2>&1
                runner_exit=$?
                ;;
            binary)
                "$runner_full" $runner_args > "$runner_log" 2>&1
                runner_exit=$?
                ;;
        esac
    fi
    set -e

    # ── 4. Parse pass/fail from runner output ────────────────────────────
    parse_pass_fail "$runner_log" "$runner_exit"
    # Now $PASS and $FAIL are set in the parent scope (this file is sourced)

    # Print result
    if [ "$FAIL" -eq 0 ]; then
        echo -e "  ${COLOR_GREEN}${PASS} passed${COLOR_RESET}, ${COLOR_RED}${FAIL} failed${COLOR_RESET}"
    else
        echo -e "  ${COLOR_RED}${PASS} passed, ${FAIL} failed${COLOR_RESET}"
        if [ "$VERBOSE" = true ]; then
            grep -E "✗|FAIL|ERROR" "$runner_log" | tail -20 || true
        fi
    fi

    # ── 5. Flush + archive gcda ──────────────────────────────────────────
    if [ "$SKIP_DB_RESTART" != "true" ] && [ "$type" = "sql_script" ]; then
        gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>&1 | tail -1
        sleep 1
    fi

    archive_gcda "$suite_id"

    # ── 6. Generate coverage report ──────────────────────────────────────
    generate_coverage_report "$suite_id" || true
    local_cov_pct="${SUITE_COV_PCT:-N/A}"

    # ── 7. Copy test artifacts ────────────────────────────────────────────
    case "$type" in
        sql_script)
            # run_tests.sh         → test/results/
            # run_concurrency_tests.sh → test/concurrent/results/
            if [ -d "$CATALOG_REPO/test/results" ]; then
                cp -r "$CATALOG_REPO/test/results/"* "$SQL_OUT_DIR/$suite_id/" 2>/dev/null || true
            fi
            if [ -d "$CATALOG_REPO/test/concurrent/results" ]; then
                cp -r "$CATALOG_REPO/test/concurrent/results/"* "$SQL_OUT_DIR/$suite_id/" 2>/dev/null || true
            fi
            log_info "测试输出已复制到: $SQL_OUT_DIR/$suite_id/"
            ;;
    esac

    # ── 8. Clean gcda for next suite ─────────────────────────────────────
    clean_gcda

    # Return suite result as global-ish variables (caller reads $PASS, $FAIL, $cov_pct)
}

# ── Pass/fail parsing (cascading regex, ordered by specificity) ───────────

parse_pass_fail() {
    local log_file="$1"
    local exit_code="$2"

    PASS=0
    FAIL=0

    # Priority 1: "X passed, Y failed"  (run_tests.sh / run_concurrency_tests.sh)
    local p f
    p=$(grep -oP '\d+(?= passed)' "$log_file" 2>/dev/null | tail -1 || true)
    f=$(grep -oP '\d+(?= failed)' "$log_file" 2>/dev/null | tail -1 || true)
    if [ -n "$p" ] || [ -n "$f" ]; then
        PASS="${p:-0}"
        FAIL="${f:-0}"
        return 0
    fi

    # Priority 2: gtest format  "[  PASSED  ] X tests." / "Y FAILED TESTS"
    local total tests_failed
    total=$(grep -oP '\[\s*==========\s*\]\s*\K\d+(?= tests? from)' "$log_file" 2>/dev/null || true)
    tests_failed=$(grep -oP '\[\s*FAILED\s*\]\s*\K\d+(?= tests?)' "$log_file" 2>/dev/null || true)
    if [ -n "$total" ]; then
        PASS=$(( total - ${tests_failed:-0} ))
        FAIL="${tests_failed:-0}"
        return 0
    fi

    # Priority 3: fallback — exit code
    if [ "$exit_code" -eq 0 ]; then
        PASS=1
        FAIL=0
    else
        PASS=0
        FAIL=1
    fi
}
