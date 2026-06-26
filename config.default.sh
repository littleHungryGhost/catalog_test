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

# Database port
PORT="${PORT:-37555}"

# Name of the test database to create/destroy
TEST_DB="${TEST_DB:-coverage_test}"

# ── Tool paths ───────────────────────────────────────────────────────────
# pg_config binary (must be on PATH or specify absolute path)
PG_CONFIG="${PG_CONFIG:-pg_config}"

# ── Iceberg configuration ────────────────────────────────────────────────
# Iceberg warehouse URI (file:// for local, s3:// for S3)
ICEBERG_WAREHOUSE="${ICEBERG_WAREHOUSE:-file:///tmp/iceberg_warehouse}"

# ── Coverage options ─────────────────────────────────────────────────────
# Extra options passed to gcovr
GCOVR_OPTIONS="${GCOVR_OPTIONS:---exclude-unreachable-branches}"

# ── Behavior flags ───────────────────────────────────────────────────────
# Skip iceberg_fdw build and deploy (set to "true" if already installed)
SKIP_FDW_BUILD="${SKIP_FDW_BUILD:-false}"

# Skip database stop/start cycle (set to "true" if DB is already running
# with the correct extensions loaded)
SKIP_DB_RESTART="${SKIP_DB_RESTART:-false}"

# Keep the test database after the run (set to "true" for manual inspection)
KEEP_TEST_DB="${KEEP_TEST_DB:-false}"
