#!/bin/bash
# coverage.sh — 完整覆盖率测试流程
# 用法: cd /home/zyp/gaussdb/Catalog && bash test/coverage.sh

# ── 加载环境（必须在 set -u 之前）────────────────────────────────────────
source ~/.bashrc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
check_port

TIMESTAMP=$(date +%Y%m%d%H%M%S)

# ── 路径配置（全部从 pg_config 动态获取）───────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_LIB="$(pg_config --pkglibdir)"
PG_SHARE="$(pg_config --sharedir)"
DATADIR="/home/zyp/gaussdb/datanodes"
PLUGIN_DIR="$PG_LIB/pg_plugin"
PROC_SRCLIB="$PG_LIB/proc_srclib"
EXT_DIR="$PG_SHARE/extension"
DEPS_DIR="$PROJECT_ROOT/deps"
LOG_FILE="/tmp/gaussdb.log"
TEST_DB="coverage_test"

# 确保运行时目录存在
mkdir -p "$PLUGIN_DIR" "$PROC_SRCLIB" "$EXT_DIR"

export ICEBERG_WAREHOUSE="file:///tmp/iceberg_warehouse"

cd "$PROJECT_ROOT"

# ── 0. 安装 iceberg_fdw（如已安装则跳过编译）──────────────────────────
echo "=== [0/9] iceberg_fdw ==="
FDW_SRC="/home/zyp/gaussdb/iceberg_fdw"
if [ ! -f "$PG_LIB/iceberg_fdw.so" ]; then
    echo "  编译安装 iceberg_fdw..."
    cd "$FDW_SRC"
    make clean > /dev/null 2>&1 || true
    OPENGAUSS_SRC_INCLUDE=/home/zyp/gaussdb/openGauss-server-datainfra/src/include make > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd "$PROJECT_ROOT"
fi
cp "$FDW_SRC/iceberg_fdw.so" "$PG_LIB/" 2>/dev/null || true
cp "$FDW_SRC/iceberg_fdw.control" "$EXT_DIR/" 2>/dev/null || true
cp "$FDW_SRC/iceberg_fdw--0.1.0.sql" "$EXT_DIR/" 2>/dev/null || true
echo "  iceberg_fdw ready"


# ── 1. 确保 --coverage 标志 ──────────────────────────────────────────────
echo "=== [1/8] 检查 --coverage 标志 ==="
if ! grep -q 'coverage' Makefile; then
    echo "  添加 --coverage 到 Makefile"
    sed -i 's/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC --coverage/' Makefile
fi
grep 'coverage' Makefile || true

# ── 2. 完整清理 + 编译 ──────────────────────────────────────────────────
echo ""
echo "=== [2/8] make clean && make ==="
make clean > /dev/null 2>&1 || true
if ! make 2>&1 | tail -1 | grep -q 'iceberg_catalog.so'; then
    echo "  编译失败!"
    exit 1
fi
echo "  编译成功"
ls src/*.gcno 2>/dev/null | while read f; do echo "  $(basename $f)"; done

# ── 3. 安装 + 部署 .so ──────────────────────────────────────────────────
echo ""
echo "=== [3/8] 部署 .so + 扩展文件 ==="
cp "$PROJECT_ROOT/iceberg_catalog.control" "$EXT_DIR/"
cp "$PROJECT_ROOT/iceberg_catalog--1.0.0.sql" "$EXT_DIR/"

SO_SRC="$PROJECT_ROOT/iceberg_catalog.so"
for f in "$PLUGIN_DIR"/node1#*iceberg_catalog.so; do
    cp "$SO_SRC" "$f" 2>/dev/null || true
done
cp "$SO_SRC" "$PG_LIB/iceberg_catalog.so"
cp "$SO_SRC" "$PROC_SRCLIB/iceberg_catalog.so"
cp "$DEPS_DIR/libiceberg_rust_bridge.so" "$PG_LIB/"
echo "  已更新所有 .so 副本"

# ── 4. 停库 + 清理旧覆盖率 + 创建 warehouse + 启库 ─────────────────────
echo ""
echo "=== [4/8] 重启数据库 ==="
gs_ctl stop -D "$DATADIR" -l "$LOG_FILE" 2>/dev/null || true
sleep 2

rm -f src/*.gcda
rm -f "$PROJECT_ROOT"/*.gcov "$PROJECT_ROOT"/src/*.gcov 2>/dev/null || true
rm -rf "$PROJECT_ROOT"/test/results/coverage-report

mkdir -p /tmp/iceberg_warehouse

gs_ctl start -D "$DATADIR" -l "$LOG_FILE" -o "-p "$PORT"" 2>&1 | tail -1
sleep 1
echo "  数据库已启动"

# ── 5. 创建测试数据库 + 安装扩展 ────────────────────────────────────────
echo ""
echo "=== [5/8] 创建测试数据库 ==="
gsql -d postgres -p "$PORT" -c "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null 2>&1 || true
gsql -d postgres -p "$PORT" -c "CREATE DATABASE $TEST_DB;" > /dev/null 2>&1
	gsql -d "$TEST_DB" -p "$PORT" -c "CREATE EXTENSION iceberg_fdw;" 2>&1
gsql -d "$TEST_DB" -p "$PORT" -c "CREATE EXTENSION iceberg_catalog;" 2>&1
echo "  扩展已安装"

# ── 6. 跑全部测试 ───────────────────────────────────────────────────────
echo ""
echo "=== [6/8] 运行测试用例 ==="
PASS=0
FAIL=0
for f in "$PROJECT_ROOT"/test/sql/*.sql; do
    name=$(basename "$f" .sql)
    OUTPUT=$(gsql -d "$TEST_DB" -p "$PORT" -f "$f" 2>&1) || true
    ERR=$(echo "$OUTPUT" | awk 'BEGIN{s=0;e=0} /^SAVEPOINT/{s=1} /^ROLLBACK/{s=0} /^ERROR:/{if(!s) e++} END{print e}')
    if [ "$ERR" -eq 0 ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name ($ERR errors)"
        FAIL=$((FAIL + 1))
    fi
done
echo "  ─────────────────────────"
echo "  $PASS passed, $FAIL failed"

# ── 7. 优雅停库 + 生成覆盖率报告 ────────────────────────────────────────
echo ""
echo "=== [7/8] 停止数据库 + 生成覆盖率 ==="
gs_ctl stop -D "$DATADIR" -l "$LOG_FILE" 2>&1 | tail -1
sleep 1

if ! ls src/*.gcda > /dev/null 2>&1; then
    echo "  警告: 未找到 .gcda 文件"
fi

COV_DIR="$PROJECT_ROOT/test/results/coverage-report/${TIMESTAMP}"
mkdir -p "$COV_DIR"
gcovr \
    --root . \
    --object-directory src \
    --html --html-details \
    --output "$COV_DIR/index.html" \
    --exclude-unreachable-branches \
    --print-summary \
    2>&1

echo ""
echo "=== 各文件覆盖率 ==="
gcovr --root . --object-directory src 2>&1 | grep -E "^src/|^TOTAL|^--" || true

echo ""
echo "  HTML 报告: $COV_DIR/index.html"

# ── 9. 恢复数据库 ───────────────────────────────────────────────────────
echo "=== [8/8] 恢复数据库 ==="
gs_ctl start -D "$DATADIR" -l "$LOG_FILE" -o "-p "$PORT"" 2>&1 | tail -1

gsql -d postgres -p "$PORT" -c "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null 2>&1 || true

echo ""
echo "═══════════════════════════════════════"
echo "  完成: $PASS passed, $FAIL failed"
echo "  报告: $COV_DIR/index.html"
echo "═══════════════════════════════════════"
