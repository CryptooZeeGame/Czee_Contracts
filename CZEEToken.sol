// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ICZEEAirdrop {
    function IsAccInAirdropList(address acc) external view returns(bool);
    function getAirdropPerAccountAmount() external view returns(uint256);
}

contract CryptozeeToken is ERC20, ERC20Burnable, Ownable {

    uint256 private immutable tokenTotalSupply = 200_000_000_000 * 10 ** decimals();
    uint256 private immutable tokenReleaseTimestamp;
    uint256 private airdropTimeLock = 60 days;
    ICZEEAirdrop public airdrop;
    error DoNotSendFundsDirectlyToTheContract();

    constructor() ERC20("CryptozeeToken", "CZEE") Ownable(msg.sender) {        
        _mint(owner(), tokenTotalSupply);
        tokenReleaseTimestamp = block.timestamp;
    }

    modifier checkTransferAllowance(address acc, uint amount) {
        if (!isPassedTimeLock())
            if(isGotAirdrop(acc))
                require(haveEnoughBalance(acc, amount), "You aren't allowed to transfer airdrop tokens yet!");
        _;
    }

    //------------------
    // Inherited functions
    //------------------

    function transfer(
        address to, 
        uint256 value
        ) public virtual override checkTransferAllowance(msg.sender, value) returns (bool) {
        return super.transfer(to, value);
    }

    function transferFrom(
        address from, 
        address to, 
        uint256 value
        ) public virtual override checkTransferAllowance(from, value) returns (bool) {
        return super.transferFrom(from, to, value);
    }

    //------------------
    // admin functions
    //------------------

    function setAirdrop(address _airdropAdr) external onlyOwner {
        airdrop = ICZEEAirdrop(_airdropAdr);
    }

    //------------------
    // get functions
    //------------------

    function isGotAirdrop(address acc) public view returns(bool) {
        return airdrop.IsAccInAirdropList(acc);
    }

    function isPassedTimeLock() public view returns(bool) {
        return (block.timestamp >= tokenReleaseTimestamp + airdropTimeLock);
    }

    function haveEnoughBalance(address acc, uint amount) public view returns(bool) {
        return (balanceOf(acc) - airdrop.getAirdropPerAccountAmount() >= amount);
    }

    //------------------
    // other functions
    //------------------
    receive() external payable {
        revert DoNotSendFundsDirectlyToTheContract();
    }
}