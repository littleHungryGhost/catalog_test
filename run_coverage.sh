#!/bin/bash
# run_coverage.sh — 配置驱动的覆盖率测试流程
#
# 用法:
#   bash run_coverage.sh              # 完整运行
#   bash run_coverage.sh --dry-run    # 仅校验配置，不执行实际操作
#   bash run_coverage.sh --verbose    # 显示完整编译和 SQL 输出
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
            echo "  --verbose   显示完整的编译和 SQL 输出"
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

# ── 前置校验 ──────────────────────────────────────────────────────────────
log_step "0/9" "前置校验"

VALIDATION_FAILED=0

# 先校验 pg_config 命令可用，再从中派生路径（避免 pg_config 不存在时直接 crash）
require_cmd "$PG_CONFIG" || { VALIDATION_FAILED=1; }
require_cmd gsql || { VALIDATION_FAILED=1; }
require_cmd gs_ctl || { VALIDATION_FAILED=1; }
require_cmd gcovr || { VALIDATION_FAILED=1; }

require_path "$CATALOG_REPO/Makefile" || { VALIDATION_FAILED=1; }
require_path "$CATALOG_REPO/src" || { VALIDATION_FAILED=1; }
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
    echo "  4. 创建测试库并安装 iceberg_catalog + iceberg_fdw 扩展"
    echo "  5. 运行 SQL 测试用例 (来自 Catalog 仓 test/sql/)"
    echo "  6. 停止数据库 → 生成 gcovr 覆盖率报告"
    echo "  7. 恢复数据库 + 清理测试库"
    echo ""
    echo "  Makefile 备份/恢复机制:"
    echo "    - 编译前备份 $CATALOG_REPO/Makefile"
    echo "    - 插入 --coverage 后编译"
    echo "    - 编译完成后立即恢复原始 Makefile"
    echo "    - trap EXIT/INT/TERM 保证异常退出时也恢复"
    echo ""
    echo "  如果确认无误，执行: bash $0"
    DRY_RUN_DB_STOP=true
    DRY_RUN_DB_START=true
    exit 0
fi

# ── 创建输出目录 ─────────────────────────────────────────────────────────
ensure_dir "$COV_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$SQL_OUT_DIR"

export ICEBERG_WAREHOUSE

# ══════════════════════════════════════════════════════════════════════════
# 步骤 0: 编译/部署 iceberg_fdw
# ══════════════════════════════════════════════════════════════════════════
FULL_STEP=0

log_step "$FULL_STEP/9" "编译部署 iceberg_fdw 依赖扩展"

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

# 部署 FDW 文件
cp "$ICEBERG_FDW_REPO/iceberg_fdw.so" "$PG_LIB/" 2>/dev/null || true
cp "$ICEBERG_FDW_REPO/iceberg_fdw.control" "$EXT_DIR/" 2>/dev/null || true
cp "$ICEBERG_FDW_REPO/iceberg_fdw--0.1.0.sql" "$EXT_DIR/" 2>/dev/null || true
log_success "iceberg_fdw 部署完成"

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 1: 编译 Catalog（带 --coverage，非破坏式）
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "编译 iceberg_catalog 扩展（带 --coverage 插桩）"

CATALOG_MAKEFILE="$CATALOG_REPO/Makefile"
MAKEFILE_BACKUP="$CATALOG_REPO/Makefile.bak.coverage.$$"

# 清理上次异常退出遗留的备份
if [ -f "$MAKEFILE_BACKUP" ]; then
    log_warn "发现上次运行遗留的备份文件，正在恢复..."
    mv "$MAKEFILE_BACKUP" "$CATALOG_MAKEFILE"
fi

# 记录原始 Makefile 的校验和
MAKEFILE_CHECKSUM_BEFORE=$(sha256sum "$CATALOG_MAKEFILE" | awk '{print $1}')

restore_makefile() {
    if [ -f "$MAKEFILE_BACKUP" ]; then
        mv "$MAKEFILE_BACKUP" "$CATALOG_MAKEFILE"
    fi
}

# 备份 Makefile
cp "$CATALOG_MAKEFILE" "$MAKEFILE_BACKUP"

# 注册 trap：无论正常退出、错误退出还是 Ctrl+C，都恢复 Makefile
trap 'restore_makefile' EXIT INT TERM

if ! grep -q -- '--coverage' "$CATALOG_MAKEFILE"; then
    sed -i 's/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC/override CXXFLAGS := $(filter-out -fPIE,$(CXXFLAGS)) -fPIC --coverage/' "$CATALOG_MAKEFILE"
    log_info "已添加 --coverage 标志"
else
    log_info "--coverage 标志已存在"
fi

# 编译
log_info "开始编译..."
if [ "$VERBOSE" = true ]; then
    (cd "$CATALOG_REPO" && make clean && make) 2>&1 | tee "$LOG_DIR/build.log"
else
    (cd "$CATALOG_REPO" && make clean > "$LOG_DIR/build.log" 2>&1 && make >> "$LOG_DIR/build.log" 2>&1)
fi

# 验证编译产物
if ! grep -q 'iceberg_catalog.so' "$LOG_DIR/build.log"; then
    log_error "编译失败! 详见: $LOG_DIR/build.log"
    tail -20 "$LOG_DIR/build.log"
    # trap 会在 exit 时恢复 Makefile
    exit 1
fi
log_success "编译成功"

# 立即恢复 Makefile 并清除 trap
restore_makefile
trap - EXIT INT TERM

# 验证 Makefile 完整恢复
MAKEFILE_CHECKSUM_AFTER=$(sha256sum "$CATALOG_MAKEFILE" | awk '{print $1}')
if [ "$MAKEFILE_CHECKSUM_BEFORE" != "$MAKEFILE_CHECKSUM_AFTER" ]; then
    log_error "Makefile 恢复后校验和不一致! 请手动检查"
    exit 1
fi
log_success "Makefile 已恢复 (校验和: ${MAKEFILE_CHECKSUM_BEFORE:0:8}...)"

# 列出 .gcno 文件
ls "$CATALOG_REPO"/src/*.gcno 2>/dev/null | while read f; do
    log_info "  $(basename "$f")"
done

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 2: 部署 .so + 扩展文件
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "安装 iceberg_catalog 扩展及 Rust 桥接依赖到 openGauss"

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

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 3: 重启数据库 + 清理旧覆盖率数据
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "重启数据库"

if [ "$SKIP_DB_RESTART" = "true" ]; then
    log_info "跳过数据库重启 (SKIP_DB_RESTART=true)"
else
    gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>/dev/null || true
    sleep 2

    # 清理旧的覆盖率数据
    rm -f "$CATALOG_REPO"/src/*.gcda

    # 确保 warehouse 目录存在
    mkdir -p /tmp/iceberg_warehouse

    gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
    sleep 1
    log_success "数据库已启动"
fi

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 4: 创建测试数据库 + 安装扩展
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "创建测试库并安装 iceberg_catalog + iceberg_fdw 扩展"

gsql -d postgres -p "$PORT" -c "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null 2>&1 || true
gsql -d postgres -p "$PORT" -c "CREATE DATABASE $TEST_DB;" > /dev/null 2>&1

gsql -d "$TEST_DB" -p "$PORT" -c "CREATE EXTENSION iceberg_fdw;" 2>&1
gsql -d "$TEST_DB" -p "$PORT" -c "CREATE EXTENSION iceberg_catalog;" 2>&1
log_success "扩展已安装"

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 5: 运行 SQL 测试用例
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "运行测试用例"

PASS=0
FAIL=0
FAIL_LIST=""

for f in "$CATALOG_REPO"/test/sql/*.sql; do
    name=$(basename "$f" .sql)
    OUTPUT=$(gsql -d "$TEST_DB" -p "$PORT" -f "$f" 2>&1) || true

    # 保存原始输出
    echo "$OUTPUT" > "$SQL_OUT_DIR/${name}.out"

    # 统计不在 SAVEPOINT/ROLLBACK 块内的 ERROR
    ERR=$(echo "$OUTPUT" | awk 'BEGIN{s=0;e=0} /^SAVEPOINT/{s=1} /^ROLLBACK/{s=0} /^ERROR:/{if(!s) e++} END{print e}')

    if [ "$ERR" -eq 0 ]; then
        echo -e "  ${COLOR_GREEN}PASS${COLOR_RESET}: $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${COLOR_RED}FAIL${COLOR_RESET}: $name ($ERR errors)"
        FAIL=$((FAIL + 1))
        FAIL_LIST="$FAIL_LIST $name"
        if [ "$VERBOSE" = true ]; then
            echo "  ── 输出 ──"
            echo "$OUTPUT" | grep -E "ERROR|WARNING|HINT|DETAIL" || true
            echo "  ────────"
        fi
    fi
done

echo "  ─────────────────────────"
echo -e "  ${COLOR_GREEN}$PASS passed${COLOR_RESET}, ${COLOR_RED}$FAIL failed${COLOR_RESET}"

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 6: 停止数据库 + 生成覆盖率报告
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "生成覆盖率报告"

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

FULL_STEP=$((FULL_STEP + 1))

# ══════════════════════════════════════════════════════════════════════════
# 步骤 7: 恢复数据库
# ══════════════════════════════════════════════════════════════════════════
log_step "$FULL_STEP/9" "恢复数据库"

if [ "$SKIP_DB_RESTART" != "true" ]; then
    gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
fi

if [ "$KEEP_TEST_DB" != "true" ]; then
    gsql -d postgres -p "$PORT" -c "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null 2>&1 || true
    log_info "已删除测试数据库"
else
    log_info "保留测试数据库: $TEST_DB"
fi

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
    echo "  Test DB:     $TEST_DB"
    echo ""
    echo "  Tests:       $PASS passed, $FAIL failed"
    if [ -n "$FAIL_LIST" ]; then
        echo "  Failures:   $FAIL_LIST"
    fi
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
