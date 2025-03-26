// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestUSD is ERC20, Ownable {
    address public cauldron; // Only Cauldron can mint/burn

    modifier onlyCauldron() {
        require(msg.sender == cauldron, "Only Cauldron");
        _;
    }

    constructor() ERC20("TestUSD", "TUSD") Ownable() {}

    function setCauldron(address _cauldron) external onlyOwner {
        require(cauldron == address(0), "Cauldron already set");
        cauldron = _cauldron;
    }

    function mint(address to, uint256 amount) external onlyCauldron {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyCauldron {
        _burn(from, amount);
    }
}
