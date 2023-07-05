// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVeSlokToken is IERC20 {
    function usageAllocations(
        address userAddress,
        address usageAddress
    ) external view returns (uint256 allocation);

    function allocateFromUsage(address userAddress, uint256 amount) external;

    function convertTo(uint256 amount, address to) external;

    function deallocateFromUsage(address userAddress, uint256 amount) external;
}
