# 保留所选上游合约的完整功能

构建完整的 Uniswap V2 Factory、Pair、Router02 及其必要依赖；不构建 Router01 实现、V1 迁移器和示例。虽然 Stake 只使用其中部分接口，仍保留所选合约的完整功能，以便直接对照上游源码，并避免维护自行裁剪的 Router；这也意味着完整 Router02 的公开接口属于本 DEX 的维护范围。

上游以 submodule 完整保留，只限制本项目的构建入口。上游的 ERC20 和 WETH9 测试合约仅作为本地测试资产，不部署为正式 WBNB。
