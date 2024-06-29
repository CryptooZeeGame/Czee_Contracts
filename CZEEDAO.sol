// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CZEEDAO is Ownable, ReentrancyGuard {

    using SafeMath for uint256;

    /* ================= Token info  ================= */
    IERC20 CZEE;
    uint256 public czeeTotalSupply;

    /* ================= Category info  ================= */
    uint8[] catIds;
    
    struct Category {
        string title;
        uint256 shareOfTotalSup; // Multiplied by 100  ex: 1.5 --> 150
    }

    // CategoryID => Category Struct
    mapping(uint256 => Category) categories;

    /* ================= Release info  ================= */
    uint256 releaseStep = 60 days;  // seconds, minutes, hours, days, weeks, years
    uint256 scheduleStartTime;

    // CategoryID => releaseSchedules Array
    mapping(uint256 => uint256[30]) releaseSchedules;

    /* ================= Beneficiary info  ================= */
    address[] beneficiaryAdrs;

    struct Beneficiary {
        uint256 catId;
        uint256 shareOfCategory;    // Multiplied by 100  ex: 1.5 --> 150
        uint256 withdrawn;          // How many tokens, this Beneficiary has took out of account, until now.
    }

    // BeneficiaryAddress => Beneficiary Struct
    mapping(address => Beneficiary) beneficiaries;

    /* ================= Vote info  ================= */
    address[] voterAdrs;
    
    struct Voter {
        address voterAdr;
        uint256 voterWeight;
        bool isVoter;
    }

    // VoterAddress => Voter Struct
    mapping(address => Voter) voters;

    enum Vote { Pending, Yes, No } 

    // votes[Voter][Beneficiary][Slot] -> Vote
    mapping(address => mapping(address => mapping (uint256 => Vote))) votes;
    
    // slotConfirms[beneficiaryAdr] -> Confirmations[30]
    // slotConfirms includes the aggregate votes based on the weight of voters
    // if(slotConfirms[beneficiary] > 50) --> beneficiary can withdraw released tokens of i'th slot
    mapping(address => uint256[30]) slotConfirms;

    /* ================= Events  ================= */
    event LogReceiveEth(address indexed sender, uint256 indexed amount);
    event LogWithdrawEther(address indexed owner, uint256 indexed amount);
    event LogWithdrawToken(address indexed beneficiaryAdr, uint256 indexed amount);
    event LogConfirm(address indexed voter, address indexed beneficiary, uint256 slot, Vote v);

    constructor() Ownable(msg.sender) {}

    /* ================= Modifiers  ================= */
    modifier onlyBeneficiaries() {
        require(beneficiaries[msg.sender].catId != 0, "You are not a beneficiary.");
        _;
    }

    modifier onlyVoter() {
        require(voters[msg.sender].isVoter, "You are not a Voter");
        _;
    }

    /* ================= onlyOwner functions    ================= */
    function addCategory(uint8 _catId, string memory _catTitle, uint16 _share) external onlyOwner {
        require(_catId > 0, "Category ID has to be greater than zero");
        require(_share > 0, "Share has to be greater than zero");
        require(keccak256(abi.encode(_catTitle)) != keccak256(abi.encode("")), "Category title has to be nonempty");
        catIds.push(_catId);
        categories[_catId] = Category({title: _catTitle, shareOfTotalSup: _share});
    }

    function addSchedule(uint8 _catId, uint8[24] memory _schedule) external onlyOwner {
        require(_catId > 0, "Category ID has to be greater than zero");
        releaseSchedules[_catId] = _schedule;
    }

    function addBeneficiary(uint8 _catId, address _beneficiary, uint16 _shareOfCategory) external onlyOwner {
        require(_catId > 0, "Category ID has to be greater than zero");
        require(_shareOfCategory > 0, "Share amount has to be greater than zero");
        require(_beneficiary != address(0), "The Beneficiary address cannot be zero");
        require(beneficiaries[_beneficiary].catId == 0, "The beneficiary has added already");
        beneficiaryAdrs.push(_beneficiary);
        beneficiaries[_beneficiary] = Beneficiary({catId: _catId, shareOfCategory: _shareOfCategory, withdrawn: 0});
    }

    function addVoter(address _newVoter, uint256 _voterWeight) external onlyOwner {
        require(_newVoter != address(0), "The voter address cannot be zero");
        require(_voterWeight != 0, "The vote weight cannot be zero");
        voterAdrs.push(_newVoter);
        voters[_newVoter] = Voter({
            voterAdr: _newVoter, 
            voterWeight: _voterWeight,
            isVoter: true
        });
    }

    function start(address _TokenAdr) external onlyOwner {
        require(_TokenAdr != address(0), "The token's address cannot be zero");

        CZEE = IERC20(_TokenAdr);
        czeeTotalSupply = CZEE.totalSupply();

        CZEE.transferFrom(msg.sender, address(this), CZEE.balanceOf(msg.sender));
        scheduleStartTime = block.timestamp;
    }

    // Allows the contract owner to withdraw the ETH from the contract
    function withdrawEthers() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
        emit LogWithdrawEther(msg.sender, address(this).balance);
    }

    /* ================= onlyVoter functions    ================= */

    // voters can vote for a beneficiary to be able to withdraw released tokens
    function confirm(address _beneficiary, uint256 _slot, uint256 _vote) external onlyVoter {
        Vote v = Vote(_vote);

        require(_beneficiary != address(0), "The Beneficiary address cannot be zero");
        require(_slot >= 0 && _slot < 24, "The selected slot of locktime schedule is not valid");
        // A release-slot can be confirmed only if 
        // the block timestamp reached just the end of that or left it behind.
        require(_slot < getCurrentSlot(),"It isn't reached the time to confirm this slot");
        require(v == Vote.Yes || v == Vote.No, "The proposed vote is not valid");
        require(votes[msg.sender][_beneficiary][_slot] == Vote.Pending, 
        "Voter already have submitted a vote for this release slot of the beneficiary");

        votes[msg.sender][_beneficiary][_slot] = v;
        if (v == Vote.Yes) {
            slotConfirms[_beneficiary][_slot] += voters[msg.sender].voterWeight;
        }

        emit LogConfirm(msg.sender, _beneficiary, _slot, v);
    }

    /* ================= External functions    ================= */

    // Beneficiary call this function to withdraw released tokens.
    function withdrawTokens(uint256 _amount) external onlyBeneficiaries nonReentrant returns (bool)  {
        require(_amount > 0, "amount has to be grater than zero");
        address beneficiaryAdr = msg.sender;

        // get amount of tokens that can be withdraw
        (,,,,uint256 canwithdraw) = getAvailableTokens(beneficiaryAdr);
        require(canwithdraw >= _amount, "You have not enough released and confirmed tokens");

        // Update the beneficiary information
        uint256 preWithdrawn = beneficiaries[beneficiaryAdr].withdrawn;
        uint256 curWithdrawn = preWithdrawn.add(_amount);
        beneficiaries[beneficiaryAdr].withdrawn = curWithdrawn;

        // Transfer released tokens to the beneficiary
        CZEE.transfer(beneficiaryAdr, _amount);

        emit LogWithdrawToken(beneficiaryAdr, _amount);
        return true;
    }

    /* ================= get functions    ================= */

    function getCatID(uint _idx) public view returns(uint8) {
        return catIds[_idx];
    }

    function getCategory(uint _catID) public view returns(string memory, uint256) {
        Category storage cat = categories[_catID];
        return (cat.title, cat.shareOfTotalSup);
    }

    function getBeneficiaryAdr(uint _idx) public view returns(address) {
        return beneficiaryAdrs[_idx];
    }

    function getBeneficiary(address _beneficiaryAdr) public view returns(uint256, uint256, uint256) {
        Beneficiary storage ben = beneficiaries[_beneficiaryAdr];
        return (ben.catId, ben.shareOfCategory, ben.withdrawn);
    }

    function geVoterAdr(uint _idx) public view returns(address) {
        return voterAdrs[_idx];
    }

    function getVoter(address _voterAdr) public view returns(address, uint256, bool) {
        Voter storage voter = voters[_voterAdr];
        return (voter.voterAdr, voter.voterWeight, voter.isVoter);
    }

    function getVote(address _voterAdr, address _beneficiaryAdr, uint256 _slot) public view returns(Vote) {
        return votes[_voterAdr][_beneficiaryAdr][_slot];
    }

    function getSlotConfirms(address _beneficiaryAdr) public view returns(uint256[30] memory) {
        return slotConfirms[_beneficiaryAdr];
    }

    function getDaoStartTime() public view returns (uint256) {
        return scheduleStartTime;
    }

    function getReleaseStep() public view returns (uint256) {
        return releaseStep;
    }

    function getReleaseSchedules(uint256 _releaseIdx) public view returns(uint256[30] memory) {
        return releaseSchedules[_releaseIdx];
    }

    function getCurrentSlot() public view returns (uint256) {
        require(scheduleStartTime != 0, "Scheduling has not started yet");
        return (block.timestamp.sub(scheduleStartTime)).div(releaseStep);
    }

    // Get the amount of tokens that beneficiary can withdraw now, base on release schedule of the category.
    function getAvailableTokens(address _beneficiary) public view returns ( 
        uint256 beneficiaryTotalTokens,
        uint256 beneficiaryReleasedTokens,
        uint256 confirmedTokens,
        uint256 withdrawn,
        uint256 canwithdraw
    ) {
        require(scheduleStartTime != 0, "Scheduling has not started yet");
        require(_beneficiary != address(0), "The Beneficiary address cannot be zero");

        uint256 catId = beneficiaries[_beneficiary].catId; 
        uint256 categoryShareOfTotalSup = categories[catId].shareOfTotalSup;
        uint256 beneficiaryShareOfCategory = beneficiaries[_beneficiary].shareOfCategory; 
        uint256 categoryTotalTokens = (categoryShareOfTotalSup.mul(czeeTotalSupply)).div(10000);
        beneficiaryTotalTokens = (beneficiaryShareOfCategory.mul(categoryTotalTokens)).div(10000);

        // get the current slot
        uint256 curSlot  = getCurrentSlot() > 30 ? 30 : getCurrentSlot();

        for(uint i; i < curSlot; i++) {

            uint256 slotReleasedTokens = (releaseSchedules[catId][i].mul(beneficiaryTotalTokens)).div(100);

            // Released tokens
            beneficiaryReleasedTokens = beneficiaryReleasedTokens.add(slotReleasedTokens);

            // user can withdraw just tokens that released and confirmed
            if(slotConfirms[_beneficiary][i] > 50) {
                confirmedTokens = confirmedTokens.add(slotReleasedTokens);
            }
        }

        // How many tokens, this Beneficiary has took out of account, until now.
        withdrawn = beneficiaries[_beneficiary].withdrawn;
        
        // How many tokens, this Beneficiary can withdraw
        if(catId == 1 || catId == 2 || catId == 3) {
            // Team, Advisors and Marketing-Dev 
            canwithdraw = confirmedTokens.sub(withdrawn);
        }
        else {
            // Other Beneficiaries
            canwithdraw = beneficiaryReleasedTokens.sub(withdrawn);
        }
    }

    /* ================= other functions  ================= */

    // To accept ETHs transferrd by low-level-calls
    receive() external payable {
        emit LogReceiveEth(msg.sender, msg.value);
    }

    fallback() external payable {
        emit LogReceiveEth(msg.sender, msg.value);
    }
}


/*
    01. Team               - withdrawn by Team's    EOA - NEED confirmation
    02. Advisors           - withdrawn by Advisor's EOA - NEED confirmation
    03. Marketing-Dev      - withdrawn by Dedicated EOA - NEED confirmation

    04. Staking            - withdrawn by Dedicated EOA - NO confirmation
    05. Airdrop            - withdrawn by Dedicated EOA - NO confirmation

    06. Treasury           - withdrawn by Dedicated EOA - NO confirmation
    07. Play-to-Earn       - withdrawn by Dedicated EOA - NO confirmation 
    08. Ecosystem-Fund     - withdrawn by Dedicated EOA - NO confirmation
    09. Animal Protection  - withdrawn by Dedicated EOA - NO confirmation

    10. Private-Sale       - withdrawn by Dedicated EOA - NO confirmation
*/