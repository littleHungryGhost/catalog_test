#!/bin/bash
# run_coverage.sh — 配置驱动的覆盖率测试流程
#
# 用法:
#   bash run_coverage.sh              # 完整运行
#   bash run_coverage.sh --dry-run    # 仅校验配置，不执行实际操作
#   bash run_coverage.sh --verbose    # 显示完整编译和 SQL 输出
#
# 测试执行委托给 Catalog 仓自带的 test/run_tests.sh（带输出归一化和预期基线对比）。
# 本脚本只负责 coverage 特有流程：编译插桩、部署、DB 启停、覆盖率报告生成。
#
# 配置: 复制 config.default.sh 为 config.sh 并修改需要的变量
#       或通过环境变量覆盖任意配置项

# ── 加载环境（必须在 set -u 之前）────────────────────────────────────────
source ~/.bashrc 2>/dev/null || true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 解析命令行选项 ────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        *)
            echo "Usage: bash $0 [--dry-run] [--verbose]"
            echo ""
            echo "  --dry-run   校验配置并打印执行计划，不执行实际操作"
            echo "  --verbose   显示完整的编译和测试输出"
            exit 1
            ;;
    esac
done

# ── 加载配置 ──────────────────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"

CONFIG_DEFAULT="$SCRIPT_DIR/config.default.sh"
CONFIG_USER="$SCRIPT_DIR/config.sh"

if [ ! -f "$CONFIG_DEFAULT" ]; then
    log_error "找不到默认配置: $CONFIG_DEFAULT"
    exit 1
fi
source "$CONFIG_DEFAULT"

if [ -f "$CONFIG_USER" ]; then
    log_info "加载用户配置: config.sh"
    source "$CONFIG_USER"
fi

TIMESTAMP=$(date +%Y%m%d%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/$TIMESTAMP"
COV_DIR="$RESULTS_DIR/coverage"
LOG_DIR="$RESULTS_DIR/logs"
SQL_OUT_DIR="$RESULTS_DIR/sql_outputs"

# 总步骤数
TOTAL_STEPS=6

# ── 前置校验 ──────────────────────────────────────────────────────────────
log_step "0/$TOTAL_STEPS" "前置校验"

VALIDATION_FAILED=0

require_cmd "$PG_CONFIG" || { VALIDATION_FAILED=1; }
require_cmd gsql || { VALIDATION_FAILED=1; }
require_cmd gs_ctl || { VALIDATION_FAILED=1; }
require_cmd gcovr || { VALIDATION_FAILED=1; }
require_cmd python3 || { VALIDATION_FAILED=1; }   # run_tests.sh 归一化需要

require_path "$CATALOG_REPO/Makefile" || { VALIDATION_FAILED=1; }
require_path "$CATALOG_REPO/src" || { VALIDATION_FAILED=1; }
require_path "$CATALOG_REPO/test/run_tests.sh" || { VALIDATION_FAILED=1; }
require_path "$DATADIR" || { VALIDATION_FAILED=1; }

if [ "$SKIP_FDW_BUILD" != "true" ]; then
    require_path "$ICEBERG_FDW_REPO/Makefile" || { VALIDATION_FAILED=1; }
fi

if [ "$VALIDATION_FAILED" -ne 0 ]; then
    echo ""
    log_error "前置校验失败，请检查配置。"
    echo "  编辑配置: $CONFIG_USER (从 $CONFIG_DEFAULT 复制)"
    echo "  环境变量: 所有配置项均支持环境变量覆盖"
    exit 1
fi

log_success "前置校验通过"

# ── 运行时路径（从 pg_config 动态获取，校验通过后才执行）──────────────────
PG_LIB="$($PG_CONFIG --pkglibdir)"
PG_SHARE="$($PG_CONFIG --sharedir)"
PLUGIN_DIR="$PG_LIB/pg_plugin"
PROC_SRCLIB="$PG_LIB/proc_srclib"
EXT_DIR="$PG_SHARE/extension"
DEPS_DIR="$CATALOG_REPO/deps"

log_info "Catalog 仓:    $CATALOG_REPO"
log_info "FDW 仓:        $ICEBERG_FDW_REPO"
log_info "数据目录:      $DATADIR"
log_info "端口:          $PORT"
log_info "结果目录:      $RESULTS_DIR"

if [ "$DRY_RUN" = true ]; then
    echo ""
    log_info "[DRY-RUN] 将执行以下步骤:"
    echo "  0. 编译部署 iceberg_fdw 依赖扩展"
    echo "  1. 编译 iceberg_catalog 扩展（带 --coverage 插桩，完成后恢复 Makefile）"
    echo "  2. 安装 iceberg_catalog 扩展及 Rust 桥接依赖到 openGauss 目录"
    echo "  3. 重启 openGauss 数据库"
    echo "  4. 调用 Catalog 仓 test/run_tests.sh 运行 SQL 测试（含归一化 + 预期对比）"
    echo "  5. 停止数据库 → 生成 gcovr 覆盖率报告"
    echo "  6. 恢复数据库"
    echo ""
    echo "  Makefile 备份/恢复机制:"
    echo "    - 编译前备份 $CATALOG_REPO/Makefile"
    echo "    - 插入 --coverage 后编译"
    echo "    - 编译完成后立即恢复原始 Makefile"
    echo "    - trap EXIT/INT/TERM 保证异常退出时也恢复"
    echo ""
    echo "  测试执行委托给: $CATALOG_REPO/test/run_tests.sh"
    echo "  如果确认无误，执行: bash $0"
    exit 0
fi

# ── 创建输出目录 ─────────────────────────────────────────────────────────
ensure_dir "$COV_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$SQL_OUT_DIR"

# run_tests.sh 需要的环境变量
export ICEBERG_WAREHOUSE
export TEST_PORT="$PORT"

# ══════════════════════════════════════════════════════════════════════════
# 步骤 0: 编译/部署 iceberg_fdw
# ══════════════════════════════════════════════════════════════════════════
STEP=0

log_step "$STEP/$TOTAL_STEPS" "编译部署 iceberg_fdw 依赖扩展"

if [ "$SKIP_FDW_BUILD" = "true" ]; then
    log_info "跳过 FDW 编译 (SKIP_FDW_BUILD=true)"
elif [ -f "$PG_LIB/iceberg_fdw.so" ]; then
    log_info "iceberg_fdw.so 已存在，跳过编译"
else
    log_info "编译安装 iceberg_fdw..."
    (
        cd "$ICEBERG_FDW_REPO"
        make clean > "$LOG_DIR/fdw_build.log" 2>&1 || true
        OPENGAUSS_SRC_INCLUDE="$OPENGAUSS_INCLUDE" make >> "$LOG_DIR/fdw_build.log" 2>&1
        make install >> "$LOG_DIR/fdw_build.log" 2>&1
    )
    log_success "FDW 编译完成"
fi

cp "$ICEBERG_FDW_REPO/iceberg_fdw.so" "$PG_LIB/" 2>/dev/null || true
cp "$ICEBERG_FDW_REPO/iceberg_fdw.control" "$EXT_DIR/" 2>/dev/null || true
cp "$ICEBERG_FDW_REPO/iceberg_fdw--0.1.0.sql" "$EXT_DIR/" 2>/dev/null || true
log_success "iceberg_fdw 部署完成"

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 1: 编译 Catalog（带 --coverage，非破坏式）
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "编译 iceberg_catalog 扩展（带 --coverage 插桩）"

CATALOG_MAKEFILE="$CATALOG_REPO/Makefile"
MAKEFILE_BACKUP="$CATALOG_REPO/Makefile.bak.coverage.$$"

if [ -f "$MAKEFILE_BACKUP" ]; then
    log_warn "发现上次运行遗留的备份文件，正在恢复..."
    mv "$MAKEFILE_BACKUP" "$CATALOG_MAKEFILE"
fi

MAKEFILE_CHECKSUM_BEFORE=$(sha256sum "$CATALOG_MAKEFILE" | awk '{print $1}')

restore_makefile() {
    if [ -f "$MAKEFILE_BACKUP" ]; then
        mv "$MAKEFILE_BACKUP" "$CATALOG_MAKEFILE"
    fi
}

cp "$CATALOG_MAKEFILE" "$MAKEFILE_BACKUP"
trap 'restore_makefile' EXIT INT TERM

if ! grep -q -- '--coverage' "$CATALOG_MAKEFILE"; then
    sed -i 's/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC --coverage/' "$CATALOG_MAKEFILE"
    log_info "已添加 --coverage 标志"
else
    log_info "--coverage 标志已存在"
fi

log_info "开始编译..."
if [ "$VERBOSE" = true ]; then
    (cd "$CATALOG_REPO" && make clean && make) 2>&1 | tee "$LOG_DIR/build.log"
else
    (cd "$CATALOG_REPO" && make clean > "$LOG_DIR/build.log" 2>&1 && make >> "$LOG_DIR/build.log" 2>&1)
fi

if ! grep -q 'iceberg_catalog.so' "$LOG_DIR/build.log"; then
    log_error "编译失败! 详见: $LOG_DIR/build.log"
    tail -20 "$LOG_DIR/build.log"
    exit 1
fi
log_success "编译成功"

restore_makefile
trap - EXIT INT TERM

MAKEFILE_CHECKSUM_AFTER=$(sha256sum "$CATALOG_MAKEFILE" | awk '{print $1}')
if [ "$MAKEFILE_CHECKSUM_BEFORE" != "$MAKEFILE_CHECKSUM_AFTER" ]; then
    log_error "Makefile 恢复后校验和不一致! 请手动检查"
    exit 1
fi
log_success "Makefile 已恢复 (校验和: ${MAKEFILE_CHECKSUM_BEFORE:0:8}...)"

ls "$CATALOG_REPO"/src/*.gcno 2>/dev/null | while read f; do
    log_info "  $(basename "$f")"
done

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 2: 安装扩展文件
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "安装 iceberg_catalog 扩展及 Rust 桥接依赖到 openGauss"

ensure_dir "$PLUGIN_DIR"
ensure_dir "$PROC_SRCLIB"
ensure_dir "$EXT_DIR"

cp "$CATALOG_REPO/iceberg_catalog.control" "$EXT_DIR/"
cp "$CATALOG_REPO/iceberg_catalog--1.0.0.sql" "$EXT_DIR/"

SO_SRC="$CATALOG_REPO/iceberg_catalog.so"
for f in "$PLUGIN_DIR"/node1#*iceberg_catalog.so; do
    cp "$SO_SRC" "$f" 2>/dev/null || true
done
cp "$SO_SRC" "$PG_LIB/iceberg_catalog.so"
cp "$SO_SRC" "$PROC_SRCLIB/iceberg_catalog.so"
cp "$DEPS_DIR/libiceberg_rust_bridge.so" "$PG_LIB/"
log_success "已更新所有 .so 副本"

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 3: 重启数据库 + 清理旧覆盖率数据
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "重启 openGauss 数据库"

if [ "$SKIP_DB_RESTART" = "true" ]; then
    log_info "跳过数据库重启 (SKIP_DB_RESTART=true)"
else
    gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>/dev/null || true
    sleep 2

    rm -f "$CATALOG_REPO"/src/*.gcda
    mkdir -p /tmp/iceberg_warehouse

    gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
    sleep 1
    log_success "数据库已启动"
fi

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 4: 运行测试（委托给 Catalog 仓 test/run_tests.sh）
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "运行 SQL 测试（调用 Catalog 仓 test/run_tests.sh）"
log_info "测试脚本: $CATALOG_REPO/test/run_tests.sh"

TEST_RUNNER="$CATALOG_REPO/test/run_tests.sh"
TEST_LOG="$LOG_DIR/run_tests.log"

# run_tests.sh 从它所在目录自动找到 common.sh、sql/、expected/ 等路径
if [ "$VERBOSE" = true ]; then
    (cd "$CATALOG_REPO" && bash "$TEST_RUNNER") 2>&1 | tee "$TEST_LOG"
    TEST_EXIT="${PIPESTATUS[0]}"
else
    (cd "$CATALOG_REPO" && bash "$TEST_RUNNER") > "$TEST_LOG" 2>&1
    TEST_EXIT=$?
fi

# 从 run_tests.sh 输出中提取 pass/fail 计数
PASS=$(grep -oP '\d+(?= passed)' "$TEST_LOG" 2>/dev/null || echo "0")
FAIL=$(grep -oP '\d+(?= failed)' "$TEST_LOG" 2>/dev/null || echo "0")
PASS="${PASS:-0}"
FAIL="${FAIL:-0}"

# 打印测试结果摘要
if [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; then
    echo -e "  ${COLOR_GREEN}$PASS passed${COLOR_RESET}, ${COLOR_RED}$FAIL failed${COLOR_RESET}"
else
    # 打印失败详情（从日志尾部提取）
    grep -E "✓|✗|PASS|FAIL|passed|failed" "$TEST_LOG" | tail -20 || true
    echo ""
    echo -e "  ${COLOR_GREEN}$PASS passed${COLOR_RESET}, ${COLOR_RED}$FAIL failed${COLOR_RESET}"
fi

# 复制 run_tests.sh 的结果到我们的输出目录
if [ -d "$CATALOG_REPO/test/results" ]; then
    cp -r "$CATALOG_REPO/test/results/"* "$SQL_OUT_DIR/" 2>/dev/null || true
    log_info "测试输出已复制到: $SQL_OUT_DIR/"
fi

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 5: 停止数据库 + 生成覆盖率报告
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "生成 gcovr 覆盖率报告"

if [ "$SKIP_DB_RESTART" != "true" ]; then
    gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>&1 | tail -1
    sleep 1
fi

if ! ls "$CATALOG_REPO"/src/*.gcda > /dev/null 2>&1; then
    log_warn "未找到 .gcda 文件，覆盖率数据可能不完整"
fi

gcovr \
    --root "$CATALOG_REPO" \
    --object-directory "$CATALOG_REPO/src" \
    --html --html-details \
    --output "$COV_DIR/index.html" \
    $GCOVR_OPTIONS \
    --print-summary \
    2>&1 | tee "$LOG_DIR/gcovr.log"

echo ""
log_info "各文件覆盖率:"
gcovr --root "$CATALOG_REPO" --object-directory "$CATALOG_REPO/src" 2>&1 | \
    grep -E "^src/|^TOTAL|^--" | tee "$LOG_DIR/coverage_summary.txt" || true

echo ""
log_info "HTML 报告: $COV_DIR/index.html"

STEP=$((STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 6: 恢复数据库
# ══════════════════════════════════════════════════════════════════════════
log_step "$STEP/$TOTAL_STEPS" "恢复 openGauss 数据库"

if [ "$SKIP_DB_RESTART" != "true" ]; then
    gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
fi

log_success "数据库已恢复"
# run_tests.sh 在结束后已自行清理测试库，无需额外操作

# ══════════════════════════════════════════════════════════════════════════
# 生成运行摘要
# ══════════════════════════════════════════════════════════════════════════
SUMMARY_FILE="$RESULTS_DIR/summary.txt"

{
    echo "═══════════════════════════════════════"
    echo "  Coverage Run Summary"
    echo "═══════════════════════════════════════"
    echo ""
    echo "  Timestamp:   $TIMESTAMP"
    echo "  Catalog:     $CATALOG_REPO"
    echo "  FDW:         $ICEBERG_FDW_REPO"
    echo "  Datadir:     $DATADIR"
    echo "  Port:        $PORT"
    echo ""
    echo "  Tests:       $PASS passed, $FAIL failed  (via run_tests.sh)"
    echo ""
    echo "  Coverage:    $COV_DIR/index.html"
    echo "  Logs:        $LOG_DIR/"
    echo "  SQL Outputs: $SQL_OUT_DIR/"
    echo ""
    echo "═══════════════════════════════════════"
} > "$SUMMARY_FILE"

cat "$SUMMARY_FILE"

# ── 退出码 ────────────────────────────────────────────────────────────────
if [ "$FAIL" -gt 0 ]; then
    exit 2
fi
exit 0
