// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import {IERC20} from "aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";

/*
 * @title StreamLine
 * @author David Zhang
 */

contract StreamLine is AutomationCompatible {
    ////////////
    // Errors //
    ////////////

    error StreamLine__TransferFailed();
    error StreamLine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error StreamLine__NeedsMoreThanZero();
    error StreamLine__TokenNotAllowed(address token);
    error StreamLine__InsufficientCollateral();
    error StreamLine__InsufficientTokenDepositForStream();
    error StreamLine__InvalidReceiverAddress();
    error StreamLine__MustBeGreaterThanZero();
    error StreamLine__InsufficientDepositYieldForLoanInterest();

    ///////////
    // Types //
    ///////////

    /////////////////////
    // State Variables //
    /////////////////////

    IPool private immutable i_aavePool;
    address private immutable i_gho;
    uint256 private constant DAYS_IN_YEAR = 365;
    uint256 private constant DAI_CURRENT_APR = 2000000000000000; // In WEI
    uint256 private constant LINK_CURRENT_APR = 800000000000000000; // In WEI

    struct UserDeposit {
        uint256 depositId;
        address tokenCollateralAddress;
        uint256 amountCollateral;
        uint256 depositPeriod;
    }

    /// @dev Enum to represent different token types
    enum BorrowTokenType {
        GHO,
        DAI,
        LINK
    }

    enum DepositTokenType {
        DAI,
        LINK
    }

    /* Chianlink Data Feeds **/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant NUMBERATOR = 75;
    uint256 private constant DENOMINATOR = 100;

    /* Chianlink Automation **/
    bytes private checkData;

    /* Stream Variables **/
    struct Stream {
        uint256 orderId;
        address receiver;
        address asset;
        uint256 streamAmount;
        uint256 interval;
        uint256 endTime;
        uint256 lastTimeStamp;
    }

    /// @dev Mapping of token address to price feed address
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    /// @dev Amount of deposited by user
    mapping(address user => mapping(address depositToken => uint256 amount)) private s_userTokenDeposits;
    /// @dev Amount of supplied by user
    mapping(address user => mapping(address tokenCollateral => uint256 amount)) private s_userSuppliedCollateral;
    /// @dev Amount of borrowed by user
    mapping(address user => mapping(address tokenCollateral => uint256 amount)) private s_userBorrowedAmount;
    /// @dev Mapping of user addresses to streams created by the user
    mapping(address user => mapping(uint256 streamId => Stream)) private s_userToStreams;
    /// @dev Mapping to store user deposit Period with respect to deposit Id
    mapping(address user => mapping(uint256 depositId => uint256 depositPeriod)) private s_userDepositIdToDepositPeriod;
    // Mapping from user address to depositId to UserDeposit struct
    mapping(address => mapping(uint256 => UserDeposit)) private s_userDeposits;
    /// @dev If we know exactly how many tokens we have, we could make this immutable
    address[] private s_collateralTokens;

    ////////////
    // Events //
    ////////////

    event TokenDeposited(
        address indexed user, address indexed token, uint256 indexed amount, uint256 id, uint256 period
    );
    event Supplied(address indexed user, uint256 amount, address indexed token);
    event Borrowed(address indexed user, uint256 indexed amount, address indexed token);
    event NewStream(
        uint256 indexed orderId,
        address indexed receiver,
        address indexed asset,
        uint256 amount,
        uint256 interval,
        uint256 duaration
    );
    event Repaid(address indexed user, uint256 indexed amount, address indexed token);
    event WithdraToken(address indexed user, address indexed token, uint256 indexed amount);

    ///////////////
    // Modifiers //
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert StreamLine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert StreamLine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////

    constructor(address aavePool, address gho, address[] memory tokenAddresses, address[] memory priceFeedAddresses) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert StreamLine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or DAI / USD or USDC / USD or USDT / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_aavePool = IPool(aavePool);
        i_gho = gho;
    }
    ////////////////////////
    // External Functions //
    ////////////////////////

    ///////////////////////////
    // Aave Pool Interaction //
    ///////////////////////////

    /**
     * @notice Allows a user to deposit collateral, creating a new deposit record.
     * @dev This function can only be called if the deposited amount is greater than zero and the token is allowed for collateral.
     * @param depositId Unique identifier for the deposit.
     * @param tokenCollateralAddress Address of the collateral token.
     * @param amountCollateral Amount of collateral to be deposited, in Wei.
     * @param depositPeriodDays Period for which the collateral is deposited, in days.
     * @dev Emits a TokenDeposited event with details of the deposited collateral, including the user's address, collateral token, amount, deposit ID, and deposit period.
     * @dev Throws a StreamLine__TransferFailed error if the token transfer from the user to the contract fails.
     */
    function depositCollateral(
        uint256 depositId,
        address tokenCollateralAddress,
        uint256 amountCollateral, // In WEI
        uint256 depositPeriodDays // In Day
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) {
        s_userTokenDeposits[msg.sender][tokenCollateralAddress] += amountCollateral;
        s_userDepositIdToDepositPeriod[msg.sender][depositId] = depositPeriodDays;
        s_userDeposits[msg.sender][depositId] = UserDeposit({
            depositId: depositId,
            tokenCollateralAddress: tokenCollateralAddress,
            amountCollateral: amountCollateral,
            depositPeriod: depositPeriodDays
        });

        // Call the approve function for the user through the front end
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert StreamLine__TransferFailed();
        }

        emit TokenDeposited(msg.sender, tokenCollateralAddress, amountCollateral, depositId, depositPeriodDays);
    }

    /**
     * @notice Allows a user to supply additional collateral to the Aave lending pool.
     * @dev This function can only be called if the supplied collateral amount is greater than zero and the token is allowed for collateral.
     * @param tokenCollateralAddress Address of the collateral token to be supplied.
     * @param collateralAmount Amount of collateral to be supplied, in Wei.
     * @dev Emits a Supplied event with details of the user's address, supplied collateral amount, and collateral token.
     * @dev Throws a StreamLine__InsufficientCollateral error if the user has insufficient collateral for the specified token.
     * @dev Approves the Aave lending pool to spend the collateral on behalf of the user and then calls the Aave supply function.
     * @dev Increases the user's supplied collateral balance for the specified token.
     */
    function supplyCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount // In WEI
    ) external moreThanZero(collateralAmount) isAllowedToken(tokenCollateralAddress) {
        if (s_userTokenDeposits[msg.sender][tokenCollateralAddress] < collateralAmount) {
            revert StreamLine__InsufficientCollateral();
        }
        IERC20(tokenCollateralAddress).approve(address(i_aavePool), collateralAmount);
        i_aavePool.supply(tokenCollateralAddress, collateralAmount, address(this), 0);
        s_userSuppliedCollateral[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit Supplied(msg.sender, collateralAmount, tokenCollateralAddress);
    }

    /**
     * @notice Allows a user to borrow tokens from the Aave lending pool using supplied collateral.
     * @dev This function can only be called if the borrowed amount is greater than zero and the collateral token is allowed.
     * @param collateralTokenAddress Address of the collateral token against which the user wants to borrow.
     * @param borrowAmount Amount of tokens to be borrowed, in Wei.
     * @dev Emits a Borrowed event with details of the user's address, borrowed amount, and collateral token.
     * @dev Calls the Aave borrow function to initiate the borrowing process, specifying a variable interest rate loan.
     * @dev Increases the user's borrowed amount for the specified collateral token.
     */
    function borrowToken(
        address collateralTokenAddress,
        uint256 borrowAmount // In WEI
    ) external moreThanZero(borrowAmount) isAllowedToken(collateralTokenAddress) {
        i_aavePool.borrow(collateralTokenAddress, borrowAmount, 2, 0, address(this)); // 2 indicates that the loan is a variable interest rate loan
        s_userBorrowedAmount[msg.sender][collateralTokenAddress] += borrowAmount;
        emit Borrowed(msg.sender, borrowAmount, collateralTokenAddress);
    }

    /**
     * @notice Allows the user to repay a specified amount of borrowed tokens.
     * @param collateralTokenAddress The address of the token used as collateral.
     * @param repayAmount The amount, in WEI, to be repaid.
     * @dev The user must have sufficient collateral to cover the repayment.
     * @dev Approves Aave Pool contract to spend the specified amount of tokens.
     * @dev Calls Aave's repay function to repay the borrowed amount.
     * @dev Updates the user's borrowed amount.
     * @dev Emits a 'Repaid' event for tracking purposes.
     */
    function repayToken(
        address collateralTokenAddress,
        uint256 repayAmount // In WEI
    ) external moreThanZero(repayAmount) isAllowedToken(collateralTokenAddress) {
        if (s_userTokenDeposits[msg.sender][collateralTokenAddress] < repayAmount) {
            revert StreamLine__InsufficientCollateral();
        }
        IERC20(collateralTokenAddress).approve(address(i_aavePool), repayAmount);
        i_aavePool.repay(collateralTokenAddress, repayAmount, 2, address(this));
        s_userBorrowedAmount[msg.sender][collateralTokenAddress] -= repayAmount;
        emit Repaid(msg.sender, repayAmount, collateralTokenAddress);
    }

    /**
     * @notice Allows the user to withdraw a specified amount of deposited tokens.
     * @param tokenCollateralAddress The address of the deposited token.
     * @param amountCollateral The amount, in WEI, to be withdrawn.
     * @dev The user must have sufficient deposited tokens to cover the withdrawal.
     * @dev Emits a 'Withdrawn' event for tracking purposes.
     * @dev Transfers the specified amount of tokens to the user.
     * @dev If the transfer fails, reverts the transaction with 'TransferFailed' error.
     */
    function withdrawToken(
        address tokenCollateralAddress,
        uint256 amountCollateral // In WEI
    ) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) {
        if (s_userTokenDeposits[msg.sender][tokenCollateralAddress] < amountCollateral) {
            revert StreamLine__InsufficientCollateral();
        }

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert StreamLine__TransferFailed();
        }
        s_userTokenDeposits[msg.sender][tokenCollateralAddress] -= amountCollateral;

        emit WithdraToken(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    //////////////////////////        ////////////////////
    // Chainlink Automation //   &&   // Stream Service //
    //////////////////////////        ////////////////////

    /**
     * @notice Opens a new streaming payment arrangement between the user and a receiver using deposited or borrowed tokens.
     * @dev This function checks if the user has sufficient token deposits or borrowed amounts to cover the total streaming amount.
     * @param orderId Unique identifier for the stream order.
     * @param tokenCollateralAddress Address of the deposited or borrowed token used for the stream.
     * @param amount Initial streaming amount, in Wei.
     * @param totalStreamAmount Total streaming amount for the entire duration, in Wei.
     * @param receiverAddress Address of the receiver who will receive the streamed funds.
     * @param interval Time interval between consecutive stream payments, in seconds.
     * @param duration Total duration of the streaming arrangement, in seconds.
     * @dev Emits a NewStream event with details of the new stream, including orderId, receiver, tokenCollateralAddress, amount, interval, and duration.
     * @dev Creates a new Stream struct and associates it with the user and orderId.
     * @dev Checks for validity of receiver address, positive interval, and positive duration.
     * @dev The stream ends automatically when the duration elapses.
     * @dev Reverts if there is insufficient token deposit or borrowed amount to cover the total streaming amount.
     */
    function openStream(
        uint256 orderId,
        address tokenCollateralAddress,
        uint256 amount, // In WEI
        uint256 totalStreamAmount, // In WEI
        address receiverAddress,
        uint256 interval, // In Seconds
        uint256 duration // In Seconds
    ) public {
        bool hasSufficientDeposit = s_userTokenDeposits[msg.sender][tokenCollateralAddress] >= totalStreamAmount;
        bool hasSufficientBorrowed = s_userBorrowedAmount[msg.sender][tokenCollateralAddress] >= totalStreamAmount;
        if (!hasSufficientDeposit && !hasSufficientBorrowed) {
            revert StreamLine__InsufficientTokenDepositForStream();
        }

        if (receiverAddress == address(0)) {
            revert StreamLine__InvalidReceiverAddress();
        }
        if (interval < 0) {
            revert StreamLine__MustBeGreaterThanZero();
        }
        if (duration < 0) {
            revert StreamLine__MustBeGreaterThanZero();
        }

        Stream memory newStream = Stream({
            orderId: orderId,
            receiver: receiverAddress,
            asset: tokenCollateralAddress,
            streamAmount: amount,
            interval: interval,
            endTime: block.timestamp + duration,
            lastTimeStamp: block.timestamp
        });

        s_userToStreams[msg.sender][newStream.orderId] = newStream;
        checkData = abi.encode(newStream);

        emit NewStream(orderId, receiverAddress, tokenCollateralAddress, amount, interval, duration);
    }

    /**
     * @notice Checks if upkeep is needed for a streaming payment arrangement.
     * @dev Decodes the provided `checkData` into a Stream struct to obtain information about the stream.
     * @dev Determines if the stream is still active and if the time interval for the next payment has passed.
     * @param * checkData Encoded data containing information about the stream.
     * @dev upkeepNeeded Boolean indicating whether upkeep is needed for the stream.
     * @dev performData Encoded data containing information about the stream, to be used in the performUpkeep function.
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Stream memory stream = abi.decode(checkData, (Stream));
        bool isStreamActive = block.timestamp < stream.endTime;
        bool timePassed = (block.timestamp - stream.lastTimeStamp) > stream.interval;

        upkeepNeeded = isStreamActive && timePassed;
        performData = checkData;
        return (upkeepNeeded, performData);
    }

    /**
     * @notice Performs the upkeep for a streaming payment arrangement.
     * @dev Decodes the provided `performData` into a Stream struct to obtain information about the stream.
     * Checks if the time interval for the next payment has passed and if the stream is still active.
     * If conditions are met, updates the last timestamp, transfers the stream amount to the receiver, and reverts on transfer failure.
     * @param performData Encoded data containing information about the stream.
     */
    function performUpkeep(bytes calldata performData) external override {
        Stream memory stream = abi.decode(performData, (Stream));

        if (block.timestamp - stream.lastTimeStamp > stream.interval && block.timestamp < stream.endTime) {
            stream.lastTimeStamp = block.timestamp;
            bool success = IERC20(stream.asset).transfer(stream.receiver, stream.streamAmount);
            if (!success) {
                revert StreamLine__TransferFailed();
            }
        }
    }

    //////////////////////////////////////////////
    // Private & Internal View & Pure Functions //
    //////////////////////////////////////////////

    /**
     * @notice Retrieves the USD value of a given amount of token.
     * @param token The ERC20 token address for which the USD value is requested.
     * @param amount The amount of the token (in WEI).
     * @return The USD value of the specified token amount.
     * @dev This function uses the Chainlink price feed for conversion rates.
     */
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // for example: 1 ETH = 1000 USD
        // The returned ETH/USD from Chainlink is 1000 * 1e8
        // And the amount is 1e18;
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        // (1000e8 * 1e10) * 1e18 / 1e18 = 1000e18;
        return (uint256(price) * ADDITIONAL_FEED_PRECISION) * amount / PRECISION; // In WEI
    }

    //////////////////////////////////////////////
    // External & Public View & Pure Functions  //
    //////////////////////////////////////////////

    /* Calculate Functions **/

    /**
     * @notice Calculates the debt interest in Ether, considering the interest generated from a deposit and the interest to be repaid on a loan.
     * @dev This function is intended to be called externally.
     * @param depositTokenType Type of the deposit token (0 for DAI, 1 for LINK).
     * @param depositTokenAddress Address of the deposit token contract.
     * @param depositAmountWei Amount of the deposit in Wei.
     * @param depositPeriodDays Period of the deposit in days.
     * @param borrowTokentype Type of the borrowed token (0 for GHO, 1 for DAI, 2 for LINK).
     * @param borrowTokenAddress Address of the borrowed token contract.
     * @param borrowedAmountWei Amount borrowed in Wei.
     * @param borrowPeriodDays Period of the loan in days.
     * @return debtInterestInEther The calculated debt interest in Ether. If the deposit yield covers the loan interest, the result is 0, indicating no debt.
     */
    function calculateCollateralForDebtCoverage(
        // Asset Info
        DepositTokenType depositTokenType, // 0 DAI, 1 LINK
        address depositTokenAddress,
        uint256 depositAmountWei,
        uint256 depositPeriodDays,
        // Debt Info
        BorrowTokenType borrowTokentype, // 0 GHO, 1 DAI, 2 LINK
        address borrowTokenAddress,
        uint256 borrowedAmountWei,
        uint256 borrowPeriodDays
    ) external view returns (uint256 debtInterestInEther) {
        // For example:
        // depositInterest = 273972602739726 In Wei // 0.0002 In Ether (DAI Token)
        uint256 depositInterest = calculateDepositInterest(depositTokenType, depositAmountWei, depositPeriodDays); // In WEI
        // finalDebt = 7001917808219178082 In Wei // 7.001917808219178082 In Ether (GHO Token)
        uint256 finalDebt = calculateFinalDebt(borrowTokentype, borrowedAmountWei, borrowPeriodDays); // Principal + interest In WEI
        // depositInterestUsdValue = 268493150684931 In Wei // 0.000268493 In Ether
        uint256 depositInterestUsdValue = _getUsdValue(depositTokenAddress, depositInterest); // In WEI
        // finalDebtUsdValue = 7001917808219176000 In Wei // 7.001917808219176 In Ether
        uint256 finalDebtUsdValue = _getUsdValue(borrowTokenAddress, finalDebt); // In WEI
        //
        uint256 debtInterestUsdValue;
        //        7.001917808219176 <  0.000268493 In Ether
        if (depositInterestUsdValue < finalDebtUsdValue) {
            // 7.001649315219176 = 7.001917808219176 - 0.000268493 In Ether
            debtInterestUsdValue = finalDebtUsdValue - depositInterestUsdValue; // In WEI
        }
        // perDepositTokenUsdValue = 1000000000000000000 In Wei (DAI Token)
        uint256 perDepositTokenUsdValue = _getUsdValue(depositTokenAddress, 1e18); // In WEI
        //       7  In Ether      =     7.001649315219176e18  / 1e18 In Wei
        debtInterestInEther = (debtInterestUsdValue / perDepositTokenUsdValue); // In ETHER
        //      7  In Ether, else If it can be covers debt, the return result is 0
        return debtInterestInEther; // In WEI, If it can be covers debt, the return result is 0, indicating no debt.
    }

    /**
     * @notice Calculates the interest earned on a deposit based on the deposit token type, amount, and period.
     * @dev The interest calculation depends on the deposit token type, and the formula considers a predefined ratio (numerator/denominator).
     * @param tokenType The type of deposit token (e.g., DAI or LINK).
     * @param depositAmountWei The amount of deposit in WEI.
     * @param depositPeriodDays The duration of the deposit period in days.
     * @return depositInterest The calculated interest on the deposit in WEI.
     */
    function calculateDepositInterest(DepositTokenType tokenType, uint256 depositAmountWei, uint256 depositPeriodDays)
        public
        pure
        returns (uint256)
    {
        uint256 numerator;
        uint256 denominator;

        if (tokenType == DepositTokenType.DAI) {
            numerator = 2;
            denominator = 1000;
        } else if (tokenType == DepositTokenType.LINK) {
            numerator = 80;
            denominator = 100;
        } else {
            revert("Invalid token type");
        }

        uint256 maxLoanInUsd = (depositAmountWei * numerator) / denominator;
        uint256 depositInterest = (maxLoanInUsd * depositPeriodDays) / DAYS_IN_YEAR;

        return depositInterest; // In WEI
    }

    /**
     * @notice Calculates the interest to be repaid on a loan based on the loan token type, borrowed amount, and period.
     * @dev The interest calculation depends on the borrowed token type, and the formula considers a predefined ratio (numerator/denominator).
     * @param tokenType The type of borrowed token (e.g., GHO, DAI, or LINK).
     * @param borrowedAmountWei The amount borrowed in WEI.
     * @param borrowPeriodDays The duration of the loan repayment period in days.
     * @return loanRepaymentInterest The calculated interest to be repaid on the loan in WEI.
     */
    function calculateLoanRepaymentInterest(
        BorrowTokenType tokenType,
        uint256 borrowedAmountWei,
        uint256 borrowPeriodDays
    ) public pure returns (uint256) {
        uint256 numerator;
        uint256 denominator;

        if (tokenType == BorrowTokenType.GHO) {
            numerator = 2;
            denominator = 100;
        } else if (tokenType == BorrowTokenType.DAI) {
            numerator = 1;
            denominator = 100;
        } else if (tokenType == BorrowTokenType.LINK) {
            numerator = 218;
            denominator = 100;
        } else {
            revert("Invalid token type");
        }

        uint256 maxLoanInUsd = (borrowedAmountWei * numerator) / denominator;
        uint256 loanRepaymentInterest = (maxLoanInUsd * borrowPeriodDays) / DAYS_IN_YEAR;

        return loanRepaymentInterest; // // In WEI
    }

    /**
     * @notice Calculates the final debt amount to be repaid, including the borrowed principal and accrued interest.
     * @dev The calculation considers the borrowed token type, borrowed amount, and the loan repayment period.
     * @param tokenType The type of borrowed token (e.g., GHO, DAI, or LINK).
     * @param borrowedAmountWei The amount borrowed in WEI.
     * @param borrowPeriodDays The duration of the loan repayment period in days.
     * @return totalDebt The total debt amount to be repaid, including principal and interest, in WEI.
     */
    function calculateFinalDebt(BorrowTokenType tokenType, uint256 borrowedAmountWei, uint256 borrowPeriodDays)
        public
        pure
        returns (uint256)
    {
        uint256 numerator;
        uint256 denominator;

        if (tokenType == BorrowTokenType.GHO) {
            numerator = 2;
            denominator = 100;
        } else if (tokenType == BorrowTokenType.DAI) {
            numerator = 1;
            denominator = 100;
        } else if (tokenType == BorrowTokenType.LINK) {
            numerator = 218;
            denominator = 100;
        } else {
            revert("Invalid token type");
        }

        uint256 maxLoanInUsd = (borrowedAmountWei * numerator) / denominator;
        uint256 interestAccrued = (maxLoanInUsd * borrowPeriodDays) / DAYS_IN_YEAR;
        uint256 totalDebt = borrowedAmountWei + interestAccrued;

        return totalDebt; // // In WEI Principal + interest
    }

    /**
     * @notice Calculates the final asset value, including the deposited principal and accrued interest.
     * @dev The calculation considers the deposit token type, deposit amount, and the deposit period.
     * @param tokenType The type of deposit token (e.g., DAI or LINK).
     * @param depositAmountWei The amount of deposit in WEI.
     * @param depositPeriodDays The duration of the deposit period in days.
     * @return totalAsset The total asset value, including principal and interest, in WEI.
     */
    function calculateFinalAsset(DepositTokenType tokenType, uint256 depositAmountWei, uint256 depositPeriodDays)
        external
        pure
        returns (uint256)
    {
        uint256 numerator;
        uint256 denominator;

        if (tokenType == DepositTokenType.DAI) {
            numerator = 2;
            denominator = 1000;
        } else if (tokenType == DepositTokenType.LINK) {
            numerator = 80;
            denominator = 100;
        } else {
            revert("Invalid token type");
        }

        uint256 maxLoanInUsd = (depositAmountWei * numerator) / denominator;
        uint256 interestAccrued = (maxLoanInUsd * depositPeriodDays) / DAYS_IN_YEAR;
        uint256 totalAsset = depositAmountWei + interestAccrued;

        return totalAsset; // In WEI
    }

    /**
     * @notice Calculates the maximum amount of GHO that can be borrowed against a given collateral.
     * @param tokenCollateralAddress The ERC20 token address of the collateral.
     * @param amountCollateral The amount of the collateral (in WEI).
     * @return maxGhoToBorrow The maximum amount of GHO that can be borrowed.
     * @dev This calculation is based on the USD value of the collateral and the loan-to-value ratio.
     */

    function calculateMaxTokenToBorrow(
        address tokenCollateralAddress,
        uint256 amountCollateral // in WEI
    ) external view returns (uint256 maxGhoToBorrow) {
        uint256 collateralUsdValue = _getUsdValue(tokenCollateralAddress, amountCollateral); // 1000e18
        uint256 maxLoanInUsd = (collateralUsdValue * NUMBERATOR) / DENOMINATOR; // Estimate LTV
        uint256 ghoUsdValue = _getUsdValue(i_gho, 1e18); //  GHO decimals is 18 on sepolia = 1e18

        maxGhoToBorrow = maxLoanInUsd / ghoUsdValue; // 1 * 1e18 / 1e18
        return maxGhoToBorrow; // In ETHER
    }

    /* Get Information Functions **/

    /**
     * @notice Retrieves the account information of a user from the Aave pool.
     * @param user The address of the user whose account information is being requested.
     * @return totalCollateralBase The total collateral of the user in the base currency.
     * @return totalDebtBase The total debt of the user in the base currency.
     * @return availableBorrowsBase The available borrow amount for the user in the base currency.
     * @return currentLiquidationThreshold The current liquidation threshold for the user's account.
     * @return ltv The loan-to-value ratio of the user's account.
     * @return healthFactor The health factor of the user's account.
     */
    function getAccountInformation(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor) =
            i_aavePool.getUserAccountData(user);
        return
            (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor);
    }

    /**
     * @notice Retrieves the information of a specific stream created by the user.
     * @param streamId The unique identifier of the stream.
     * @return streamInfo The information of the specified stream.
     */
    function getUserStreamInfo(address user, uint256 streamId) external view returns (Stream memory) {
        return s_userToStreams[user][streamId];
    }

    ////////////////////////////////////////
    // Getter Public / External Functions //
    ////////////////////////////////////////

    function getPoolAddress() external view returns (IPool) {
        return i_aavePool;
    }

    function getGhoAddress() external view returns (address) {
        return i_gho;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getUserDepositAmount(address user, address depositToken) external view returns (uint256) {
        return s_userTokenDeposits[user][depositToken]; // In WEI
    }

    function getUserSuppliedCollateralAmount(address user, address tokenCollateral) external view returns (uint256) {
        return s_userSuppliedCollateral[user][tokenCollateral]; // In WEI
    }

    function getUserBorrowedAmount(address user, address tokenCollateral) external view returns (uint256) {
        return s_userBorrowedAmount[user][tokenCollateral]; // In WEI
    }

    function getDepositPeriodForUser(address user, uint256 depositId) external view returns (uint256) {
        return s_userDeposits[user][depositId].depositPeriod; // In Day
    }

    function getUserDepositInfo(address user, uint256 depositId) external view returns (UserDeposit memory) {
        return s_userDeposits[user][depositId];
    }

    function getDAITokenCurrentAPR() external pure returns (uint256) {
        return DAI_CURRENT_APR; // In WEI
    }

    function getLINKTokenCurrentAPR() external pure returns (uint256) {
        return LINK_CURRENT_APR; // In WEI
    }
}