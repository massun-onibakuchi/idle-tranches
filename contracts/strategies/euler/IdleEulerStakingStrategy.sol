// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../../interfaces/euler/IEToken.sol";
import "../../interfaces/euler/IDToken.sol";
import "../../interfaces/euler/IMarkets.sol";
import "../../interfaces/euler/IEulerGeneralView.sol";
import "../../interfaces/IStakingRewards.sol";

import "../BaseStrategy.sol";

/// @author Euler Finance + Idle Finance
/// @title IdleEulerStakingStrategy
/// @notice IIdleCDOStrategy to deploy funds in Euler Finance and then stake eToken in Euler staking contracts
/// @dev This contract should not have any funds at the end of each tx.
/// The contract is upgradable, to add storage slots, add them after the last `###### End of storage VXX`
contract IdleEulerStakingStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Detailed;

    /// ###### End of storage BaseStrategy

    /// @notice Euler account id
    uint256 internal constant SUB_ACCOUNT_ID = 0;
    /// @notice Euler Governance Token
    IERC20Detailed internal constant EUL = IERC20Detailed(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    /// @notice Euler markets contract address
    IMarkets internal constant EULER_MARKETS = IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    /// @notice Euler general view contract address
    IEulerGeneralView internal constant EULER_GENERAL_VIEW =
        IEulerGeneralView(0xACC25c4d40651676FEEd43a3467F3169e3E68e42);

    IEToken public eToken;
    IStakingRewards public stakingRewards;

    /// ###### End of storage IdleEulerStakingStrategy

    // ###################
    // Initializer
    // ###################

    /// @notice can only be called once
    /// @dev Initialize the upgradable contract
    /// @param _eToken address of the eToken
    /// @param _underlyingToken address of the underlying token
    /// @param _eulerMain Euler main contract address
    /// @param _stakingRewards stakingRewards contract address
    /// @param _owner owner address
    function initialize(
        address _eToken,
        address _underlyingToken,
        address _eulerMain,
        address _stakingRewards,
        address _owner
    ) public initializer {
        _initialize(
            string(abi.encodePacked("Idle Euler ", IERC20Detailed(_eToken).name(), " Staking Strategy")),
            string(abi.encodePacked("idleEulStk_", IERC20Detailed(_eToken).symbol())),
            _underlyingToken,
            _owner
        );
        eToken = IEToken(_eToken);
        stakingRewards = IStakingRewards(_stakingRewards);

        // approve Euler protocol uint256 max for deposits
        underlyingToken.safeApprove(_eulerMain, type(uint256).max);
        // approve stakingRewards contract uint256 max for staking
        IERC20Detailed(_eToken).safeApprove(_stakingRewards, type(uint256).max);
    }

    // ###################
    // Public methods
    // ###################

    /// @dev msg.sender should approve this contract first to spend `_amount` of `token`
    /// @param _amount amount of `token` to deposit
    /// @return shares strategyTokens minted
    function deposit(uint256 _amount) external override onlyIdleCDO returns (uint256 shares) {
        if (_amount != 0) {
            uint256 eTokenBalanceBefore = eToken.balanceOf(address(this));
            // Send tokens to the strategy
            underlyingToken.safeTransferFrom(msg.sender, address(this), _amount);

            eToken.deposit(SUB_ACCOUNT_ID, _amount);

            // Mint shares 1:1 ratio
            shares = eToken.balanceOf(address(this)) - eTokenBalanceBefore;
            if (address(stakingRewards) != address(0)) {
                stakingRewards.stake(shares);
            }

            _mint(msg.sender, shares);
        }
    }

    function redeemRewards(bytes calldata data)
        public
        override
        onlyIdleCDO
        nonReentrant
        returns (uint256[] memory rewards)
    {
        rewards = _redeemRewards(data);
    }

    /// @dev msg.sender should approve this contract first to spend `_amount` of `strategyToken`
    /// @param _shares amount of strategyTokens to redeem
    /// @return amountRedeemed  amount of underlyings redeemed
    function redeem(uint256 _shares) external override onlyIdleCDO returns (uint256 amountRedeemed) {
        if (_shares != 0) {
            _burn(msg.sender, _shares);
            // Withdraw amount needed
            amountRedeemed = _withdraw((_shares * price()) / EXP_SCALE, msg.sender);
        }
    }

    /// @notice Redeem Tokens
    /// @param _amount amount of underlying tokens to redeem
    /// @return amountRedeemed Amount of underlying tokens received
    function redeemUnderlying(uint256 _amount) external override onlyIdleCDO returns (uint256 amountRedeemed) {
        uint256 _shares = (_amount * EXP_SCALE) / price();
        if (_shares != 0) {
            _burn(msg.sender, _shares);
            // Withdraw amount needed
            amountRedeemed = _withdraw(_amount, msg.sender);
        }
    }

    // ###################
    // Internal
    // ###################

    /// @dev Unused but needed for BaseStrategy
    function _deposit(uint256 _amount) internal override returns (uint256 amountUsed) {}

    /// @param _amountToWithdraw in underlyings
    /// @param _destination address where to send underlyings
    /// @return amountWithdrawn returns the amount withdrawn
    function _withdraw(uint256 _amountToWithdraw, address _destination)
        internal
        override
        returns (uint256 amountWithdrawn)
    {
        IEToken _eToken = eToken;
        IERC20Detailed _underlyingToken = underlyingToken;
        IStakingRewards _stakingRewards = stakingRewards;

        if (address(_stakingRewards) != address(0)) {
            // Unstake from StakingRewards
            _stakingRewards.withdraw(_eToken.convertUnderlyingToBalance(_amountToWithdraw));
        }

        uint256 underlyingsInEuler = eToken.balanceOfUnderlying(address(this));
        if (_amountToWithdraw > underlyingsInEuler) {
            _amountToWithdraw = underlyingsInEuler;
        }

        // Withdraw from Euler
        uint256 underlyingBalanceBefore = _underlyingToken.balanceOf(address(this));
        _eToken.withdraw(SUB_ACCOUNT_ID, _amountToWithdraw);
        amountWithdrawn = _underlyingToken.balanceOf(address(this)) - underlyingBalanceBefore;
        // Send tokens to the destination
        _underlyingToken.safeTransfer(_destination, amountWithdrawn);
    }

    /// @return rewards rewards[0] : rewards redeemed
    function _redeemRewards(bytes calldata) internal override returns (uint256[] memory rewards) {
        IStakingRewards _stakingRewards = stakingRewards;
        if (address(_stakingRewards) != address(0)) {
            // Get rewards from StakingRewards contract
            stakingRewards.getReward();
        }
        // transfer rewards to the IdleCDO contract
        rewards = new uint256[](1);
        rewards[0] = EUL.balanceOf(address(this));
        EUL.safeTransfer(idleCDO, rewards[0]);
    }

    // ###################
    // Views
    // ###################

    /// @return net price in underlyings of 1 strategyToken
    function price() public view override returns (uint256) {
        uint256 eTokenDecimals = eToken.decimals();
        // return price of 1 eToken in underlying
        return eToken.convertBalanceToUnderlying(10**eTokenDecimals);
    }

    // TODO add staking apr 

    /// @dev Returns supply apr for providing liquidity minus reserveFee
    /// @return apr net apr (fees should already be excluded)
    function getApr() external view override returns (uint256 apr) {
        // Use the markets module:
        IMarkets markets = IMarkets(EULER_MARKETS);
        IDToken dToken = IDToken(markets.underlyingToDToken(token));
        uint256 borrowSPY = uint256(int256(markets.interestRate(token)));
        uint256 totalBorrows = dToken.totalSupply();
        uint256 totalBalancesUnderlying = eToken.totalSupplyUnderlying();
        uint32 reserveFee = markets.reserveFee(token);
        // (borrowAPY, supplyAPY)
        (, apr) = IEulerGeneralView(EULER_GENERAL_VIEW).computeAPYs(
            borrowSPY,
            totalBorrows,
            totalBalancesUnderlying,
            reserveFee
        );
        // apr is eg 0.024300334 * 1e27 for 2.43% apr
        // while the method needs to return the value in the format 2.43 * 1e18
        // so we do apr / 1e9 * 100 -> apr / 1e7
        apr = apr / 1e7;
    }

    /// @return tokens array of reward token addresses
    function getRewardTokens() external pure override returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(EUL);
    }

    // ###################
    // Protected
    // ###################

    ///@notice Claim rewards and withdraw all from StakingRewards contract
    function exitStaking() external onlyOwner {
        stakingRewards.exit();
    }

    function setStakingRewards(address _stakingRewards) external onlyOwner {
        stakingRewards = IStakingRewards(_stakingRewards);
    }
}