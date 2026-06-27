#!/bin/bash
# coverage.sh — gcda management and gcovr report generation utilities.
#
# This file is sourced by run_coverage.sh and run_suite.sh.
# It expects the following variables to already be set:
#   CATALOG_REPO, COV_DIR, LOG_DIR, GCOVR_OPTIONS

# ── gcda management ───────────────────────────────────────────────────────

# Remove all .gcda files from the Catalog source directory.
clean_gcda() {
    rm -f "$CATALOG_REPO"/src/*.gcda
}

# Archive .gcda files for a suite and symlink .gcno files so gcovr
# can resolve the source-to-object mapping from a snapshot directory.
archive_gcda() {
    local suite_id="$1"
    local snapshot_dir="$RESULTS_DIR/gcda_snapshots/$suite_id"

    if ! ls "$CATALOG_REPO"/src/*.gcda > /dev/null 2>&1; then
        return 0
    fi

    ensure_dir "$snapshot_dir"

    # Copy .gcda coverage data
    cp "$CATALOG_REPO"/src/*.gcda "$snapshot_dir/" 2>/dev/null || true

    # Symlink .gcno notes files so gcovr can resolve when pointed at the snapshot
    for gcno in "$CATALOG_REPO"/src/*.gcno; do
        [ -f "$gcno" ] && ln -sf "$gcno" "$snapshot_dir/$(basename "$gcno")" 2>/dev/null || true
    done

    log_info "gcda archived: $snapshot_dir/"
}

# Check whether any .gcda files exist in the Catalog source directory.
has_gcda() {
    ls "$CATALOG_REPO"/src/*.gcda > /dev/null 2>&1
}

# ── gcovr report generation ───────────────────────────────────────────────

# Generate an HTML coverage report for a suite.
# Arguments: suite_id (e.g. "serial", "concurrency", "combined")
# Sets global: SUITE_COV_PCT (line coverage percentage, or "N/A")
generate_coverage_report() {
    local suite_id="$1"
    local report_dir="$COV_DIR/$suite_id"

    SUITE_COV_PCT="N/A"
    ensure_dir "$report_dir"

    if ! has_gcda; then
        log_warn "未找到 .gcda 文件，跳过覆盖率报告: $suite_id"
        return 1
    fi

    local gcovr_log="$LOG_DIR/${suite_id}_gcovr.log"
    local summary_file="$LOG_DIR/${suite_id}_coverage_summary.txt"

    log_info "生成覆盖率报告: $suite_id"

    gcovr \
        --root "$CATALOG_REPO" \
        --object-directory "$CATALOG_REPO/src" \
        --html --html-details \
        --output "$report_dir/index.html" \
        $GCOVR_OPTIONS \
        --print-summary \
        2>&1 | tee "$gcovr_log"

    echo ""
    log_info "各文件覆盖率:"
    gcovr --root "$CATALOG_REPO" --object-directory "$CATALOG_REPO/src" 2>&1 | \
        grep -E "^src/|^TOTAL|^--" | tee "$summary_file" || true

    SUITE_COV_PCT=$(grep -oP 'lines: \K[0-9.]+' "$gcovr_log" 2>/dev/null | tail -1 || echo "N/A")
    log_info "覆盖率: ${SUITE_COV_PCT}% lines → $report_dir/index.html"
}
