// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface Vm {
    function envAddress(string calldata name) external view returns (address);
    function envOr(string calldata name, bool defaultValue) external view returns (bool);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function getCode(string calldata artifactPath) external view returns (bytes memory);
    function startBroadcast() external;
    function stopBroadcast() external;
    function toString(address value) external pure returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

contract Deploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 internal constant PAIR_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function run() public returns (IUniswapV2Factory factory, IUniswapV2Router02 router) {
        address wbnb = vm.envAddress("WBNB");
        require(wbnb.code.length != 0, "WBNB must be a deployed contract");
        require(
            keccak256(vm.getCode("build/core/UniswapV2Pair.sol/UniswapV2Pair.json")) == PAIR_INIT_CODE_HASH,
            "Pair bytecode does not match the upstream Router"
        );
        bytes memory factoryCode = abi.encodePacked(
            vm.getCode("build/core/UniswapV2Factory.sol/UniswapV2Factory.json"), abi.encode(address(0))
        );
        bytes memory routerCode = vm.getCode("build/periphery/UniswapV2Router02.sol/UniswapV2Router02.json");

        vm.startBroadcast();
        factory = IUniswapV2Factory(_deploy(factoryCode));
        router = IUniswapV2Router02(_deploy(abi.encodePacked(routerCode, abi.encode(address(factory), wbnb))));
        vm.stopBroadcast();

        require(factory.feeTo() == address(0) && factory.feeToSetter() == address(0), "Protocol fee is not locked");
        require(router.factory() == address(factory) && router.WETH() == wbnb, "Router configuration mismatch");

        if (vm.envOr("WRITE_ADDRESS_FILE", false)) {
            string memory network = vm.envOr("network", string("anvil31337_dev"));
            string memory path = string.concat("script/network/", network, "/address.params");
            vm.writeFile(
                path,
                string.concat(
                    "FACTORY_ADDRESS=",
                    vm.toString(address(factory)),
                    "\nROUTER_ADDRESS=",
                    vm.toString(address(router)),
                    "\n"
                )
            );
        }
    }

    function _deploy(bytes memory code) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "Deployment failed");
    }
}
