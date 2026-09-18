// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

import {Deploy} from "../script/Deploy.s.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

interface TestVm {
    function setEnv(string calldata name, string calldata value) external;
    function toString(address value) external pure returns (string memory);
    function deal(address account, uint256 balance) external;
    function assume(bool condition) external;
    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
}

contract DexTest is Deploy {
    TestVm private constant testVm = TestVm(address(vm));
    IUniswapV2Factory private factory;
    IUniswapV2Router02 private router;
    IUniswapV2Pair private pair;
    IERC20 private token;
    IWETH private weth;

    function setUp() public {
        token = IERC20(_deploy(abi.encodePacked(vm.getCode("build/core/ERC20.sol/ERC20.json"), abi.encode(1e27))));
        weth = IWETH(_deploy(vm.getCode("build/periphery/WETH9.sol/WETH9.json")));
        testVm.setEnv("WBNB", testVm.toString(address(weth)));
        (factory, router) = run();
        pair = IUniswapV2Pair(factory.createPair(address(token), address(weth)));
        testVm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        require(token.approve(address(router), type(uint256).max));
        require(IERC20(address(weth)).approve(address(router), type(uint256).max));
    }

    function test_DeploymentAndPairAddress() public view {
        require(factory.feeTo() == address(0) && factory.feeToSetter() == address(0), "Protocol fee unlocked");
        require(router.factory() == address(factory) && router.WETH() == address(weth), "Wrong Router setup");
        (address token0, address token1) =
            address(token) < address(weth) ? (address(token), address(weth)) : (address(weth), address(token));
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", address(factory), keccak256(abi.encodePacked(token0, token1)), PAIR_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        require(address(pair) == predicted, "Factory bytecode does not match Router hash");
        require(factory.getPair(token1, token0) == predicted && factory.allPairsLength() == 1, "Wrong registry");
    }

    function testFuzz_NoAccountCanRestoreProtocolFee(address caller, address recipient) public {
        testVm.assume(caller != address(0));
        bytes memory forbidden = abi.encodeWithSignature("Error(string)", "UniswapV2: FORBIDDEN");
        testVm.expectRevert(forbidden);
        testVm.prank(caller);
        factory.setFeeTo(recipient);
        testVm.expectRevert(forbidden);
        testVm.prank(caller);
        factory.setFeeToSetter(recipient);
        require(factory.feeTo() == address(0) && factory.feeToSetter() == address(0), "Protocol fee changed");
    }

    function test_LiquiditySwapAndBurnWithoutProtocolFee() public {
        (,, uint256 firstLp) = router.addLiquidity(
            address(token), address(weth), 1000 ether, 10 ether, 1000 ether, 10 ether, address(this), block.timestamp
        );
        require(firstLp == 100 ether - 1000 && pair.totalSupply() == 100 ether, "Wrong initial mint");
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        uint256 expectedOut = (uint256(10 ether) * 997 * 10 ether) / (1000 ether * 1000 + 10 ether * 997);
        uint256 quoted = router.getAmountsOut(10 ether, path)[1];
        require(quoted == expectedOut, "Swap fee is not 0.30%");
        uint256 balanceBefore = IERC20(address(weth)).balanceOf(address(this));
        router.swapExactTokensForTokens(10 ether, quoted, path, address(this), block.timestamp);
        require(IERC20(address(weth)).balanceOf(address(this)) - balanceBefore == quoted, "Swap missed quote");

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 amount0 = reserve0 / 10;
        uint256 amount1 = reserve1 / 10;
        require(IERC20(pair.token0()).transfer(address(pair), amount0));
        require(IERC20(pair.token1()).transfer(address(pair), amount1));
        uint256 expectedMint = amount0 * supply / reserve0;
        uint256 otherMint = amount1 * supply / reserve1;
        if (otherMint < expectedMint) expectedMint = otherMint;
        uint256 minted = pair.mint(address(this));
        require(minted == expectedMint && pair.totalSupply() == supply + minted, "Unexpected fee LP minted");

        (reserve0, reserve1,) = pair.getReserves();
        supply = pair.totalSupply();
        uint256 lp = pair.balanceOf(address(this));
        require(pair.transfer(address(pair), lp));
        (uint256 out0, uint256 out1) = pair.burn(address(this));
        require(out0 == lp * reserve0 / supply && out1 == lp * reserve1 / supply, "Wrong redemption");
        require(pair.totalSupply() == 1000 && pair.kLast() == 0, "Protocol fee accrued");
    }

    function test_SwapFailureLeavesFundsUntouched() public {
        router.addLiquidity(address(token), address(weth), 1000 ether, 10 ether, 0, 0, address(this), block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        uint256 quoted = router.getAmountsOut(10 ether, path)[1];
        uint256 balance = token.balanceOf(address(this));
        testVm.expectRevert(abi.encodeWithSignature("Error(string)", "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"));
        router.swapExactTokensForTokens(10 ether, quoted + 1, path, address(this), block.timestamp);
        require(token.balanceOf(address(this)) == balance, "Failed swap moved funds");
    }
}
