// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CZEEAirdrop is Ownable {

    IERC20 public token;

    uint256 public airdropPerAccountAmount;
    uint256 public maxAirdropsAmount;
    uint256 public releasedAirdropAmount;
    uint256 public remainigAirdropAmount;

    uint256 public airdropStartTime;
    uint256 public airdropEndTime;
    uint256 public airdropDuration;

    bool public isStarted;

    mapping(address => bool) public isInAirdropList;

    constructor() Ownable(msg.sender) {}

    //------------------
    // Admin Functions
    //------------------

    /*
        1. Owner calls this function to put airdrop tokens into contract.
            Owner needs to call the token's approve() function before call depositTokens()
            approve(CZEEAirdrop.address, _amount)
    */
    function depositTokens(address _token, uint256 _amount) public onlyOwner {
        token = IERC20(_token);
        token.transferFrom(msg.sender, address(this), _amount);

        maxAirdropsAmount += _amount;
    }

    /* 
        2. Owner calls this function to start the airdrop.
            _airdropDeadline:             days remain to airdrop deadline
            _airdropPerAccountAmount:     ex. 100e18 ~ 100000000000000000000
    */
    function startAirdrop(uint256 _airdropDeadline, uint256 _airdropPerAccountAmount) public onlyOwner {
        require(!isStarted, "Airdrop has been started already!");
        require(maxAirdropsAmount > 0, "Add tokens to the contract, before starting the Airdrop");

        airdropDuration = _airdropDeadline * 1 days;
        airdropPerAccountAmount = _airdropPerAccountAmount;

        airdropStartTime = block.timestamp;
        airdropEndTime = airdropStartTime + airdropDuration;

        isStarted = true;
        remainigAirdropAmount = maxAirdropsAmount;
    }

    // 3. The owner calls this function to batch send airdrop tokens
    function sendAirdrops(address[] memory acs) public onlyOwner {
        require(isStarted, "Airdrop hasn't started yet!");

        for(uint i; i<acs.length; i++) {
            address acc = acs[i];
            // If the account isn't already on the airdrop list!
            if(!isInAirdropList[acc])
                sendAirdropToAcc(acc);
        }
    }

    // transfer airdrop tokens to an address and put it in the airdrop list
    function sendAirdropToAcc(address acc) internal {
        require(releasedAirdropAmount < maxAirdropsAmount);
        require(remainigAirdropAmount >= airdropPerAccountAmount, "Not enough tokens for airdrop");

        token.transfer(acc, airdropPerAccountAmount);

        isInAirdropList[acc] = true;
        remainigAirdropAmount -= airdropPerAccountAmount;
        releasedAirdropAmount += airdropPerAccountAmount;
    }

    // 4. The owner calls this function to withdraw the remaining tokens in the contract.
    function withdrawTokens(uint amount) public onlyOwner {
        require(amount <= getAirdripTokensBalance(), "Not enough token");
        token.transfer(msg.sender, amount);
    }

    //------------------
    // get Functions
    //------------------

    function IsAccInAirdropList(address acc) public view returns(bool) {
        return isInAirdropList[acc];
    }

    function getAirdropPerAccountAmount() public view returns(uint256) {
        return airdropPerAccountAmount;
    }

    function getAirdripTokensBalance() public view returns(uint256) {
        return token.balanceOf(address(this));
    }
}