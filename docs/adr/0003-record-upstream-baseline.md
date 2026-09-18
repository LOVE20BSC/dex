# 用上游原文基线追踪 fork 差异

`dex/` 使用独立 Git 仓库，以 submodule 引入 Uniswap 的 `v2-core`、`v2-periphery` 和 `solidity-lib`，固定精确提交，不修改上游源码。首个提交和 `upstream-baseline` 标签记录子模块基线，后续提交只增加本项目的部署、测试和文档。上游合约名称、许可证和历史原样保留，读者可以直接核验版本与源码差异，无需维护重复源码。

核心合约与 Router 分别来自 Uniswap V2 的不同仓库，因此采用组合源码的独立仓库，不要求 GitHub 显示 `forked from` 标记。基线之后不改写基线提交，以免丢失差异对照依据。
