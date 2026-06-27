#!/bin/bash
# run_coverage.sh — 配置驱动的多套件覆盖率测试工具
#
# 用法:
#   bash run_coverage.sh              # 完整运行（所有 TEST_SUITES 套件）
#   bash run_coverage.sh --dry-run    # 校验配置，打印执行计划
#   bash run_coverage.sh --verbose    # 显示完整编译和测试输出
#
# 测试执行委托给 Catalog 仓自带的 test/run_*.sh 脚本。
# 本脚本负责: 配置 → 编译插桩 → 部署 → 循环各套件 → 覆盖率报告。
#
# 配置: 复制 config.default.sh 为 config.sh 并修改需要的变量
#       或通过环境变量覆盖任意配置项

# ── 加载环境 ─────────────────────────────────────────────────────────────
source ~/.bashrc 2>/dev/null || true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 解析命令行选项 ──────────────────────────────────────────────────────
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

# ── 加载配置和工具库 ────────────────────────────────────────────────────
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

source "$SCRIPT_DIR/lib/coverage.sh"
source "$SCRIPT_DIR/lib/run_suite.sh"

TIMESTAMP=$(date +%Y%m%d%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/$TIMESTAMP"
COV_DIR="$RESULTS_DIR/coverage"
LOG_DIR="$RESULTS_DIR/logs"
SQL_OUT_DIR="$RESULTS_DIR/sql_outputs"

# ── 前置校验 ────────────────────────────────────────────────────────────
log_step "0/?" "前置校验"

VALIDATION_FAILED=0

require_cmd "$PG_CONFIG" || { VALIDATION_FAILED=1; }
require_cmd gsql || { VALIDATION_FAILED=1; }
require_cmd gs_ctl || { VALIDATION_FAILED=1; }
require_cmd gcovr || { VALIDATION_FAILED=1; }
require_cmd python3 || { VALIDATION_FAILED=1; }

require_path "$CATALOG_REPO/Makefile" || { VALIDATION_FAILED=1; }
require_path "$CATALOG_REPO/src" || { VALIDATION_FAILED=1; }
require_path "$DATADIR" || { VALIDATION_FAILED=1; }

if [ "$SKIP_FDW_BUILD" != "true" ]; then
    require_path "$ICEBERG_FDW_REPO/Makefile" || { VALIDATION_FAILED=1; }
fi

# 校验每个套件的 runner 路径
for entry in "${TEST_SUITES[@]}"; do
    IFS='|' read -r sid sname stype spath sargs <<< "$entry"
    require_path "$CATALOG_REPO/test/$spath" || { VALIDATION_FAILED=1; }
done

if [ "$VALIDATION_FAILED" -ne 0 ]; then
    echo ""
    log_error "前置校验失败，请检查配置。"
    echo "  编辑配置: $CONFIG_USER (从 $CONFIG_DEFAULT 复制)"
    echo "  环境变量: 所有配置项均支持环境变量覆盖"
    exit 1
fi

log_success "前置校验通过"

# ── 运行时路径（从 pg_config 动态获取）─────────────────────────────────
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
log_info "测试套件:      共 ${#TEST_SUITES[@]} 个"

if [ "$DRY_RUN" = true ]; then
    echo ""
    log_info "[DRY-RUN] 将执行以下步骤:"
    echo "  Phase 0 — Build:"
    echo "    0.1  编译部署 iceberg_fdw 依赖扩展"
    echo "    0.2  编译 iceberg_catalog（带 --coverage，完成后恢复 Makefile）"
    echo "    0.3  安装 iceberg_catalog 扩展及 Rust 桥接依赖"
    echo "  Phase 1 — 独立覆盖率（每套件一轮，轮间清理 .gcda）:"
    for entry in "${TEST_SUITES[@]}"; do
        IFS='|' read -r sid sname stype spath sargs <<< "$entry"
        echo "    → $sid ($sname) — $CATALOG_REPO/test/$spath"
    done
    if [ "$COMBINED_REPORT" = "true" ]; then
        echo "  Phase 2 — 累加覆盖率: 重跑全部套件不清理 .gcda → coverage/combined/"
    fi
    echo "  Phase 3 — 恢复数据库 + 汇总"
    echo ""
    echo "  Makefile 备份/恢复: 编译前备份，完成后 sha256sum 校验"
    echo "  .gcda 归档:         gcda_snapshots/<suite_id>/"
    echo ""
    echo "  如果确认无误，执行: bash $0"
    exit 0
fi

# ── 创建输出目录 ─────────────────────────────────────────────────────────
ensure_dir "$COV_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$SQL_OUT_DIR"

export ICEBERG_WAREHOUSE
export TEST_PORT="$PORT"

# ══════════════════════════════════════════════════════════════════════════
# Phase 0 — Build（一次编译，非破坏式）
# ══════════════════════════════════════════════════════════════════════════

# ── 0.1 iceberg_fdw ──────────────────────────────────────────────────────
log_step "Build.1" "编译部署 iceberg_fdw 依赖扩展"

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

# ── 0.2 Catalog --coverage ────────────────────────────────────────────────
log_step "Build.2" "编译 iceberg_catalog 扩展（带 --coverage 插桩）"

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

# ── 0.3 部署 .so + 扩展文件 ──────────────────────────────────────────────
log_step "Build.3" "安装 iceberg_catalog 扩展及 Rust 桥接依赖到 openGauss"

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

# ══════════════════════════════════════════════════════════════════════════
# Phase 1 — 独立覆盖率（循环每个套件）
# ══════════════════════════════════════════════════════════════════════════

SUITE_RESULTS=()    # "suite_id|display_name|pass|fail|cov_pct"
OVERALL_PASS=0
OVERALL_FAIL=0

for entry in "${TEST_SUITES[@]}"; do
    IFS='|' read -r suite_id display_name stype spath sargs <<< "$entry"

    echo ""
    log_step "Suite" "$display_name ($suite_id)"

    # Call the suite lifecycle (sourced, sets PASS/FAIL)
    run_one_suite "$suite_id" "$display_name" "$stype" "$spath" "$sargs"

    local_cov_pct="${SUITE_COV_PCT:-N/A}"
    SUITE_RESULTS+=("$suite_id|$display_name|$PASS|$FAIL|$local_cov_pct")
    OVERALL_PASS=$((OVERALL_PASS + PASS))
    OVERALL_FAIL=$((OVERALL_FAIL + FAIL))
done

# ══════════════════════════════════════════════════════════════════════════
# Phase 2 — 累加覆盖率报告（可选）
# ══════════════════════════════════════════════════════════════════════════

if [ "$COMBINED_REPORT" = "true" ]; then
    echo ""
    log_step "Combined" "生成累加覆盖率报告（重跑全部套件，不清理 .gcda）"

    if [ "$SKIP_DB_RESTART" != "true" ]; then
        gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>/dev/null || true
        sleep 1
        clean_gcda
        mkdir -p /tmp/iceberg_warehouse
        gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
        sleep 1
    fi

    for entry in "${TEST_SUITES[@]}"; do
        IFS='|' read -r suite_id display_name stype spath sargs <<< "$entry"

        log_info "运行: $display_name"
        case "$stype" in
            sql_script)
                (cd "$CATALOG_REPO" && bash "test/$spath" $sargs) \
                    > "$LOG_DIR/combined_${suite_id}_runner.log" 2>&1 || true
                ;;
            binary)
                "$CATALOG_REPO/test/$spath" $sargs \
                    > "$LOG_DIR/combined_${suite_id}_runner.log" 2>&1 || true
                ;;
        esac
    done

    if [ "$SKIP_DB_RESTART" != "true" ]; then
        gs_ctl stop -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" 2>&1 | tail -1
        sleep 1
    fi

    generate_coverage_report "combined" || true
    combined_cov_pct="${SUITE_COV_PCT:-N/A}"
    clean_gcda
fi

# ══════════════════════════════════════════════════════════════════════════
# Phase 3 — 恢复数据库
# ══════════════════════════════════════════════════════════════════════════

if [ "$SKIP_DB_RESTART" != "true" ]; then
    gs_ctl start -D "$DATADIR" -l "$LOG_DIR/gaussdb.log" -o "-p $PORT" 2>&1 | tail -1
fi
log_success "数据库已恢复"

# ══════════════════════════════════════════════════════════════════════════
# 汇总
# ══════════════════════════════════════════════════════════════════════════

SUMMARY_FILE="$RESULTS_DIR/summary.txt"

{
    echo "═══════════════════════════════════════"
    echo "  Coverage Run Summary"
    echo "═══════════════════════════════════════"
    echo ""
    echo "  Timestamp:   $TIMESTAMP"
    echo "  Catalog:     $CATALOG_REPO"
    echo "  Datadir:     $DATADIR"
    echo "  Port:        $PORT"
    echo ""
    echo "── Suite Results ────────────────────"
    for entry in "${SUITE_RESULTS[@]}"; do
        IFS='|' read -r sid sname spass sfail scov <<< "$entry"
        printf "  %-16s %3s passed, %3s failed   lines: %s\n" \
            "$sid:" "$spass" "$sfail" "$scov"
    done
    echo ""
    echo "── Overall ──────────────────────────"
    echo "  Suites:     ${#SUITE_RESULTS[@]} run"
    echo "  Tests:      $OVERALL_PASS passed, $OVERALL_FAIL failed"
    if [ "$COMBINED_REPORT" = "true" ]; then
        echo "  Combined:   $COV_DIR/combined/index.html"
    fi
    echo ""
    echo "  Coverage:   $COV_DIR/"
    echo "  Logs:       $LOG_DIR/"
    echo "  Artifacts:  $SQL_OUT_DIR/"
    echo ""
    echo "═══════════════════════════════════════"
} > "$SUMMARY_FILE"

cat "$SUMMARY_FILE"

# ── 退出码 ──────────────────────────────────────────────────────────────
if [ "$OVERALL_FAIL" -gt 0 ]; then
    exit 2
fi
exit 0
