# LOVE20 DEX — Uniswap V2

独立的 Uniswap V2 部署仓库，为 LOVE20 的 Stake 提供 Factory、Pair 和完整 Router02。
**上游合约源码零修改**：通过固定提交的 Git submodule 引入；永久关闭协议抽成由部署参数实现，交易手续费仍为 **0.30%**。

## 上游来源与版本

| 子模块 | 本项目使用范围 |
| --- | --- |
| [v2-core](https://github.com/Uniswap/v2-core) | Factory、Pair、LP ERC20 及依赖 |
| [v2-periphery](https://github.com/Uniswap/v2-periphery) | Router02 及依赖 |
| [solidity-lib](https://github.com/Uniswap/solidity-lib) | TransferHelper |

子模块固定到精确提交（v2-core 为 v1.0.1、solidity-lib 为 v1.1.1）；溯源口径见 [ADR 0003](docs/adr/0003-record-upstream-baseline.md)，构建范围见 [ADR 0002](docs/adr/0002-preserve-complete-selected-contracts.md)。核验上游未被改动：

```bash
git submodule status
git submodule foreach 'git status --short; git diff --exit-code HEAD'
git diff --exit-code upstream-baseline -- .gitmodules lib
```

`status --short` 无输出且 diff 为空即通过；`git diff upstream-baseline..HEAD` 是本项目在上游之后增加的全部内容。

## 与上游的差异

唯一差异是 Factory 的部署参数 `feeToSetter = address(0)`：`feeTo` 初始为零，而 `setFeeTo` 与 `setFeeToSetter` 都只允许当前管理员调用，部署后无人能开启协议抽成。手续费收益全部归流动性提供者，代价是放弃未来开启协议收入的能力，理由见 [ADR 0001](docs/adr/0001-disable-protocol-fee.md)。

## 构建与测试

需要 Foundry（已使用 v1.8.1 验证）和 Make；首次构建由 Foundry 获取所需 Solidity 编译器，不依赖相邻的 LOVE20 仓库，也不需要 npm。

```bash
git submodule update --init --recursive
make test
```

`make build` 分别在子模块根目录编译，保留上游的 `contracts/...` 源文件路径：

| 构建 | Solidity | EVM | 优化器 runs | 产物 |
| --- | --- | --- | --- | --- |
| Factory / Pair | 0.5.16 | istanbul | 999999 | `build/core/` |
| Router02 | 0.6.6 | istanbul | 999999 | `build/periphery/` |
| 部署脚本 / 测试 | 0.8.37 | osaka | 200 | `out/` |

两个 profile 复刻各自上游的 `.waffle.json`，产出的 Factory、Pair 与 Router 和官方发布包逐字节一致（metadata 仅因本地 submodule remapping 路径不同而有差异）。Pair 创建字节码的哈希必须为原版 Router 内置的值：

```text
0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f
```

部署脚本在部署前核验此哈希，测试还验证 Factory 实际创建的 Pair 地址与之吻合。所以不要改变 core 的源码路径、编译器或编译设置，也不要用普通 `forge build` 生成的其他产物替代 `build/core/`。普通 `forge build` 只做编译，不自动输出脚本/测试 lint；需要审查这些代码时单独运行 `forge lint`。

`test/Dex.t.sol` 直接运行同一份部署脚本，覆盖永久放弃管理权（256 组随机地址）、建池与地址计算、0.30% 报价、兑换与失败回滚、添加/移除流动性不增发协议费 LP。

部署脚本的 shell 层由 `test/deploy_scripts_test.py` 回归：它在临时工程根里放三个同名的假命令（`cast`/`forge`/`osascript`）并把 `PATH` 指过去，假命令只把「谁被调用、参数是什么」记进日志，然后断言真脚本的退出码与日志——该发的交易有没有发、不该发的是否真的停住了。不碰真仓库、不碰真链，改完脚本跑一次：

```bash
python3 test/deploy_scripts_test.py
```

将构建产物部署到本地 Anvil 后，另经 LOVE20BSC 的 compatibility 工程完成 11 项兼容性检查，包括真实 Stake 的质押、手续费销毁和提取回放；那是集成验证记录，不是本仓库独立构建的依赖。

## 部署

### 准备 Foundry Keystore

部署统一使用 Foundry keystore 管理私钥。先导入账户：

```bash
cast wallet import <account-name> --interactive
```

（另可用 `cast wallet new-mnemonic` 生成新助记词、`cast wallet address --account <account-name>` 查地址，详见 [Foundry 文档](https://book.getfoundry.sh/reference/cast/cast-wallet)。）

将 `<account-name>` 和对应地址填入目标网络的 `.account` 文件（必需）。部署时 macOS 会通过弹窗读取 keystore 密码；`one_click_deploy.sh` 入口把密码**只解析一次**（先重置、再读 `.account`、最后才交互）并导出给两个部署模块，不会各弹一次窗；单独运行某个部署模块时，该模块按 环境变量 → `.account` → 交互 自行解析。已设 `KEYSTORE_PASSWORD`（写进 `.account`，或单独跑某步骤时经环境变量）时跳过弹窗，便于非交互调用；但**入口不接受通过环境变量传密码**——`KEYSTORE_PASSWORD=xxx ./script/deploy/one_click_deploy.sh <net>` 里的值会被入口重置掉（有意为之，避免上次运行的残留密码被静默复用），非交互场景请把密码写进 `.account`。非 macOS 环境没有 `osascript`，必须预设 `KEYSTORE_PASSWORD`，脚本会在缺失时明确报错。密码经权限 600 的临时文件以 `--password-file` 传给 forge，不进进程参数；广播结束或脚本退出时删除。

### 部署流程

网络参数在 `script/network/<network>/`，网络名采用「链名+链 ID+用途」（例如 `anvil31337_dev`），账户文件只在本地保存。

`script/deploy/` 下**带数字编号的都是步骤文件**，一个文件一个步骤，统一 `<步骤>.sh <network>` 调用形态，**自行加载自己需要的文件**，没有任何文件互相 source。部署面拆为两个模块，**编号即依赖顺序：deploy 1x、check 2x、verify 3x（x 为模块序号）；WETH 模块（11/21）在前，UniswapV2 模块（12/22/32）在后**：

| 步骤文件 | 自行载入的输入 | 职责 |
| --- | --- | --- |
| `11_deploy_weth.sh` | `network.params`、`dex.params`；本地部署模式另需 `.account` | 就绪 WETH：`WETH_ADDRESS` 非空则校验使用、不部署；为空则用 `WETH_NAME`/`WETH_SYMBOL` 部署可配置 WETH；地址写入 `addresses.weth.params` |
| `12_deploy_uniswapv2.sh` | `network.params`、`addresses.weth.params`、`.account` | 部署 Factory 与 Router02（WETH 取上一步写出的地址）；地址写入 `addresses.uniswapv2.params` |
| `21_check_weth.sh` | `network.params`、`dex.params`、`addresses.weth.params` | 复核 WETH 部署状态；本地部署模式另校验名称与符号 |
| `22_check_uniswapv2.sh` | `network.params`、`dex.params`、两个模块的地址文件 | 复核 Factory 与 Router02 的绑定关系 |
| `32_verify.sh` | `network.params`、两个模块的地址文件 | 合约开源验证（只覆盖 UniswapV2 两份本仓库合约）；链不支持时跳过 |

每个复核步骤都断言**地址文件的键集合等于期望合约集合**：键名漏改（如历史 `WBNB_ADDRESS`→`WETH_ADDRESS` 改造漏改一处）会显式失败，而不是让后续变量静默为空。

**入口脚本**只做编排，自身不 source 任何文件：备份两个模块的地址文件 → 依次跑五个步骤 → 校验失败回滚。

| 入口脚本 | 组合 | 用途 |
| --- | --- | --- |
| `one_click_deploy.sh <network>` | 11 → 12 → 21 → 22 → 32 | 首次全量部署 |
| `one_click_deploy_<名称>.sh <network>` | 新模块自己的步骤脚本 | 后续新增合约时另建一份 |

首次全量部署：

```bash
cp script/network/anvil31337_dev/.account.example script/network/anvil31337_dev/.account
# 填写 .account 的 keystore 账户和发送地址；在 dex.params 配置 WETH_ADDRESS（外部）
# 或 WETH_NAME/WETH_SYMBOL（本地部署）
make build
script/deploy/one_click_deploy.sh anvil31337_dev
```

将来新增合约时，为它写一套自己的步骤脚本，再建一份入口脚本把它接上；已有步骤与入口都不用改——各步骤的部署输入互不要求存在。任一一步都可脱离入口单独执行（注意模块顺序：UniswapV2 模块要求 WETH 模块先就绪）：

```bash
script/deploy/11_deploy_weth.sh anvil31337_dev       # 就绪 WETH（外部地址模式不读 .account；本地部署模式需要）
script/deploy/12_deploy_uniswapv2.sh anvil31337_dev  # 部署 Factory 与 Router02
script/deploy/21_check_weth.sh anvil31337_dev        # 独立复核，只读参数与地址文件，可随时重跑
script/deploy/22_check_uniswapv2.sh anvil31337_dev
script/deploy/32_verify.sh anvil31337_dev               # 开源验证，需 ETHERSCAN_API_KEY
```

两个复核步骤各自把不符项全部跑完再汇总，不中途退出，便于一次性看到全部不符项；任一不符以非零退出。它们不读 `.account`、不需要密码。改动 `script/deploy/` 下的脚本后，用 `python3 test/deploy_scripts_test.py` 做一次回归（见「构建与测试」）。

`dex.params` 的 WETH 三参数**严格二选一**，不能同时有值，也不能全空：

- `WETH_ADDRESS` 单独有值：使用外部已部署 WETH。`11_deploy_weth.sh` 只校验地址并写入地址文件，**不触发部署**，也不需要 `.account`；`WETH_NAME`/`WETH_SYMBOL` 必须为空，`21_check_weth.sh` 只校验地址。
- `WETH_NAME` + `WETH_SYMBOL` 同时有值（`WETH_ADDRESS` 为空）：`11_deploy_weth.sh` 用它们部署一个可配置名称/符号的 WETH（`WETH9Configurable`），并在 `21_check_weth.sh` 中校验名称与符号。只有这个模式需要 `.account` 与 keystore 签名。
- 地址与名称/符号同时有、全空、或只给一个名称/符号，部署与复核脚本都会在广播前报错。

`anvil31337_dev` 使用 `TestWETH`/`Test Wrapped ETH`；公共链填写官方 WETH 地址（BSC 上即官方 WBNB），不要再配置名称/符号。两个模块的地址分别写入 `script/network/<network>/addresses.weth.params` 与 `addresses.uniswapv2.params` 并纳入 Git 管理（与 `dev-standards` §6.2 一致；只有 `.account` 被 `.gitignore` 排除），不写进 submodule。

各部署步骤要求 RPC 的实际 Chain ID 等于 `network.params` 里的 `CHAIN_ID`。`DeployWETH.s.sol` 只负责本地部署（名称/符号来自 `WETH_NAME`/`WETH_SYMBOL`）；`DeployUniswapV2.s.sol` 在广播前先模拟：WETH 必须是已部署合约，Factory 的 `feeTo` 与 `feeToSetter` 必须为零，Router 的 `factory`/`WETH` 必须指向本次结果，否则整笔回滚。若 Router 交易失败，Factory 仍可单独保留；广播记录位于 Foundry 的 `broadcast/` 目录。

LOVE20 的 Launch 与 Stake 配置同一个 Factory，Stake 的 Router 配置为这里部署的 Router02：添加/移除流动性直接调用 Pair，手续费换币调用 Router 的 `getAmountsOut` 与 `swapExactTokensForTokens`。

## 决策与许可证

[术语表](CONTEXT.md) · [永久关闭抽成](docs/adr/0001-disable-protocol-fee.md) · [合约范围](docs/adr/0002-preserve-complete-selected-contracts.md) · [上游溯源](docs/adr/0003-record-upstream-baseline.md)

上游许可证原样保留于各子模块：[v2-core](lib/v2-core/LICENSE)、[v2-periphery](lib/v2-periphery/LICENSE)、[solidity-lib](lib/solidity-lib/LICENSE)。本项目新增脚本和测试采用 GPL-3.0-or-later。
