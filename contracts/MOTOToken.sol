// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  MOTOToken
 * @notice Utility token for the MotoChain / RideTrue protocol.
 *
 *  Earning model:
 *    - Mechanics earn MOTO per confirmed service record (minted by VINToken).
 *    - Riders earn MOTO per insurance policy activated (minted by RideTrue).
 *
 *  Spending model:
 *    - Mechanics stake MOTO to register (held by VINToken; slashed on misconduct).
 *    - Riders holding ≥ 1 000 MOTO get a 20% premium discount in RideTrue.
 *    - Future: governance votes, fee payments.
 *
 *  10 million tokens minted to deployer at launch for initial distribution.
 *  Protocol contracts (VINToken, RideTrue) are granted minter roles by the owner.
 */
contract MOTOToken is ERC20, Ownable {

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    mapping(address => bool) public minters;

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    constructor() ERC20("MOTO Token", "MOTO") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    // ── Minter management ─────────────────────────────────────────────────────

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    // ── Token operations ──────────────────────────────────────────────────────

    /**
     * @notice Mint MOTO to a recipient. Only owner or authorized protocol contracts.
     */
    function mint(address to, uint256 amount) external {
        require(minters[msg.sender] || msg.sender == owner(), "Not authorized to mint");
        _mint(to, amount);
    }

    /**
     * @notice Burn caller's own MOTO (e.g. VINToken burning slashed mechanic stakes
     *         it holds in its own balance).
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
