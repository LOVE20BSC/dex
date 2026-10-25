// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {DeployWETH} from "../script/deploy/DeployWETH.s.sol";
import {WETH9Configurable} from "../script/WETH9Configurable.sol";
import {TestHelpers, TestVm} from "./TestHelpers.sol";

contract DeployWETHHarness is DeployWETH {
    function validateConfigForTest(WethConfig memory config) external view {
        _validateConfig(config);
    }

    function validateExternalForTest(address weth) external {
        _validateExternalWeth(weth);
    }
}

contract MockWrongDecimals {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MockNoDeposit {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockNoWithdraw {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function deposit() external payable {}
}

contract DeployWETHTest {
    TestVm private constant testVm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    DeployWETHHarness private deployer;

    function setUp() public {
        deployer = new DeployWETHHarness();
    }

    function testAcceptsExternalConfig() public view {
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(this), name: "", symbol: ""})
        );
    }

    function testAcceptsLocalConfig() public view {
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(0), name: "Wrapped", symbol: "WETH"})
        );
    }

    function testRejectsExternalWithNameOrSymbol() public {
        testVm.expectRevert(TestHelpers.errorData("WETH_ADDRESS and WETH_NAME/WETH_SYMBOL are mutually exclusive"));
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(this), name: "Wrapped", symbol: ""})
        );
    }

    function testRejectsLocalWithoutNameOrSymbol() public {
        testVm.expectRevert(TestHelpers.errorData("WETH_NAME and WETH_SYMBOL are required"));
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(0), name: "", symbol: "WETH"})
        );
        testVm.expectRevert(TestHelpers.errorData("WETH_NAME and WETH_SYMBOL are required"));
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(0), name: "Wrapped", symbol: ""})
        );
    }

    function testRejectsExternalWithoutCode() public {
        testVm.expectRevert(TestHelpers.errorData("WETH_ADDRESS must be a deployed contract"));
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid, externalWeth: address(0x1234), name: "", symbol: ""})
        );
    }

    function testRejectsChainMismatch() public {
        testVm.expectRevert(TestHelpers.errorData("Chain ID mismatch"));
        deployer.validateConfigForTest(
            DeployWETH.WethConfig({chainId: block.chainid + 1, externalWeth: address(this), name: "", symbol: ""})
        );
    }

    function testExternalWethMustSupportDepositAndWithdraw() public {
        WETH9Configurable weth = new WETH9Configurable("Wrapped", "WETH");
        deployer.validateExternalForTest(address(weth));
    }

    function testExternalWethRejectsWrongDecimals() public {
        address mock = address(new MockWrongDecimals());
        testVm.expectRevert(TestHelpers.errorData("WETH must report 18 decimals"));
        deployer.validateExternalForTest(mock);
    }

    function testExternalWethRejectsMissingDeposit() public {
        address mock = address(new MockNoDeposit());
        testVm.expectRevert(TestHelpers.errorData("WETH deposit unavailable"));
        deployer.validateExternalForTest(mock);
    }

    function testExternalWethRejectsMissingWithdraw() public {
        address mock = address(new MockNoWithdraw());
        testVm.expectRevert(TestHelpers.errorData("WETH withdraw unavailable"));
        deployer.validateExternalForTest(mock);
    }
}
