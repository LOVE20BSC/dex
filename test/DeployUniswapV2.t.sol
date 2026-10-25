// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {DeployUniswapV2} from "../script/deploy/DeployUniswapV2.s.sol";
import {WETH9Configurable} from "../script/WETH9Configurable.sol";
import {TestHelpers, TestVm} from "./TestHelpers.sol";

contract DeployUniswapV2Harness is DeployUniswapV2 {
    function validateConfigForTest(UniswapConfig memory config) external view {
        _validateConfig(config);
    }

    function validateSourceForTest() external view {
        _validateSourceArtifacts(
            vm.getCode("build/core/UniswapV2Factory.sol/UniswapV2Factory.json"),
            vm.getCode("build/periphery/UniswapV2Router02.sol/UniswapV2Router02.json")
        );
    }
}

contract DeployUniswapV2Test {
    TestVm private constant testVm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    DeployUniswapV2Harness private deployer;
    address private weth;

    function setUp() public {
        deployer = new DeployUniswapV2Harness();
        weth = address(new WETH9Configurable("Wrapped", "WETH"));
    }

    function testAcceptsValidConfig() public view {
        deployer.validateConfigForTest(
            DeployUniswapV2.UniswapConfig({chainId: block.chainid, weth: weth})
        );
    }

    function testRejectsChainMismatch() public {
        testVm.expectRevert(TestHelpers.errorData("Chain ID mismatch"));
        deployer.validateConfigForTest(
            DeployUniswapV2.UniswapConfig({chainId: block.chainid + 1, weth: weth})
        );
    }

    function testRejectsNonContractWeth() public {
        testVm.expectRevert(TestHelpers.errorData("WETH must be a deployed contract"));
        deployer.validateConfigForTest(
            DeployUniswapV2.UniswapConfig({chainId: block.chainid, weth: address(0x1234)})
        );
    }

    function testSourceArtifactsMatchPinnedHashes() public view {
        deployer.validateSourceForTest();
    }
}
