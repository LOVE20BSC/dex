// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.37;

interface TestVm {
    function expectRevert(bytes calldata revertData) external;
}

library TestHelpers {
    function errorData(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }
}
