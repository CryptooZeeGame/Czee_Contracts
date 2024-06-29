// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./CZEEDAO.sol";

contract CZEEStaking is ReentrancyGuard {

    CZEEDAO dao;
    uint256 timeUnits = 1 days; // minutes;


    /* ================= Investor Info  ================= */

    struct Investor {
        uint256 depositTimestamp;   // The time that the deposit happened
        uint256 depositBalance;     // How much Token is deposited into the contract
        uint256 pendingReward;      // Remained Reward Tokens that user can withdraw
        uint256 withdrawnReward;    // How many rewards tokens, this Investor has accrued of contract, until now.
    }


    /* ================= Plan Info  ================= */

    uint256 public latestPlanId;
    uint256[] public planIds;

    struct Plan {
        uint256 stakingStartTime;    // timestamp
        uint256 stakingDuration;     // seconds
        uint256 stakingDeadline;     // timestamp

        uint256 rewardRate;          // 10 ~ 10%
        uint256 rewardRatePerToken;  // interest payout rate for each deposited Token in every second     

        uint256 totalPendingRewards; // total rewards that should be paid to investors
        uint256 totalPaidRewards;    // total rewards that has been paid to investors, until now
        uint256 totalDeposits;       // total tokens that investors has been deposited, until now

        uint256 maxReward;           // maxReward = maxDeposit * rewardRate / 100
        uint256 maxDeposit;          // maxDeposit = maxReward * 100 / rewardRate; 

        IERC20 stakingToken;
        IERC20 rewardToken;

        // Investor Addresses
        address[] investorAdrs;

        // Investor Address => Investor Struct
        mapping(address => Investor) investors;
    }

    mapping(uint256 => Plan) plans;


    /* ================= Events  ================= */

    event LogDepositToken(uint256 indexed planId, address indexed investor, uint256 amount); 
    event LogWithdrawToken(uint256 indexed planId, address indexed investor, uint256 amount);
    event LogWithdrawReward(uint256 indexed planId, address indexed investor, uint256 amount);
    event LogReceiveEth(address indexed sender, uint256 amount);
    event LogWithdrawEther(address indexed owner, uint256 amount);
    event LogNewPlanStarted(uint256 indexed planId, uint256 stakingDays, uint256 rewardRate);
    event LogGetRewardTokensFromDAO(uint256 indexed planId, uint256 amount);
    event LogAddRewardTokens(address indexed owner, uint256 planId, uint256 amount);
    event LogWithdrawRestReward(uint256 indexed planId, address indexed owner, address indexed treasuryAdr, uint256 amount);


    constructor(address payable _daoAdr) {
        require(_daoAdr != address(0), "The dao address cannot be zero");
        dao = CZEEDAO(_daoAdr);
    }


    /* ================= Modifiers  ================= */

    modifier onlyOwner {
        require(msg.sender == getOwner(), "Only Owner");
        _;
    }

    modifier onlyInvestor() {
        require(plans[latestPlanId].investors[msg.sender].depositTimestamp != 0, "You are not an Investor");
        _;
    }

    modifier stakingDeadlineReached(bool _required) {
        uint256 timeRemaining = getStakingTimeLeft();
        if(_required) {
            require(timeRemaining == 0, "Staking Deadline is not reached yet");
        } else {
            require(timeRemaining > 0, "Staking Deadline has been reached");
        }
        _;
    }

    modifier hasDeposit(bool _required) {
        uint depositTimestamp = plans[latestPlanId].investors[msg.sender].depositTimestamp;
        if(_required) {
            require(depositTimestamp != 0, "You have not any deposit");
        } else {
            require(depositTimestamp == 0, "You have a deposit");
        }
        _;
    }

    modifier planExists(uint256 _planId) {
        require(_planId > 0 && _planId <= latestPlanId, "Plan does not exist");
        _;
    }

    modifier canStartNewPlan() {
        require(block.timestamp > plans[latestPlanId].stakingDeadline, "new Plan have to start after latest plan");
        _;
    }


    /* ================= Owner functions   ================= */

    function startNewPlan(
        uint256 _rewardRate, 
        uint256 _stakingDays,
        uint256 _maxReward,
        address _stakingToken, 
        address _rewardToken
    ) external  onlyOwner canStartNewPlan {
        latestPlanId++;
        planIds.push(latestPlanId);

        setContractAddresses(_stakingToken, _rewardToken);
        setStakingTimes(_stakingDays);
        setRewardAndDepositMaxValues(_maxReward, _rewardRate);
        setRewardRatePerToken();
        claimRewardTokensFromDAO();

        emit LogNewPlanStarted(latestPlanId, _stakingDays, _rewardRate);
    }

    function setContractAddresses(address _stakingToken, address _rewardToken) internal {
        require(_stakingToken != address(0), "The stake token's address cannot be zero");
        require(_rewardToken != address(0), "The reward token's address cannot be zero");

        Plan storage plan = plans[latestPlanId];
        plan.stakingToken = IERC20(_stakingToken);
        plan.rewardToken = IERC20(_rewardToken);
    }

    // get _stakingDuration in seconds and set stakingStartTime and stakingDeadline as timestamp
    function setStakingTimes(uint _stakingDays) internal {
        Plan storage plan = plans[latestPlanId];
        plan.stakingStartTime = block.timestamp;            // timestamp
        plan.stakingDuration = _stakingDays * timeUnits;    // seconds
        plan.stakingDeadline = plan.stakingStartTime + plan.stakingDuration; // timestamp
    }

    function setRewardAndDepositMaxValues(uint _maxReward, uint _rewardRate) internal {
        Plan storage plan = plans[latestPlanId];
        plan.rewardRate = _rewardRate;     // reward Rate for staking duration - ex. 10 ~ 10%
        plan.maxReward = _maxReward;
        plan.maxDeposit = plan.maxReward * 100 / plan.rewardRate;
    }

    function setRewardRatePerToken() internal {
        Plan storage plan = plans[latestPlanId];
        plan.rewardRatePerToken = (plan.rewardRate * 1e18) / (plan.stakingDuration * 100);
    }

    function updateRewardAndDepositMaxValues(uint _AddRewardAmount) internal {
        Plan storage plan = plans[latestPlanId];
        plan.maxReward += _AddRewardAmount;
        plan.maxDeposit = plan.maxReward * 100 / plan.rewardRate;
    }

    // Staking Contract get Reward-Tokens from DAO.
    // First, be sure that your required amount has been released for staking.
    function claimRewardTokensFromDAO() internal nonReentrant {
        Plan storage plan = plans[latestPlanId];
        dao.withdrawTokens(plan.maxReward);

        emit LogGetRewardTokensFromDAO(latestPlanId, plan.maxReward);
    }

    // Treasury-Owner can add more Reward tokens.
    function addRewardTokens(uint256 _amount) external stakingDeadlineReached(false) nonReentrant {
        Plan storage plan = plans[latestPlanId];

        uint allowance = plan.rewardToken.allowance(msg.sender, address(this));
        require(allowance >= _amount , "Staking insufficient allowance.");

        updateRewardAndDepositMaxValues(_amount);
        plan.rewardToken.transferFrom(msg.sender, address(this), _amount);

        emit LogAddRewardTokens(msg.sender, latestPlanId, _amount);
    }

    // Allows the contract owner (deployer) to withdraw the ETH from the contract
    function withdrawRestEthers(address _target) external onlyOwner nonReentrant {
        uint EthAmount = address(this).balance;
        require(EthAmount > 0, "You have no Eth balance to withdraw!");

        // Transfer ETH via call
        (bool sent,) = _target.call{value: EthAmount}("");
        require(sent, "withdrawal failed.");

        emit LogWithdrawEther(msg.sender, address(this).balance);
    }

    // Owner can send remained RewardTokens to Treasury-Owner from plans that its dedline reached.
    function withdrawRestRewardTokens(uint _planId, address _treasuryAdr) external onlyOwner nonReentrant {
        require(block.timestamp > plans[_planId].stakingDeadline, "Staking plan doesn't reached deadline!");

        uint canWithdraw = getRestRewardTokensAmount(_planId);
        require(canWithdraw > 0, "There are not any remained Reward Tokens!");

        Plan storage plan = plans[_planId];
        plan.rewardToken.transfer(_treasuryAdr, canWithdraw);

        emit LogWithdrawRestReward(_planId, msg.sender, _treasuryAdr, canWithdraw);
    }


    /* ================= Investor functions  ================= */

    function deposit(uint256 _amount) external stakingDeadlineReached(false) hasDeposit(false) nonReentrant {
        Plan storage plan = plans[latestPlanId];

        // control how many tokens new user can deposit, With regards to the reward Token's Limitation.
        uint depositLimitaion = plan.maxDeposit - plan.totalDeposits;
        require(_amount <= depositLimitaion, "deposit amount is greater than limitaion");

        uint allowance = plan.stakingToken.allowance(msg.sender, address(this));
        require(allowance >= _amount , "Staking insufficient allowance.");

        uint256 userTotalReward = getUserTotalReward(_amount);

        plan.totalPendingRewards += userTotalReward;
        plan.totalDeposits += _amount;

        plan.investors[msg.sender] = Investor({
            depositTimestamp: block.timestamp, 
            depositBalance: _amount, 
            pendingReward: userTotalReward,
            withdrawnReward: 0
        });
        plan.investorAdrs.push(msg.sender);

        plan.stakingToken.transferFrom(msg.sender, address(this), _amount);

        emit LogDepositToken(latestPlanId, msg.sender, _amount); 
    }

    // Anytime, user can get their accrued reward tokens from last plan 
    function getReward() public onlyInvestor nonReentrant {
        uint256 canWithdraw = getUserCanWithdrawRewards(msg.sender);
        require(canWithdraw > 0, "You have withdraw all earned reward tokens already!");

        Plan storage plan = plans[latestPlanId];
        address investor = msg.sender;

        plan.totalPendingRewards -= canWithdraw;
        plan.totalPaidRewards += canWithdraw;

        plan.investors[investor].pendingReward -= canWithdraw;
        plan.investors[investor].withdrawnReward += canWithdraw;

        plan.rewardToken.transfer(investor, canWithdraw);

        emit LogWithdrawReward(latestPlanId, investor, canWithdraw);
    }

    // After deadline, user can Withdraw their principle balance from the plan
    function withdrawPrincipalBalance(uint _planId) public planExists(_planId) onlyInvestor nonReentrant {
        address investor = msg.sender;
        Plan storage plan = plans[_planId];
        uint principleBalance = plan.investors[investor].depositBalance;

        require(block.timestamp > plan.stakingDeadline, "Staking plan doesn't reach deadline!");
        require(principleBalance != 0, "Principle Balances is Zero.");

        plan.investors[investor].depositBalance = 0;

        plan.stakingToken.transfer(investor, principleBalance);

        emit LogWithdrawToken(_planId, investor, principleBalance);
    }

    // After deadline, user can Withdraw their reward tokens from the plan
    function withdrawReward(uint _planId) public planExists(_planId) onlyInvestor nonReentrant {
        address investor = msg.sender;
        Plan storage plan = plans[_planId];
        uint pendingReward = plan.investors[investor].pendingReward;

        require(block.timestamp > plan.stakingDeadline, "Staking plan doesn't reach deadline!");
        require(pendingReward != 0, "Pending Reward is Zero.");

        plan.totalPendingRewards -= pendingReward;
        plan.totalPaidRewards += pendingReward;

        plan.investors[investor].pendingReward -= pendingReward;
        plan.investors[investor].withdrawnReward += pendingReward;

        plan.rewardToken.transfer(investor, pendingReward);

        emit LogWithdrawReward(_planId, investor, pendingReward);
    }

    // exit from closed plan
    function exitPlan(uint _planId) external planExists(_planId) onlyInvestor {
        withdrawPrincipalBalance(_planId);
        withdrawReward(_planId);
    }


    /* ================= get functions ================= */

    function getStakingTimeLeft() public view returns (uint256) {
        Plan storage plan = plans[latestPlanId];
        if(block.timestamp >= plan.stakingDeadline) {
            return (0);
        } else {
            return (plan.stakingDeadline - block.timestamp);
        }
    }

    function getUserDepositBalance(address _investor) public view returns (uint256) {
        Plan storage plan = plans[latestPlanId];
        return plan.investors[_investor].depositBalance;
    }

    function getUserElapsedDepositTime(address _investor) public view returns (uint256) {
        Plan storage plan = plans[latestPlanId];
        return (block.timestamp - plan.investors[_investor].depositTimestamp);
    }

    function getUserWithdrawnReward(address _investor) public view returns (uint256) {
        Plan storage plan = plans[latestPlanId];
        return plan.investors[_investor].withdrawnReward;
    }

    function getUserTotalReward(uint256 _depositAmount) internal view returns (uint256 totalReward) {
        Plan storage plan = plans[latestPlanId];
        totalReward = ( plan.rewardRatePerToken * getStakingTimeLeft() * _depositAmount ) / 1e18;
    }
    
    function getUserCanWithdrawRewards(address _investor) public view returns (uint256 canWithdraw) {
        Plan storage plan = plans[latestPlanId];
        uint256 totalEarnedReward =  ( plan.rewardRatePerToken * getUserElapsedDepositTime(_investor) * getUserDepositBalance(_investor) ) / 1e18;
        canWithdraw = totalEarnedReward - getUserWithdrawnReward(_investor);
    }

    function getInvestorCount(uint _planId) public view returns(uint) {
        return plans[_planId].investorAdrs.length;
    }

    function getInvestorAddress(uint _planId, uint _idx) public view returns(address) {
        return plans[_planId].investorAdrs[_idx];
    }

    function getInvestorInfo(uint _planId, address _invAdr) public view returns(uint, uint, uint, uint) {
        Investor storage investor = plans[_planId].investors[_invAdr];
        return (
            investor.depositTimestamp,   // The time that the deposit happened
            investor.depositBalance,     // How much Token is deposited into the contract
            investor.pendingReward,      // Remained Reward Tokens that user can withdraw
            investor.withdrawnReward     // How many rewards tokens, this Investor has accrued, until now.
        );
    }

    function getPlansCount() public view returns(uint) {
        return planIds.length;
    }

    function getPlanInfo(uint _planId) public view returns(
        uint stakingStartTime, 
        uint stakingDuration,
        uint stakingDeadline, 
        uint rewardRate, 
        uint rewardRatePerToken, 
        uint totalPendingRewards, 
        uint totalPaidRewards, 
        uint totalDeposits, 
        uint maxReward, 
        uint maxDeposit
    ) {
        Plan storage plan = plans[_planId];
        return (
            plan.stakingStartTime,    // timestamp
            plan.stakingDuration,     // seconds
            plan.stakingDeadline,     // timestamp
            plan.rewardRate,          // 10 ~ 10%
            plan.rewardRatePerToken,  // interest payout rate for each deposited Token in every second     
            plan.totalPendingRewards, // total rewards that should be paid to investors
            plan.totalPaidRewards,    // total rewards that has been paid to investors, until now
            plan.totalDeposits,       // total tokens that investors has been deposited, until now
            plan.maxReward,           // maxReward = maxDeposit * rewardRate / 100
            plan.maxDeposit           // maxDeposit = maxReward * 100 / rewardRate; 
        );
    }

    function getPlanTokenAddresses(uint _planId) public view returns(
        address stakingToken, 
        address rewardToken
    ) {
        Plan storage plan = plans[_planId];
        return (
            address(plan.stakingToken), 
            address(plan.rewardToken)
        );
    }

    function getRestRewardTokensAmount(uint _planId) public view onlyOwner returns(uint) {
        Plan storage plan = plans[_planId];
        uint256 rewardTokenBalance = plan.rewardToken.balanceOf(address(this));
        uint totalPendingRewards = plan.totalPendingRewards;
        return (rewardTokenBalance - totalPendingRewards);
    }

    function getOwner() public view returns(address) {
        return dao.owner();
    }


    /* ================= other functions  ================= */
    
    receive() external payable {
        emit LogReceiveEth(msg.sender, msg.value);
    }

}