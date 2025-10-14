// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Helix Dollar ($HELIXD)
 * @notice Minimal ERC20 with 6 decimals. All supply minted to the deployer.
 */
contract HelixDToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("Helix Dollar", "HELIXD") {
        _mint(msg.sender, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
