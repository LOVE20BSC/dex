#!/usr/bin/env bash
set -euo pipefail

# 入口：纯编排。自身不 source 任何环境文件——各步骤各自加载自己的输入，
# 统一 <step>.sh <network> 一种调用形态，步骤之间互不调用、互不依赖预载环境。
# 模块顺序即依赖顺序：deploy 1x / check 2x / verify 3x；WETH 模块（11/21/31）在前，
# UniswapV2 模块（12/22/32）在后。
# 将来新增合约时，新建模块自己的步骤脚本与 one_click_deploy_<名称>.sh，现有文件不用改。
# 用法：script/deploy/one_click_deploy.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
network="${1:?usage: script/deploy/one_click_deploy.sh <network>}"

NETWORK_DIR="$DEX_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# keystore 密码整次运行只解析一次：先重置（不继承调用方环境里的旧值，避免上次运行的
# 残留密码静默复用），再读 .account 的密码行；两者都没有则交互输入一次并导出，全部
# 部署步骤沿用（两个部署模块不会各弹一次窗）。步骤单独运行时仍自行按
# 环境变量 → .account → 交互 解析。入口只读取密码行，不 source 配置文件。
export KEYSTORE_PASSWORD=""
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account"
    exit 1
fi
configured_password=$(grep -E '^KEYSTORE_PASSWORD=' "$NETWORK_DIR/.account" | tail -1 | cut -d= -f2- || true)
if [ -n "$configured_password" ]; then
    export KEYSTORE_PASSWORD="$configured_password"
fi
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for deployment:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    export KEYSTORE_PASSWORD
fi

# 部署与校验是分开的步骤，校验失败不应覆盖上次已保存的地址：先备份，校验通过后丢弃，失败则回滚。
BACKUP_DIR="$(mktemp -d)"
trap 'rm -rf "$BACKUP_DIR"' EXIT
for file in addresses.weth.params addresses.uniswapv2.params; do
    [ -f "$NETWORK_DIR/$file" ] && cp "$NETWORK_DIR/$file" "$BACKUP_DIR/$file"
    true
done

# 步骤一/二：合约部署与初始化（各模块自载入部署输入）。失败时地址文件尚未写入，无需回滚。
bash "$SCRIPT_DIR/11_deploy_weth.sh" "$network"
bash "$SCRIPT_DIR/12_deploy_uniswapv2.sh" "$network"

# 步骤三/四：校验部署与初始化是否正确（各模块自载入校验文件，失败回滚已保存地址）。
if ! bash "$SCRIPT_DIR/21_check_weth.sh" "$network" || ! bash "$SCRIPT_DIR/22_check_uniswapv2.sh" "$network"; then
    for file in addresses.weth.params addresses.uniswapv2.params; do
        if [ -f "$BACKUP_DIR/$file" ]; then
            cp "$BACKUP_DIR/$file" "$NETWORK_DIR/$file"
        else
            rm -f "$NETWORK_DIR/$file"
        fi
    done
    echo "Error: post-deployment check failed; the previously saved addresses were restored."
    exit 1
fi

# 步骤五/六：合约开源验证（自载入地址文件）。链不支持开源验证时自行跳过；
# 外部 WETH 不验证（由对方部署维护），本地 WETH 走 31_verify_weth.sh。
bash "$SCRIPT_DIR/31_verify_weth.sh" "$network"
bash "$SCRIPT_DIR/32_verify.sh" "$network"

echo "✓ Deployment completed: $network"
