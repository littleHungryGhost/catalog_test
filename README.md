# catalog_test — openGauss Catalog 覆盖率测试工具

配置驱动的覆盖率测试工具，用于对 [openGauss-Catalog](https://github.com/DataInfraLab/openGauss-Catalog) 扩展进行自动化测试并生成 gcov/lcov 覆盖率报告。

## 特性

- **配置驱动**：所有路径通过 `config.sh` 或环境变量管理，适配不同环境
- **非破坏性**：不修改被测代码仓文件，Makefile 编译前后 sha256sum 一致
- **输出自包含**：报告、日志、SQL 输出全部集中在 `results/<timestamp>/` 下
- **前置校验**：运行前检查所有依赖，提前失败并给出清晰错误信息

## 快速开始

```bash
# 1. 克隆本项目
git clone git@github.com:littleHungryGhost/catalog_test.git
cd catalog_test

# 2.（可选）创建本地配置覆盖
cp config.default.sh config.sh
# 编辑 config.sh，修改需要调整的路径

# 3. 校验配置
bash run_coverage.sh --dry-run

# 4. 运行覆盖率测试
bash run_coverage.sh

# 5.（可选）查看详细输出
bash run_coverage.sh --verbose
```

## 配置

### 配置优先级（从高到低）

1. **环境变量** — 命令行临时覆盖
2. **`config.sh`** — 用户本地覆盖（gitignore，不会提交）
3. **`config.default.sh`** — 默认配置（git 跟踪）

### 可配置项

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CATALOG_REPO` | `/home/zyp/gaussdb/Catalog` | 被测 Catalog 代码仓路径 |
| `ICEBERG_FDW_REPO` | `/home/zyp/gaussdb/iceberg_fdw` | iceberg_fdw 依赖仓路径 |
| `OPENGAUSS_INCLUDE` | `…/openGauss-server-datainfra/src/include` | openGauss 头文件路径 |
| `DATADIR` | `/home/zyp/gaussdb/datanodes` | openGauss 数据目录 |
| `PORT` | `37555` | 数据库端口 |
| `TEST_DB` | `coverage_test` | 测试数据库名（自动创建/销毁） |
| `PG_CONFIG` | `pg_config` | pg_config 命令路径 |
| `ICEBERG_WAREHOUSE` | `file:///tmp/iceberg_warehouse` | Iceberg 仓库 URI |
| `GCOVR_OPTIONS` | `--exclude-unreachable-branches` | gcovr 额外选项 |
| `SKIP_FDW_BUILD` | `false` | 跳过 FDW 编译部署 |
| `SKIP_DB_RESTART` | `false` | 跳过数据库启停 |
| `KEEP_TEST_DB` | `false` | 保留测试库（调试用） |

### 示例

```bash
# 测试不同代码仓分支
CATALOG_REPO=/home/zyp/gaussdb/Catalog-feat-branch bash run_coverage.sh

# 使用不同端口
PORT=37556 bash run_coverage.sh

# 复用已运行的数据库，跳过启停
SKIP_DB_RESTART=true bash run_coverage.sh
```

## 命令行选项

| 选项 | 说明 |
|------|------|
| `--dry-run` | 校验配置和依赖，打印执行计划，不执行实际操作 |
| `--verbose` | 显示完整编译输出和失败测试的 SQL 错误详情 |

## 执行流程

```
0/9  前置校验        → 检查所有命令和路径
1/9  iceberg_fdw     → 编译部署 FDW 依赖（可跳过）
2/9  编译 Catalog    → 插入 --coverage → make → 恢复 Makefile
3/9  部署            → 复制 .so 和扩展文件到 pg 目录
4/9  重启数据库      → 停库 → 清理 .gcda → 启库
5/9  创建测试库      → 创建库 → 安装扩展
6/9  运行测试        → 遍历 test/sql/*.sql，统计 PASS/FAIL
7/9  生成报告        → 停库 → gcovr 生成 HTML 覆盖率报告
8/9  恢复            → 启库 → 清理测试库（可保留）
     生成摘要        → results/<timestamp>/summary.txt
```

## 输出结构

```
results/20250626120000/
├── coverage/
│   ├── index.html              # 覆盖率入口（浏览器打开）
│   ├── iceberg_catalog.cpp.html
│   ├── table.cpp.html
│   └── ...
├── logs/
│   ├── build.log               # Catalog 编译日志
│   ├── fdw_build.log           # FDW 编译日志
│   ├── gaussdb.log             # 数据库日志
│   ├── gcovr.log               # gcovr 输出
│   └── coverage_summary.txt    # 各文件覆盖率百分比
├── sql_outputs/
│   ├── 001_basic.out           # 每个测试的原始 SQL 输出
│   ├── 002_query.out
│   └── ...
└── summary.txt                 # 运行摘要（配置快照、通过/失败数）
```

## 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 全部测试通过，报告生成成功 |
| 1 | 配置错误或前置校验失败 |
| 2 | 存在测试失败（报告已生成） |
| 3 | 编译失败 |

## 依赖

- `gsql` — openGauss 客户端
- `gs_ctl` — openGauss 服务管理
- `gcovr` — 覆盖率报告生成（`pip install gcovr`）
- `pg_config` — PostgreSQL/openGauss 编译配置
- `make`、`gcc`/`g++` — C/C++ 编译工具链
- `sha256sum` — Makefile 完整性校验

## 项目结构

```
catalog_test/
├── README.md
├── CLAUDE.md              # Claude AI 行为准则
├── CONTRIBUTING.md        # openGauss 插件开发规范
├── config.default.sh      # 默认配置（git 跟踪）
├── config.sh              # 用户覆盖（gitignore）
├── run_coverage.sh        # 主入口脚本
├── lib/
│   └── helpers.sh         # 工具函数
├── results/               # 输出目录（gitignore）
└── tmp/                   # 临时目录（gitignore）
```

## 相关项目

- [openGauss-Catalog](https://github.com/DataInfraLab/openGauss-Catalog) — 被测扩展代码仓
- [iceberg_fdw](https://github.com/DataInfraLab/iceberg_fdw) — FDW 依赖
