// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
//import "./CZEEToken.sol";

/**
 * @title CZEEICO Contract
 * @dev A smart contract that implements the CZEE initial coin offering (ICO),
 * allowing investors to purchase CZEE tokens in exchange for Matic or Tether.
 */
contract CZEEICO is Ownable, ReentrancyGuard {  

    using SafeMath for uint256;           
    
    // maximum number of tokens that can be purchased in a single transaction.
    uint256 private _maxTokensPerTx = 100_000e18;

    // minimum number of tokens that can be purchased in a single transaction.
    uint256 private _minTokensPerTx = 10e18;

    // maximum number of tokens that a buyer can hold.
    uint256 private _maxTokensPerBuyer = 1_000_000e18;

    IERC20 public _token;

    //---------------------------------------------------------------
    // Tether (USDT) address 
    //---------------------------------------------------------------
    // Polygon  : 0xc2132D05D31c914a87C6611C10748AEb04B58e8F
    //------------------
    // Ethereum : 0xc2132D05D31c914a87C6611C10748AEb04B58e8F 
    //---------------------------------------------------------------
    IERC20 private _usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
  
    //---------------------------------------------------------------
    // Chainlink price feed
    // ETH/USD 
    // https://docs.chain.link/data-feeds/price-feeds/addresses
    //---------------------------------------------------------------
    // Polygon
    //------------------
    // Mainnet : 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0      
    // Testnet : 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada 
    //------------------
    // Ehereum
    //------------------
    // Mainnet : 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    // Testnet : 0x694AA1769357215DE4FAC081bf1f309aDC325306
    //---------------------------------------------------------------
    AggregatorV3Interface private toUsdPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    // Price of token in USD (1 CZEE = 0.0000025 $)
    uint256 private _tokenPriceInUSD = 0.0000025 * 1e18;
    
    // The total amount of funds raised in the ICO.
    uint256 private _fundsRaised;     

    // The total amount of tokens available for sale in the ICO.
    uint256 private _icoTokenAmount;    

    // Unix timestamp for the start of the ICO.
    uint256 private _icoOpeningTime;

    // Unix timestamp for the end of the ICO.
    uint256 private _icoClosingTime; 

    // duration of the ICO in seconds.
    uint256 private _icoDurationInSeconds;     

    // Maps the address of each buyer to their token balance.    
    mapping(address => uint256) private tokenAmountInWallet;


    //---------------------------------------------------------------
    // Private Sale Scheduling
    //---------------------------------------------------------------
    // Release info
    uint256 private releaseStep = 60 days;  // seconds, minutes, hours, days, weeks, years
    
    // Release Schedules Array
    uint256[3] private releaseSchedule;

    // Beneficiary info
    address[] beneficiaryAdrs;

    struct Beneficiary {
        uint256 scheduleStartTime;
        uint256 tokenAmountInWallet;
        uint256 withdrawn;          // How many tokens, this Beneficiary has took out of account, until now.
    }

    // BeneficiaryAddress => Beneficiary Struct
    mapping(address => Beneficiary) beneficiaries;

    modifier onlyBeneficiaries() {
        require(beneficiaries[msg.sender].scheduleStartTime != 0, "You are not a beneficiary.");
        _;
    }

    event TokensDeposited(address indexed _owner, uint256 amount);
    event TokensPurchased(address indexed beneficiary, uint256 value, uint256 amount);
    event FundsWithdrawn(address indexed _owner, uint256 _amount);
    event usdtWithdrawn(address indexed _owner, uint256 _amount);
    event TokensWithdrawn(address indexed _owner, uint256 _amount);

    constructor() Ownable(msg.sender) {
        releaseSchedule = [33, 33, 34];
    }

    /**
    * @dev Modifier to restrict certain functions to the time when the ICO is closed.
    * @notice This modifier should be used in conjunction with isOpen() function.
    */
    modifier onlyWhileClosed {
         require(!isOpen(), "ICO Should be closed");
        _;
    }    

    /**
    * @dev Modifier to restrict certain functions to the time when the ICO is open.
    * @notice This modifier should be used in conjunction with isOpen() function.
    */
    modifier onlyWhileOpen {
        require(isOpen(), "ICO: has been already closed");
        _;
    } 

    //------------------
    // Admin Functions
    //------------------
    
    /**
    * @dev Deposits tokens into the ICO contract.
    * @notice Only the contract owner can deposit tokens.
    * @param _amount The amount of tokens to be deposited.
    */
    function depositTokens(address token, uint _amount) external onlyOwner returns (bool) {
        _token = IERC20(token);

        require(_amount > 0, "ICO: Invalid token amount");

        _icoTokenAmount += _amount;      
        _token.transferFrom(owner(), address(this), _amount);

        emit TokensDeposited(owner(), _amount);
        return true;      
    }

    /**
    * @dev Opens the ICO for buying tokens.
    * @param _icoDurationInDays The duration of the ICO in days.
    * @notice Only the contract owner can open the ICO.
    */
    function openIco(uint256 _icoDurationInDays) external onlyOwner {
        require(_icoDurationInDays > 0, "ICO: Invalid ico Duration");
        require(!isOpen(), "ICO: has been already opened");
        require(_icoTokenAmount > 0, "ICO: No tokens to buy");
                
        _icoOpeningTime = block.timestamp;
        _icoDurationInSeconds = _icoDurationInDays * 1 days;
        _icoClosingTime = _icoOpeningTime + _icoDurationInSeconds;                                 
    }

    /**
    * @dev Extends the ICO closing time.
    * @notice Only the contract owner can extend the ICO.
    * @notice This function can only be called while the ICO is open.
    * @param _addedDurationInDays The added ICO duration in days.
    */
    function extendIcoTime(uint256 _addedDurationInDays) external onlyOwner onlyWhileOpen {
        require(_addedDurationInDays > 0, "ICO: Invalid Duration");

        _icoDurationInSeconds += _addedDurationInDays * 1 days;      
        _icoClosingTime = _icoOpeningTime + _icoDurationInSeconds;
    }

    /**
    * @dev Sets the price feed address of the native coin to USD from the Chainlink oracle.
    * @param _toUsdPricefeed The address of native coin to USD price feed.
    */    
    function changePriceFeed(address _toUsdPricefeed) external onlyOwner onlyWhileClosed {
        require(_toUsdPricefeed != address(0), "ICO: Price feed address cannot be zero" );
        toUsdPriceFeed = AggregatorV3Interface(_toUsdPricefeed);        
    }

    /**
    * @dev Sets the address of the USD stable coin.
    * @param _stableCoin The address of native USD stable coin.
    */    
    function changeStableCoin(address _stableCoin) external onlyOwner onlyWhileClosed {
        require(_stableCoin != address(0), "ICO: Price feed address cannot be zero" );
        _usdt = IERC20(_stableCoin);        
    }

    // update maximum number of tokens that can be purchased in a single transaction.
    function change_maxTokensPerTx(uint256 _newMaxTokensPerTx) external onlyOwner onlyWhileClosed {
        require(_newMaxTokensPerTx != 0, "ICO: _maxTokensPerTx cannot be zero" );
        _maxTokensPerTx = _newMaxTokensPerTx;        
    }

    // update minimum number of tokens that can be purchased in a single transaction.
    function change_minTokensPerTx(uint256 _newMinTokensPerTx) external onlyOwner onlyWhileClosed {
        require(_newMinTokensPerTx != 0, "ICO: _minTokensPerTx cannot be zero" );
        _minTokensPerTx = _newMinTokensPerTx;        
    }

    // update maximum number of tokens that a buyer can hold.
    function change_maxTokensPerBuyer(uint256 _newMaxTokensPerBuyer) external onlyOwner onlyWhileClosed {
        require(_newMaxTokensPerBuyer != 0, "ICO: _maxTokensPerBuyer cannot be zero" );
        _maxTokensPerBuyer = _newMaxTokensPerBuyer;        
    }

    /**
    * @dev Closes the ICO for buying tokens.
    * @notice Only the contract owner can close the ICO.
    * @notice This function can only be called while the ICO is open.
    */
    function closeIco() external onlyOwner onlyWhileOpen {        
        _icoOpeningTime = 0;
        _icoClosingTime = 0;
        _icoDurationInSeconds = 0;                 
    }  
    
    /**
    * @dev Withdraws all funds from the ICO contract.
    * @notice Only the contract owner can withdraw funds.
    * @notice This function can only be called while the ICO is closed.
    * @return _success boolean indicating whether the withdrawal was successful.
    */
    function withdrawFunds(uint _value) external onlyOwner onlyWhileClosed returns (bool _success) {        
        require(_value > 0, "ICO: Invalid Amount to withdraw Funds");
        require(_fundsRaised >= _value, "ICO: No Enough Funds to Withdraw");
        
        _fundsRaised -= _value;
        (_success,) = owner().call{value: _value}("");

        emit FundsWithdrawn(owner(), _value);
        return _success;        
    }

    /**
    * @dev Withdraws Stable Coins from the ICO contract.
    * @notice Only the contract owner can withdraw tokens.    
    * @param _amount The amount of tokens to be withdrawn.
    */
    function withdrawUSDT(uint _amount) external onlyOwner onlyWhileClosed returns (bool) {        
        require(_amount > 0, "ICO: Invalid Amount to withdraw USDT");      
        require(_usdt.balanceOf(address(this)) >= _amount, "ICO: No Enough USDT to Withdraw");       

        _usdt.transfer(owner(), _amount);
        
        emit usdtWithdrawn(owner(), _amount);
        return true; 
    }

    /**
    * @dev withdraw the remained tokens (if any) in ICO.
    * @notice This function can only be called while the ICO is closed.
    */
    function withdrawRemainedTokens() external onlyOwner onlyWhileClosed returns (bool) {
        require(_icoTokenAmount != 0, "ICO: No Tokens to withdraw");

        uint256 remainedAmount = _icoTokenAmount;
        _icoTokenAmount = 0;
        _token.transfer(msg.sender, remainedAmount);

        emit TokensWithdrawn(msg.sender, remainedAmount);
        return true;        
    }


    //------------------
    // User Functions
    //------------------

    /**
    * @dev Allows users to buy tokens during the ICO.
    * @notice This function can only be called while the ICO is open.    
    * @return A boolean indicating whether the token purchase was successful.
    */
    function publicSale_by_NativeCoin() external onlyWhileOpen nonReentrant payable returns(bool) {
        address beneficiary = msg.sender;
        uint256 paymentInWei = msg.value;                

        _preValidatePurchase(beneficiary, paymentInWei);
        uint256 tokenAmount = _getTokenAmount(false, paymentInWei);       
        _processPurchase(beneficiary, tokenAmount);

        _fundsRaised += paymentInWei;
        tokenAmountInWallet[beneficiary] += tokenAmount;        
        _icoTokenAmount -= tokenAmount;
        _token.transfer(beneficiary, tokenAmount);

        emit TokensPurchased(beneficiary, paymentInWei, tokenAmount);
        return true;
    }

    /**
    * @dev Allows users to buy tokens with a Stable coin during the ICO.
    * @notice This function can only be called while the ICO is open.    
    * @param _usdtAmount The amount of USDT in wei.    
    * @return A boolean indicating whether the token purchase was successful.
    */
    function publicSale_buy_USDT(uint256 _usdtAmount) external onlyWhileOpen nonReentrant returns(bool) {
        address beneficiary = msg.sender;                                     

        _preValidatePurchase(beneficiary, _usdtAmount);
        uint256 tokenAmount = _getTokenAmount(true, _usdtAmount);      
        _processPurchase(beneficiary, tokenAmount);

        tokenAmountInWallet[beneficiary] += tokenAmount;        
        _icoTokenAmount -= tokenAmount;
        _usdt.transferFrom(beneficiary, address(this), _usdtAmount);
        _token.transfer(beneficiary, tokenAmount);

        emit TokensPurchased(beneficiary, _usdtAmount, tokenAmount);
        return true;
    }


    //------------------
    // Internal functions
    //------------------

    /**
    * @dev Validates that a token purchase is valid.
    * @notice This function is called by the `buyWithMatic()` function to validate the transaction.
    * @param _beneficiary The address of the beneficiary of the token purchase.
    * @param _amount The amount of Ether/USDT sent in the transaction.
    */
    function _preValidatePurchase(address _beneficiary, uint256 _amount) internal view {
        require(_beneficiary != address(0), "ICO: Beneficiary address cannot be zero");
        require(_amount > 0, "ICO: Payment is zero"); 
        require(_amount <= _icoTokenAmount, "ICO: not enough tokens to buy");
    }

    /**
    * @dev Processes a token purchase for a given beneficiary.
    * @notice This function is called by the `buyWithMatic()` function to process a token purchase.
    * @param _beneficiary The address of the beneficiary of the token purchase.
    * @param _tokenAmount The amount of tokens to be purchased.
    */
    function _processPurchase(address _beneficiary, uint256 _tokenAmount) internal view {        
        require(_tokenAmount >= _minTokensPerTx, "ICO: cannot buy less than the max amount" );
        require(_tokenAmount <= _maxTokensPerTx, "ICO: cannot buy more than the max amount" );
        require(tokenAmountInWallet[_beneficiary] + _tokenAmount <= _maxTokensPerBuyer, "ICO: Cannot hold more tokens than max allowed");      
    }
    
    /**
    * @dev Calculates the amount of tokens that can be purchased with the specified amount of ether, based on the current token rate in USD.
    * @param paymentInWei The amount of ether sent to purchase tokens.
    * @return The number of tokens that can be purchased with the specified amount of ether.
    */
    function _getTokenAmount(bool isUSDT, uint256 paymentInWei) internal view returns (uint256) {   
        uint priceInwei;

        if (isUSDT)
            priceInwei = 1e18;
        else          
            priceInwei = _priceInWei();        
        
        return ((paymentInWei * priceInwei) / _tokenPriceInUSD);
    }   

    /**
    * @dev Gets the latest MATIC/USD from the Chainlink oracle.
    * @return The price of 1 MATIC in USD.
    */
    function _priceInWei() internal view returns (uint256) {
        (,int price,,,) = toUsdPriceFeed.latestRoundData();
        uint8 priceFeedDecimals = toUsdPriceFeed.decimals();
        price = _toWei(price, priceFeedDecimals, 18);
        return uint256(price);
    } 
    
    /**
    * @dev Converts the price from the Chainlink Oracle to the appropriate data type,
        before performing arithmetic operations.
    * @param _amount The price returned from the Chainlink Oracle.
    * @param _amountDecimals The number of decimals in the price returned from the Chainlink Oracle.
    * @param _chainDecimals The number of decimals used by the Ethereum blockchain (18 for ether).
    * @return The price converted to the appropriate data type.
    */
    function _toWei(int256 _amount, uint8 _amountDecimals, uint8 _chainDecimals) internal pure returns (int256) {        
        if (_chainDecimals > _amountDecimals)
            return _amount * int256(10 **(_chainDecimals - _amountDecimals));
        else
            return _amount * int256(10 **(_amountDecimals - _chainDecimals));
    }


    //------------------
    // get functions
    //------------------

    /**
    * @dev Checks if the ICO is currently open.
    * @return A boolean indicating whether the ICO is currently open or not.
    */
    function isOpen() public view returns (bool) {        
        return block.timestamp >= _icoOpeningTime && block.timestamp <= _icoClosingTime;
    }    

    /**
    * @dev Returns the total amount of funds raised in the ICO.
    * @return The total amount of funds raised in the ICO.
    */
    function getIcoFundsBalance() external view returns(uint256) {
        return _fundsRaised;
    } 

    /**
    * @dev Returns the total amount of ICO tokens remaining.
    * @return The total amount of ICO tokens remaining.
    */
    function getIcoCZEETokensBalance() external view returns(uint256) {
        return _icoTokenAmount;
    }

    /**
    * @dev Returns the total amount of USDT raised in the ICO.
    * @return The total amount of USDT raised in the ICO.
    */
    function getIcoUsdtBalance() external view returns(uint256) {
        return _usdt.balanceOf(address(this));
    }

    /**
    * @dev Returns the number of tokens held by the specified beneficiary.
    * @param _beneficiary The address of the beneficiary.
    * @return The number of tokens held by the specified beneficiary.
    */
    function getTokenBuyerBalance(address _beneficiary) external view returns(uint256) {
        return tokenAmountInWallet[_beneficiary];
    }

    /**
    * @dev Returns the maximum number of tokens that can be purchased in a single transaction.
    */
    function getMaxTokensPerTx() external view returns(uint256) {
        return _maxTokensPerTx;
    }

    /**
    * @dev Returns the minimum number of tokens that can be purchased in a single transaction.
    */
    function getMinTokensPerTx() external view returns(uint256) {
        return _minTokensPerTx;
    }

    /**
    * @dev Returns the maximum number of tokens that a buyer can hold.
    */
    function getMaxTokensPerBuyer() external view returns(uint256) {
        return _maxTokensPerBuyer;
    }

    /**
    * @dev Returns the duration of the ICO in seconds.
    */    
    function getIcoDurationInSeconds() external view returns(uint256) {
        return _icoDurationInSeconds;
    }

    /**
    * @dev Returns the Unix timestamp for the start of the ICO.
    */    
    function getIcoOpeningTime() external view returns(uint256) {
        return _icoOpeningTime;
    }

    /**
    * @dev Returns the Unix timestamp for the end of the ICO.
    */    
    function getIcoClosingTime() external view returns(uint256) {
        return _icoClosingTime;
    }

    /**  
    * @dev Returns the price of token in USD.
    */    
    function getTokenPriceInUSD() external view returns(uint256) {
        return _tokenPriceInUSD;
    }

    /**
    * @dev Returns the price feed address and the price of the native coin to USD from the Chainlink oracle.    
    */  
    function getPriceFeedData() external view returns(address, uint256) {
        return (address(toUsdPriceFeed), _priceInWei());
    }

    /**
    * @dev Returns the address of USDT according to the chain.    
    */
    function getUSDTaddress() external view returns(address) {
        return address(_usdt);
    }

    function getCZEETokenAddress() external view returns(address) {
        return address(_token);
    }


    /////////////////////////////////////////////
    //          Private Sale
    /////////////////////////////////////////////


    /**
    * @dev Allows users to buy tokens during the ICO.
    * @notice This function can only be called while the ICO is open.    
    * @return A boolean indicating whether the token purchase was successful.
    */
    function privateSale_by_NativeCoin() external onlyWhileOpen nonReentrant payable returns(bool) {
        address beneficiary = msg.sender;
        uint256 paymentInWei = msg.value;                
        _preValidatePurchase(beneficiary, paymentInWei);

        uint256 tokenAmount = _getTokenAmount(false, paymentInWei); 
        tokenAmountInWallet[beneficiary] += tokenAmount;   
        _fundsRaised += paymentInWei;
        _icoTokenAmount -= tokenAmount;

        // keeping tokens for the claim by the buyer instead of a transfer
        // _token.transfer(beneficiary, tokenAmount);
        addBeneficiary(beneficiary, tokenAmount);

        emit TokensPurchased(beneficiary, paymentInWei, tokenAmount);
        return true;
    }

    /**
    * @dev Allows users to buy tokens with a Stable coin during the ICO.
    * @notice This function can only be called while the ICO is open.    
    * @param _usdtAmount The amount of USDT in wei.    
    * @return A boolean indicating whether the token purchase was successful.
    */
    function privateSale_buy_USDT(uint256 _usdtAmount) external onlyWhileOpen nonReentrant returns(bool) {
        address beneficiary = msg.sender;                                     
        _preValidatePurchase(beneficiary, _usdtAmount);

        uint256 tokenAmount = _getTokenAmount(true, _usdtAmount);  
        tokenAmountInWallet[beneficiary] += tokenAmount;        
        _icoTokenAmount -= tokenAmount;

        _usdt.transferFrom(beneficiary, address(this), _usdtAmount);

        // keeping tokens for the claim by the buyer instead of a transfer
        // _token.transfer(beneficiary, tokenAmount);
        addBeneficiary(beneficiary, tokenAmount);

        emit TokensPurchased(beneficiary, _usdtAmount, tokenAmount);
        return true;
    }

    function addBeneficiary(address _beneficiary, uint256 purchaseAmount) internal {
        require(_beneficiary != address(0), "The Beneficiary address cannot be zero");
        require(beneficiaries[_beneficiary].scheduleStartTime == 0, "The beneficiary has added already");

        beneficiaryAdrs.push(_beneficiary);

        beneficiaries[_beneficiary] = Beneficiary({
            scheduleStartTime: block.timestamp, 
            tokenAmountInWallet: purchaseAmount,
            withdrawn: 0
            });
    }

    // Beneficiary call this function to withdraw released tokens.
    function withdrawTokens(uint256 _amount) external onlyBeneficiaries nonReentrant returns (bool)  {
        require(_amount > 0, "amount has to be grater than zero");
        address beneficiaryAdr = msg.sender;

        // get amount of tokens that can be withdraw
        (,,,uint256 canwithdraw) = getAvailableTokens(beneficiaryAdr);
        require(canwithdraw >= _amount, "You have not enough released tokens");

        // Update the beneficiary information
        uint256 preWithdrawn = beneficiaries[beneficiaryAdr].withdrawn;
        uint256 curWithdrawn = preWithdrawn.add(_amount);
        beneficiaries[beneficiaryAdr].withdrawn = curWithdrawn;

        // Transfer released tokens to the beneficiary
        _token.transfer(beneficiaryAdr, _amount);

        emit TokensWithdrawn(beneficiaryAdr, _amount);
        return true;
    }

    function getBeneficiaryAdr(uint _idx) public view returns(address) {
        return beneficiaryAdrs[_idx];
    }

    function getBeneficiary(address _beneficiaryAdr) public view returns(uint256, uint256, uint256) {
        Beneficiary storage ben = beneficiaries[_beneficiaryAdr];
        return (ben.scheduleStartTime, ben.tokenAmountInWallet , ben.withdrawn);
    }

    function getReleaseStep() public view returns (uint256) {
        return releaseStep;
    }

    function getReleaseSchedule() public view returns(uint256[3] memory) {
        return releaseSchedule;
    }

    function getCurrentSlot(address _beneficiaryAdr) public view returns (uint256) {
        Beneficiary storage ben = beneficiaries[_beneficiaryAdr];
        require(ben.scheduleStartTime != 0, "You are not a beneficiary.");
        return (block.timestamp.sub(ben.scheduleStartTime)).div(releaseStep);
    }

    // Get the amount of tokens that beneficiary can withdraw now, base on release schedule.
    function getAvailableTokens(address _beneficiary) public view returns ( 
        uint256 beneficiaryTotalTokens,
        uint256 beneficiaryReleasedTokens,
        uint256 withdrawn,
        uint256 canwithdraw
    ) {
        require(_beneficiary != address(0), "The Beneficiary address cannot be zero");
        Beneficiary storage ben = beneficiaries[_beneficiary];
        require(ben.scheduleStartTime != 0, "Invalid beneficiary.");

        beneficiaryTotalTokens = beneficiaries[_beneficiary].tokenAmountInWallet;
        // get the current slot
        uint256 curSlot  = getCurrentSlot(_beneficiary) > 3 ? 3 : getCurrentSlot(_beneficiary);

        if(curSlot == 3) {
            beneficiaryReleasedTokens = beneficiaryTotalTokens;
        }
        else {
            for(uint i; i < curSlot; i++) {
                uint256 slotReleasedTokens = (releaseSchedule[i].mul(beneficiaryTotalTokens)).div(100);
                // Released tokens
                beneficiaryReleasedTokens = beneficiaryReleasedTokens.add(slotReleasedTokens);
            }
        }

        // How many tokens, this Beneficiary has took out of account, until now.
        withdrawn = ben.withdrawn;
        canwithdraw = beneficiaryReleasedTokens.sub(withdrawn);
    }

}