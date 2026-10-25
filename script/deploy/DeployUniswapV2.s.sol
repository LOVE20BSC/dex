// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface Vm {
    function envAddress(string calldata name) external view returns (address);
    function envString(string calldata name) external view returns (string memory);
    function envUint(string calldata name) external view returns (uint256);
    function getCode(string calldata artifactPath) external view returns (bytes memory);
    function startBroadcast() external;
    function stopBroadcast() external;
    function toString(address value) external pure returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

contract DeployUniswapV2 {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 internal constant PAIR_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    bytes32 internal constant FACTORY_CREATION_HASH = 0x8716c49c3c982e1d8b8beaab0a95d88cc5ec06681dded0f951fa1f3059c1e32a;
    bytes32 internal constant ROUTER_CREATION_HASH = 0xdcc6e896a61e7aa6adbaad7c377d2f14c32c7ded40e258ea079932d43678295b;

    struct UniswapConfig {
        uint256 chainId;
        address weth;
    }

    function run() public returns (IUniswapV2Factory factory, IUniswapV2Router02 router) {
        UniswapConfig memory config = _loadConfig();
        _validateConfig(config);

        bytes memory factoryArtifact = vm.getCode("build/core/UniswapV2Factory.sol/UniswapV2Factory.json");
        bytes memory routerArtifact =
            vm.getCode("build/periphery/UniswapV2Router02.sol/UniswapV2Router02.json");
        _validateSourceArtifacts(factoryArtifact, routerArtifact);

        bytes memory factoryCode = abi.encodePacked(factoryArtifact, abi.encode(address(0)));

        vm.startBroadcast();
        factory = IUniswapV2Factory(_deploy(factoryCode));
        bytes memory routerCode = abi.encodePacked(routerArtifact, abi.encode(address(factory), config.weth));
        router = IUniswapV2Router02(_deploy(routerCode));
        vm.stopBroadcast();

        _validateDeployment(config, address(factory), address(router));
        _writeAddresses(address(factory), address(router));
    }

    function _loadConfig() internal view returns (UniswapConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.weth = vm.envAddress("WETH_ADDRESS");
    }

    function _validateConfig(UniswapConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
        require(config.weth.code.length != 0, "WETH must be a deployed contract");
    }

    function _validateSourceArtifacts(bytes memory factoryArtifact, bytes memory routerArtifact) internal view {
        require(
            keccak256(vm.getCode("build/core/UniswapV2Pair.sol/UniswapV2Pair.json")) == PAIR_INIT_CODE_HASH,
            "Pair bytecode does not match the upstream Router"
        );
        require(keccak256(factoryArtifact) == FACTORY_CREATION_HASH, "Factory bytecode mismatch");
        require(keccak256(routerArtifact) == ROUTER_CREATION_HASH, "Router bytecode mismatch");
    }

    function _validateDeployment(UniswapConfig memory config, address factory, address router) internal view {
        require(factory.code.length != 0, "Factory deployment failed");
        require(router.code.length != 0, "Router deployment failed");
        require(
            IUniswapV2Factory(factory).feeTo() == address(0)
                && IUniswapV2Factory(factory).feeToSetter() == address(0),
            "Protocol fee is not locked"
        );
        require(
            IUniswapV2Router02(router).factory() == factory && IUniswapV2Router02(router).WETH() == config.weth,
            "Router configuration mismatch"
        );
    }

    function _deploy(bytes memory code) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "Deployment failed");
    }

    function _writeAddresses(address factory, address router) internal {
        vm.writeFile(
            vm.envString("ADDRESSES_FILE"),
            string.concat(
                "FACTORY_ADDRESS=",
                vm.toString(factory),
                "\nROUTER_ADDRESS=",
                vm.toString(router),
                "\n"
            )
        );
    }
}
