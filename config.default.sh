#!/bin/bash
# config.default.sh — Default configuration for catalog_test coverage runner.
#
# To override any value, copy this file to config.sh (in the same directory)
# and edit only the variables you want to change.
# config.sh is gitignored and will never be committed.
#
# Priority (highest to lowest):
#   1. Environment variables
#   2. config.sh (user override)
#   3. config.default.sh (this file — defaults)

# ── Repository paths ─────────────────────────────────────────────────────
# Path to the Catalog source repository under test
CATALOG_REPO="${CATALOG_REPO:-/home/zyp/gaussdb/Catalog}"

# Path to iceberg_fdw source repository (needed as a dependency)
ICEBERG_FDW_REPO="${ICEBERG_FDW_REPO:-/home/zyp/gaussdb/iceberg_fdw}"

# Path to openGauss server source include directory (for FDW compilation)
OPENGAUSS_INCLUDE="${OPENGAUSS_INCLUDE:-/home/zyp/gaussdb/openGauss-server-datainfra/src/include}"

# ── Database configuration ───────────────────────────────────────────────
# openGauss data directory
DATADIR="${DATADIR:-/home/zyp/gaussdb/datanodes}"

# Database port (passed to Catalog's run_tests.sh via TEST_PORT)
PORT="${PORT:-37555}"

# ── Tool paths ───────────────────────────────────────────────────────────
# pg_config binary (must be on PATH or specify absolute path)
PG_CONFIG="${PG_CONFIG:-pg_config}"

# ── Iceberg configuration ────────────────────────────────────────────────
# Iceberg warehouse URI (file:// for local, s3:// for S3)
ICEBERG_WAREHOUSE="${ICEBERG_WAREHOUSE:-file:///tmp/iceberg_warehouse}"

# ── Coverage options ─────────────────────────────────────────────────────
# Extra options passed to gcovr
GCOVR_OPTIONS="${GCOVR_OPTIONS:---exclude-unreachable-branches}"

# ── Test Suite Definitions ─────────────────────────────────────────────────
# Each entry: "suite_id|display_name|type|runner_path|runner_args"
#
#   suite_id       Unique short ID used for directory naming (alphanumeric + _).
#   display_name   Human-readable label shown in logs and summary.
#   type           "sql_script" (requires DB, auto stop/start around suite)
#                  "binary"     (no DB needed, run executable directly)
#   runner_path    Path relative to $CATALOG_REPO/test/.
#   runner_args    Extra CLI args forwarded to the runner (optional, can be "").
#
# To add a suite: append an entry here or in config.sh via TEST_SUITES+=(...).
TEST_SUITES=(
    "serial|SQL Serial Tests|sql_script|run_tests.sh|"
    "concurrency|Concurrency Tests|sql_script|run_concurrency_tests.sh|"
)

# ── Combined Coverage Report ────────────────────────────────────────────────
# If "true", after all per-suite independent reports are generated, re-run
# all suites sequentially without cleaning .gcda to produce a combined report
# at coverage/combined/index.html.  Disable with "false" to save time.
COMBINED_REPORT="${COMBINED_REPORT:-true}"

# ── Behavior flags ───────────────────────────────────────────────────────
# Skip iceberg_fdw build and deploy (set to "true" if already installed)
SKIP_FDW_BUILD="${SKIP_FDW_BUILD:-false}"

# Skip database stop/start cycle (set to "true" if DB is already running
# with the correct extensions loaded)
SKIP_DB_RESTART="${SKIP_DB_RESTART:-false}"
