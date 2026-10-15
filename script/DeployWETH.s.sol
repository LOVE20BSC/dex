// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

interface Vm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function getCode(string calldata artifactPath) external view returns (bytes memory);
    function parseAddress(string calldata value) external pure returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
    function toString(address value) external pure returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

contract DeployWETH {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() public returns (address weth) {
        // dex.params 配置了 WETH 地址（公共链的官方 WETH，BSC 上即官方 WBNB）时使用它；
        // 未配置时（本地 anvil）部署上游 WETH9 充当 WETH。
        string memory wethConfig = vm.envOr("WETH_ADDRESS", string(""));
        if (bytes(wethConfig).length == 0) {
            vm.startBroadcast();
            weth = _deploy(vm.getCode("build/periphery/WETH9.sol/WETH9.json"));
            vm.stopBroadcast();
        } else {
            weth = vm.parseAddress(wethConfig);
        }
        require(weth.code.length != 0, "WETH must be a deployed contract");

        string memory addressesFile = vm.envOr("ADDRESSES_FILE", string(""));
        if (bytes(addressesFile).length != 0) {
            vm.writeFile(addressesFile, string.concat("WETH_ADDRESS=", vm.toString(weth), "\n"));
        }
    }

    function _deploy(bytes memory code) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "Deployment failed");
    }
}
