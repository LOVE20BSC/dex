#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    Verifying DEX Contract Deployment  ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# 检查所有合约地址是否已设置
if [ -z "${FACTORY_ADDRESS:-}" ] || [ -z "${ROUTER_ADDRESS:-}" ] || [ -z "${WBNB_ADDRESS:-}" ]; then
    echo -e "${RED}✗ Error: Not all contract addresses are set${NC}"
    exit 1
fi

# 辅助函数：标准化输出（去掉引号和科学计数法标记）
normalize_output() {
    local value="$1"
    # 去掉首尾引号
    value="${value%\"}"
    value="${value#\"}"
    # 去掉科学计数法标记 [1e18]
    value="${value% \[*\]}"
    echo "$value"
}

# 辅助函数：验证单个值
verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    # 标准化两个值
    expected=$(normalize_output "$expected")
    actual=$(normalize_output "$actual")

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${GRAY}Actual:   ${actual}${NC}"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${YELLOW}Actual:   ${actual}${NC}"
        return 1
    fi
}

# 辅助函数：验证合约是否部署
verify_deployed() {
    local name=$1
    local address=$2

    local code=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null)
    if [ "$code" = "0x" ]; then
        echo -e "${RED}✗ $name not deployed at $address${NC}"
        return 1
    fi
    return 0
}

# 辅助函数：打印合约头部
print_contract_header() {
    local num=$1
    local name=$2
    local address=$3
    echo ""
    echo -e "${BLUE}[$num/3]${NC} ${CYAN}${name}${NC}"
    echo -e "${GRAY}      ${address}${NC}"
}

FAILED=0

# 1. 验证 WBNB (或测试网的 WETH)
if [ "${DEPLOY_TEST_WBNB:-false}" = "true" ]; then
    print_contract_header "1" "WETH9 (TestWBNB)" "$WBNB_ADDRESS"
    verify_deployed "WETH9" "$WBNB_ADDRESS" || ((FAILED++))

    ACTUAL_NAME=$(cast call "$WBNB_ADDRESS" "name()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "name" "Wrapped Ether" "$ACTUAL_NAME" || ((FAILED++))

    ACTUAL_SYMBOL=$(cast call "$WBNB_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "symbol" "WETH" "$ACTUAL_SYMBOL" || ((FAILED++))
else
    print_contract_header "1" "WBNB" "$WBNB_ADDRESS"
    verify_deployed "WBNB" "$WBNB_ADDRESS" || ((FAILED++))

    ACTUAL_NAME=$(cast call "$WBNB_ADDRESS" "name()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "name" "Wrapped BNB" "$ACTUAL_NAME" || ((FAILED++))

    ACTUAL_SYMBOL=$(cast call "$WBNB_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "symbol" "WBNB" "$ACTUAL_SYMBOL" || ((FAILED++))
fi

# 2. 验证 Factory
print_contract_header "2" "PancakeFactory" "$FACTORY_ADDRESS"
verify_deployed "Factory" "$FACTORY_ADDRESS" || ((FAILED++))

ACTUAL_FEETO=$(cast call "$FACTORY_ADDRESS" "feeTo()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "feeTo" "0x0000000000000000000000000000000000000000" "$ACTUAL_FEETO" || ((FAILED++))

ACTUAL_FEETOSETTER=$(cast call "$FACTORY_ADDRESS" "feeToSetter()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "feeToSetter" "0x0000000000000000000000000000000000000000" "$ACTUAL_FEETOSETTER" || ((FAILED++))

# 3. 验证 Router
print_contract_header "3" "PancakeRouter" "$ROUTER_ADDRESS"
verify_deployed "Router" "$ROUTER_ADDRESS" || ((FAILED++))

ACTUAL_FACTORY=$(cast call "$ROUTER_ADDRESS" "factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "factory" "$FACTORY_ADDRESS" "$ACTUAL_FACTORY" || ((FAILED++))

ACTUAL_WETH=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "WETH" "$WBNB_ADDRESS" "$ACTUAL_WETH" || ((FAILED++))

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All verifications passed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
else
    echo -e "${RED}✗ $FAILED verification(s) failed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    exit 1
fi
