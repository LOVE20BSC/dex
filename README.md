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

将 `<account-name>` 和对应地址填入目标网络的 `.account` 文件。部署时 macOS 会通过弹窗读取 keystore 密码；已设 `KEYSTORE_PASSWORD` 时跳过弹窗，便于非交互调用。

### 部署流程

网络参数在 `script/network/<network>/`，网络名采用「链名+链 ID+用途」（例如 `bsc97_dev`），账户文件只在本地保存。

`script/deploy/` 下**带数字编号的都是步骤文件**，一个文件一个步骤：

| 步骤文件 | 职责 |
| --- | --- |
| `00_init.sh` | 载入网络配置、校验链 ID、读取 keystore 密码，并把后续步骤所需变量导出到环境 |
| `01_deploy.sh` | 部署 Factory 与 Router02，地址写入 `addresses.dex.params` |
| `99_check.sh` | 独立复核链上取值 |

步骤文件自身不含初始化逻辑：变量由拼装脚本在同一 shell 里 source `00_init.sh` 得到（子进程之间无法传递 shell 变量），因此编号步骤**不作为入口单独调用**。

**拼装脚本**把步骤按顺序组合起来，是唯一入口：

| 拼装脚本 | 组合 | 用途 |
| --- | --- | --- |
| `one_click_deploy.sh <network>` | 00 → 01 → 99 | 首次全量部署 |
| `one_click_deploy_<名称>.sh <network>` | 00 → 02 → 99 | 后续新增合约时另建一份 |

首次全量部署：

```bash
cp script/network/bsc97_dev/.account.example script/network/bsc97_dev/.account
# 填写 .account 的 keystore 账户和发送地址，并在 dex.params 填写 WBNB_ADDRESS
make build
script/deploy/one_click_deploy.sh bsc97_dev
```

将来新增合约时，只写一个新的步骤文件（如 `02_deploy_<名称>.sh`），再建一份拼装脚本把它接上；`00_init.sh` 与已部署的步骤都不用改。只想跑其中一步时，在子 shell 里加载初始化，避免失败影响当前终端：

```bash
bash -c 'source script/deploy/00_init.sh bsc97_dev && bash script/deploy/01_deploy.sh'
script/deploy/99_check.sh bsc97_dev      # 独立复核，只读参数与地址文件，可随时重跑
```

`99_check.sh` 逐项核对 WBNB 名称与符号、Factory 的 `feeTo`/`feeToSetter` 为零、Router 指向本 Factory 与本 WBNB。六项全部跑完再汇总，不中途退出，便于一次性看到全部不符项；任一不符以非零退出。它不读 `.account`、不需要密码。改动 `script/deploy/` 下的脚本后，用 `python3 test/deploy_scripts_test.py` 做一次回归（见「构建与测试」）。

`anvil31337_dev` 启用 `DEPLOY_TEST_WBNB=true`，从上游 WETH9 构建产物部署一个本地包装币当 WBNB（链上名称仍是上游的 `Wrapped Ether`），因此不需要填写 `WBNB_ADDRESS`。地址写入被 `.gitignore` 排除的 `script/network/<network>/addresses.dex.params`，不写进 submodule。

`00_init.sh` 要求 RPC 的实际 Chain ID 等于 `network.params` 里的 `CHAIN_ID`。`Deploy.s.sol` 在广播前先模拟：WBNB 必须是已部署合约，Factory 的 `feeTo` 与 `feeToSetter` 必须为零，Router 的 `factory`/`WETH` 必须指向本次结果，否则整笔回滚。若 Router 交易失败，Factory 仍可单独保留；广播记录位于 Foundry 的 `broadcast/` 目录。

LOVE20 的 Launch 与 Stake 配置同一个 Factory，Stake 的 Router 配置为这里部署的 Router02：添加/移除流动性直接调用 Pair，手续费换币调用 Router 的 `getAmountsOut` 与 `swapExactTokensForTokens`。

## 决策与许可证

[术语表](CONTEXT.md) · [永久关闭抽成](docs/adr/0001-disable-protocol-fee.md) · [合约范围](docs/adr/0002-preserve-complete-selected-contracts.md) · [上游溯源](docs/adr/0003-record-upstream-baseline.md)

上游许可证原样保留于各子模块：[v2-core](lib/v2-core/LICENSE)、[v2-periphery](lib/v2-periphery/LICENSE)、[solidity-lib](lib/solidity-lib/LICENSE)。本项目新增脚本和测试采用 GPL-3.0-or-later。
