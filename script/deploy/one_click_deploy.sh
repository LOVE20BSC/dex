#!/usr/bin/env bash

# 拼装：首次全量部署 = 00 初始化 + 01 部署 + 99 复核。
# 将来新增合约时，新建 02_deploy_<名称>.sh 与 one_click_deploy_<名称>.sh，按同样方式拼装即可。
# 用法：script/deploy/one_click_deploy.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
network="${1:?usage: script/deploy/one_click_deploy.sh <network>}"

source "$SCRIPT_DIR/00_init.sh" "$network"
bash "$SCRIPT_DIR/01_deploy.sh"
bash "$SCRIPT_DIR/99_check.sh" "$network"
echo "✓ Deployment completed: $network"
