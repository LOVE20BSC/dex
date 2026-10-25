// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {WETH9Configurable} from "../WETH9Configurable.sol";

interface Vm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envUint(string calldata name) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
    function prank(address sender) external;
    function toString(address value) external pure returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

interface IWETHLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract DeployWETH {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant PROBE = address(0xdEaD);

    struct WethConfig {
        uint256 chainId;
        address externalWeth;
        string name;
        string symbol;
    }

    function run() public returns (address weth) {
        WethConfig memory config = _loadConfig();
        _validateConfig(config);

        if (config.externalWeth != address(0)) {
            _validateExternalWeth(config.externalWeth);
            weth = config.externalWeth;
        } else {
            weth = _deploy(config);
        }

        _validateDeployment(config, weth);
        _writeAddresses(weth);
    }

    function _loadConfig() internal view returns (WethConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.externalWeth = vm.envOr("WETH_ADDRESS", address(0));
        config.name = vm.envOr("WETH_NAME", string(""));
        config.symbol = vm.envOr("WETH_SYMBOL", string(""));
    }

    function _validateConfig(WethConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
        if (config.externalWeth != address(0)) {
            require(
                bytes(config.name).length == 0 && bytes(config.symbol).length == 0,
                "WETH_ADDRESS and WETH_NAME/WETH_SYMBOL are mutually exclusive"
            );
            require(config.externalWeth.code.length != 0, "WETH_ADDRESS must be a deployed contract");
        } else {
            require(
                bytes(config.name).length != 0 && bytes(config.symbol).length != 0,
                "WETH_NAME and WETH_SYMBOL are required"
            );
        }
    }

    function _validateExternalWeth(address weth) internal {
        require(IWETHLike(weth).decimals() == 18, "WETH must report 18 decimals");
        vm.prank(PROBE);
        (bool deposited,) = weth.call(abi.encodeCall(IWETHLike.deposit, ()));
        require(deposited, "WETH deposit unavailable");
        vm.prank(PROBE);
        (bool withdrawn,) = weth.call(abi.encodeCall(IWETHLike.withdraw, (0)));
        require(withdrawn, "WETH withdraw unavailable");
    }

    function _deploy(WethConfig memory config) internal returns (address weth) {
        vm.startBroadcast();
        weth = address(new WETH9Configurable(config.name, config.symbol));
        vm.stopBroadcast();
    }

    function _validateDeployment(WethConfig memory config, address weth) internal view {
        require(weth.code.length != 0, "Deployment failed");
        if (config.externalWeth != address(0)) {
            require(weth == config.externalWeth, "External WETH mismatch");
            return;
        }
        require(
            keccak256(bytes(IWETHLike(weth).name())) == keccak256(bytes(config.name)), "WETH name mismatch"
        );
        require(
            keccak256(bytes(IWETHLike(weth).symbol())) == keccak256(bytes(config.symbol)),
            "WETH symbol mismatch"
        );
        require(IWETHLike(weth).decimals() == 18, "WETH must report 18 decimals");
    }

    function _writeAddresses(address weth) internal {
        string memory addressesFile = vm.envOr("ADDRESSES_FILE", string(""));
        if (bytes(addressesFile).length != 0) {
            vm.writeFile(addressesFile, string.concat("WETH_ADDRESS=", vm.toString(weth), "\n"));
        }
    }
}
