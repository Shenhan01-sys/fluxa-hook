// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FluxaLPShares is ERC20 {
    address public immutable hook;
    error OnlyHook();

    constructor(address _hook) ERC20("Fluxa LP Shares", "FLUXA-LP") {
        hook = _hook;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    function mint(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyHook {
        _burn(account, amount);
    }
}
