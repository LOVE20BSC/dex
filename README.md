# LOVE20 DEX — Uniswap V2

独立的 Uniswap V2 部署仓库，为 LOVE20 的 Stake 提供 Factory、Pair 和完整 Router02。
**上游合约源码零修改**：通过固定版本的 Git submodule 引入；永久关闭协议抽成由部署参数实现，交易手续费仍为 **0.30%**。

## 上游来源与版本

| 子模块 | 官方仓库与固定提交 | 本项目使用范围 |
| --- | --- | --- |
| `lib/v2-core` | [Uniswap/v2-core · 4dd59067c76dea4a0e8e4bfdda41877a6b16dedc](https://github.com/Uniswap/v2-core/tree/4dd59067c76dea4a0e8e4bfdda41877a6b16dedc)（v1.0.1） | Factory、Pair、LP ERC20 及依赖 |
| `lib/v2-periphery` | [Uniswap/v2-periphery · ed24991304291297c3b4a52818d02f46a17aa9a2](https://github.com/Uniswap/v2-periphery/tree/ed24991304291297c3b4a52818d02f46a17aa9a2) | Router02 及依赖 |
| `lib/solidity-lib` | [Uniswap/solidity-lib · 2e31d2c594caf01f16041cd73d8701c43b87cc16](https://github.com/Uniswap/solidity-lib/tree/2e31d2c594caf01f16041cd73d8701c43b87cc16)（v1.1.1） | TransferHelper |

这是组合多个上游仓库的独立衍生项目，不代表 Uniswap 官方部署。
原始名称、源码、许可证和提交历史完整保留；子模块中的 Router01 实现、V1 迁移器和示例不参与本项目构建。
Router02 依赖的 `IUniswapV2Router01` 接口保留。

## 与上游的差异

| 项目 | 差异 |
| --- | --- |
| 上游 Solidity 源码 | 无 |
| Factory 部署参数 | `feeToSetter = address(0)`，永久放弃费用管理权 |
| 交易手续费 | 无，仍为 0.30% |
| 项目自身新增 | Foundry 构建配置、部署脚本、测试和文档 |

原版 Factory 的 `feeTo` 初始为零；`setFeeTo` 与 `setFeeToSetter` 都只允许当前管理员调用。
从部署开始将管理员设为零地址，两个管理入口就永久不可用，无需删除接口或改动 Pair。
此保证针对本项目部署脚本创建的 Factory；手动给原版构造函数传入其他管理员地址，仍能开启抽成。

核验上游版本和源码：

```bash
git submodule status
git diff --exit-code upstream-baseline -- .gitmodules lib
git submodule foreach 'git status --short; git diff --exit-code HEAD'
```

子模块版本应与上表一致，`status --short` 无输出且 diff 为空。
查看本项目在上游基线之后增加的全部内容：

```bash
git diff upstream-baseline..HEAD
```

## 构建与测试

需要 Foundry（已使用 v1.8.1 验证）和 Make。首次构建由 Foundry 获取所需 Solidity 编译器；不依赖相邻的 LOVE20 仓库，也不需要 npm。

```bash
git submodule update --init --recursive
make test
```

`make build` 分别在子模块根目录编译，保留上游的 `contracts/...` 源文件路径：

| 构建 | Solidity | EVM | 优化器 runs | 产物 |
| --- | --- | --- | --- | --- |
| Factory / Pair | 0.5.16 | istanbul | 999999 | `build/core/` |
| Router02 | 0.6.6 | istanbul | 999999 | `build/periphery/` |
| 部署脚本 / 测试 | 0.8.37 | istanbul | 200 | `out/` |

Pair 创建字节码的哈希必须为原版 Router 内置的值：

```text
0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f
```

部署脚本在部署前核验此哈希；测试还验证 Factory 实际创建的 Pair 地址与之吻合。
所以不要改变 core 的源码路径、编译器或编译设置，也不要用普通 `forge build` 生成的其他产物替代 `build/core/`。

core 和 periphery 的两个 Foundry profile 明确复刻各自上游 `.waffle.json`：编译器分别为 0.5.16 和 0.6.6，EVM 为 Istanbul，优化器 runs 为 999999，metadata 使用 IPFS。Factory、Pair 的创建码和运行码与官方发布包逐字节一致；Router 的可执行码也一致，metadata 仅因本地 submodule remapping 路径不同而不同。

测试直接运行同一份部署脚本，覆盖永久放弃管理权（256 组随机地址）、建池与地址计算、0.30% 报价、兑换、添加/移除流动性不增发协议费 LP，以及失败兑换的资金回滚。
上游 ERC20、WETH9 仅用作本地测试资产；正式部署复用目标链已有的 WBNB。

2026-09-18 验证：本仓库 4 项测试通过；将构建产物部署至本地 Anvil 后，另用 LOVE20BSC 现有 compatibility 工程完成 11 项兼容性检查，包括真实 Stake 的质押、手续费销毁和提取回放。后者是集成验证记录，不是本仓库独立构建的依赖。

## 部署

部署流程仿照 LOVE20TKM `group/script/deploy`：网络参数在 `script/network/<network>/`，网络名采用“链名+链 ID+用途”（例如 `bsc97_dev`），账户文件只在本地保存，脚本依次完成初始化、部署和链上检查。

```bash
cp script/network/bsc97_dev/.account.example script/network/bsc97_dev/.account
# 填写 .account 的 keystore 账户和发送地址，并在 network.params 填写 WBNB_ADDRESS
make build
source script/deploy/00_init.sh bsc97_dev
source script/deploy/01_deploy.sh
source script/deploy/99_check.sh
```

或一键执行：

```bash
script/deploy/one_click_deploy.sh bsc97_dev
```

所有网络统一使用 Foundry keystore，macOS 会通过密码输入框读取密码。`anvil31337_dev` 会自动从上游 WETH9 构建产物部署一个本地包装币，并在本次部署中把它作为 `TestWBNB` 使用；它的链上合约名称仍是上游 WETH9 的 `Wrapped Ether`。部署脚本将地址写入被忽略的 `script/network/<network>/address.params`，不会写入三个 submodule。

`00_init.sh` 会先读取 RPC 实际 Chain ID，并要求它等于 `network.params` 中的 `CHAIN_ID`；`anvil31337_dev` 因为启用 `DEPLOY_TEST_WBNB=true`，不需要填写 `WBNB_ADDRESS`。

脚本创建 Factory 和 Router02，检查 `feeTo`、`feeToSetter` 均为零及 Router 的关联地址正确。若 Router 交易失败，Factory 仍可单独保留；广播记录位于 Foundry 的 `broadcast/` 目录。

LOVE20 的 Launch 与 Stake 应配置同一个 Factory；Stake 的 Router 配置为这里部署的 Router02。
Stake 添加/移除流动性直接调用 Pair，手续费换币调用 Router 的 `getAmountsOut` 和 `swapExactTokensForTokens`。

## 决策与许可证

[术语表](CONTEXT.md) · [永久关闭抽成](docs/adr/0001-disable-protocol-fee.md) · [合约范围](docs/adr/0002-preserve-complete-selected-contracts.md) · [上游溯源](docs/adr/0003-record-upstream-baseline.md)

上游许可证原样保留于各子模块：[v2-core](lib/v2-core/LICENSE)、[v2-periphery](lib/v2-periphery/LICENSE)、[solidity-lib](lib/solidity-lib/LICENSE)。本项目新增脚本和测试采用 GPL-3.0-or-later。
