// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {WETH9Configurable} from "./WETH9Configurable.sol";

interface Vm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function startBroadcast() external;
    function stopBroadcast() external;
    function toString(address value) external pure returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

contract DeployWETH {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() public returns (address weth) {
        string memory name = vm.envOr("WETH_NAME", string(""));
        string memory symbol = vm.envOr("WETH_SYMBOL", string(""));
        require(bytes(name).length != 0 && bytes(symbol).length != 0, "WETH_NAME and WETH_SYMBOL are required");

        vm.startBroadcast();
        weth = address(new WETH9Configurable(name, symbol));
        vm.stopBroadcast();
        require(weth.code.length != 0, "Deployment failed");

        string memory addressesFile = vm.envOr("ADDRESSES_FILE", string(""));
        if (bytes(addressesFile).length != 0) {
            vm.writeFile(addressesFile, string.concat("WETH_ADDRESS=", vm.toString(weth), "\n"));
        }
    }
}
