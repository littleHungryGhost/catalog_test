#!/bin/bash
# helpers.sh — shared utility functions for catalog_test scripts

# ── ANSI color codes ─────────────────────────────────────────────────────
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
COLOR_BOLD='\033[1m'

# ── Logging helpers ──────────────────────────────────────────────────────

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_step() {
    echo ""
    echo -e "${COLOR_BOLD}=== [$1] $2 ===${COLOR_RESET}"
}

# ── Filesystem helpers ────────────────────────────────────────────────────

ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

# ── Database helpers ──────────────────────────────────────────────────────

check_port() {
    if ! gsql -d postgres -p "$PORT" -c "SELECT 1;" > /dev/null 2>&1; then
        log_error "端口 $PORT 上没有运行中的数据库"
        echo ""
        echo "  启动数据库:  gs_ctl start -D <datadir> -o \"-p $PORT\""
        echo "  或指定端口:  PORT=xxx bash $0"
        return 1
    fi
    return 0
}

# ── Validation helpers ────────────────────────────────────────────────────

# Check that a required command is available on PATH
require_cmd() {
    if ! command -v "$1" > /dev/null 2>&1; then
        log_error "缺少命令: $1 (请先安装)"
        return 1
    fi
    return 0
}

# Check that a required file or directory exists
require_path() {
    if [ ! -e "$1" ]; then
        log_error "路径不存在: $1"
        return 1
    fi
    return 0
}
