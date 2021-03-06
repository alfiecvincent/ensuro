// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseAssetManager} from "./BaseAssetManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPolicyPool} from "../interfaces/IPolicyPool.sol";
import {IPolicyPoolConfig} from "../interfaces/IPolicyPoolConfig.sol";
import {WadRayMath} from "./WadRayMath.sol";
import {ILendingPoolAddressesProvider} from "@aave/protocol-v2/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";
import {IAToken} from "@aave/protocol-v2/contracts/interfaces/IAToken.sol";
import {IPriceOracle} from "@aave/protocol-v2/contracts/interfaces/IPriceOracle.sol";
import {AaveProtocolDataProvider} from "@aave/protocol-v2/contracts/misc/AaveProtocolDataProvider.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title AssetManager that reinvests the capital in AAVE
 * @dev Deposits and withdraw from AAVE, also converts the rewards.
 *      Invest into AAVE AToken for the underlying asset (ex. USDC) getting lending interests.
 *      When needs to deinvest, first deinvest from AAVE, but also can liquidate the rewards
 *      (AAVE in mainnet or MATIC in Polygon) using a DEX.
 *      Above a given threshold, the rewards are claimed. Also, above a given threshold they are also reinvested
 *      to accrue additional interests and rewards.
 *      An authorized user (SWAP_REWARDS_ROLE) can force the swap of the rewards for the pool's currency.
 * @custom:security-contact security@ensuro.co
 * @author Ensuro
 */
contract AaveAssetManager is BaseAssetManager {
  using SafeERC20 for IERC20Metadata;
  using WadRayMath for uint256;

  bytes32 public constant SWAP_REWARDS_ROLE = keccak256("SWAP_REWARDS_ROLE");

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ILendingPoolAddressesProvider internal immutable _aaveAddrProv;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IAToken internal immutable _aToken;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IAToken internal immutable _rewardAToken;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IERC20Metadata internal immutable _rewardToken;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IUniswapV2Router02 internal immutable _swapRouter; // We will use SushiSwap in Polygon
  uint256 internal _claimRewardsMin; // Minimum amount of rewards accumulated to claim
  uint256 internal _reinvestRewardsMin; // Minimum amount of rewards to reinvest into AAVE
  uint256 internal _maxSlippage; // Maximum slippage in WAD

  bytes32 internal constant DATA_PROVIDER_ID =
    0x0100000000000000000000000000000000000000000000000000000000000000;

  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  event RewardSwapped(uint256 rewardIn, uint256 currencyOut);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    IPolicyPool policyPool_,
    ILendingPoolAddressesProvider aaveAddrProv_,
    IUniswapV2Router02 swapRouter_
  ) BaseAssetManager(policyPool_) {
    _aaveAddrProv = aaveAddrProv_;
    _swapRouter = swapRouter_;
    AaveProtocolDataProvider dataProvider = AaveProtocolDataProvider(
      aaveAddrProv_.getAddress(DATA_PROVIDER_ID)
    );
    (address aToken_, , ) = dataProvider.getReserveTokensAddresses(address(policyPool_.currency()));
    _aToken = IAToken(aToken_);
    address rewardToken_ = IAToken(aToken_).getIncentivesController().REWARD_TOKEN();
    _rewardToken = IERC20Metadata(rewardToken_);
    (address rewardAToken_, , ) = dataProvider.getReserveTokensAddresses(address(rewardToken_));
    _rewardAToken = IAToken(rewardAToken_);
  }

  function initialize(
    uint256 liquidityMin_,
    uint256 liquidityMiddle_,
    uint256 liquidityMax_,
    uint256 claimRewardsMin_,
    uint256 reinvestRewardsMin_,
    uint256 maxSlippage_
  ) public initializer {
    __BaseAssetManager_init(liquidityMin_, liquidityMiddle_, liquidityMax_);
    __AaveAssetManager_init(claimRewardsMin_, reinvestRewardsMin_, maxSlippage_);
  }

  // solhint-disable-next-line func-name-mixedcase
  function __AaveAssetManager_init(
    uint256 claimRewardsMin_,
    uint256 reinvestRewardsMin_,
    uint256 maxSlippage_
  ) internal initializer {
    _claimRewardsMin = claimRewardsMin_;
    _reinvestRewardsMin = reinvestRewardsMin_;
    require(maxSlippage_ <= 1e17, "maxSlippage can't be more than 10%");
    _maxSlippage = maxSlippage_;
  }

  function getInvestmentValue() public view override returns (uint256) {
    uint256 balance = aToken().balanceOf(address(this));
    uint256 rewardBalance = rewardToken().balanceOf(address(this)) +
      rewardAToken().balanceOf(address(this));
    // Don't count unclaimedRewards as part of investmentValue to save gas and because if doing that will
    // also need to claim rewards as part of _deinvest process
    return balance + _rewardToCurrency(rewardBalance);
  }

  function unclaimedRewards() public view returns (uint256) {
    // Also add unclaimed rewards
    IAToken atk = aToken();
    address[] memory atks = new address[](2);
    atks[0] = address(atk);
    atks[1] = address(rewardAToken());
    return atk.getIncentivesController().getRewardsBalance(atks, address(this));
  }

  function _claimRewards(bool ignoreMin) internal returns (uint256) {
    if (ignoreMin || unclaimedRewards() > _claimRewardsMin) {
      IAToken atk = aToken();
      address[] memory atks = new address[](2);
      atks[0] = address(atk);
      atks[1] = address(rewardAToken());
      return atk.getIncentivesController().claimRewards(atks, type(uint256).max, address(this));
    } else {
      return 0;
    }
  }

  function lendingPool() public view returns (ILendingPool) {
    return ILendingPool(_aaveAddrProv.getLendingPool());
  }

  function priceOracle() public view returns (IPriceOracle) {
    return IPriceOracle(_aaveAddrProv.getPriceOracle());
  }

  function _aaveDataProvider() internal view returns (AaveProtocolDataProvider) {
    return AaveProtocolDataProvider(_aaveAddrProv.getAddress(DATA_PROVIDER_ID));
  }

  function aToken() public view returns (IAToken) {
    return _aToken;
  }

  function rewardToken() public view returns (IERC20Metadata) {
    return _rewardToken;
  }

  function rewardAToken() public view returns (IAToken) {
    return _rewardAToken;
  }

  function _exchangePath() internal view returns (address[] memory) {
    address[] memory path = new address[](2);
    path[0] = address(rewardToken());
    path[1] = address(currency());
    return path;
  }

  function _rewardToCurrency(uint256 amount) internal view returns (uint256) {
    // TODO Check: this is safe? Or I should use IPriceOracle instead
    IPriceOracle oracle = priceOracle();
    IERC20Metadata from_ = rewardToken();
    IERC20Metadata to_ = currency();
    uint256 exchangeRate = oracle.getAssetPrice(address(from_)).wadDiv(
      oracle.getAssetPrice(address(to_))
    );
    if (from_.decimals() > to_.decimals()) {
      exchangeRate /= 10**(from_.decimals() - to_.decimals());
    } else {
      exchangeRate *= 10**(from_.decimals() - to_.decimals());
    }
    return amount.wadMul(exchangeRate);
  }

  function reinvestRewardToken() public {
    ILendingPool lendingPool_ = lendingPool();
    IERC20Metadata token = rewardToken();
    uint256 rewardBalance = token.balanceOf(address(this));
    if (rewardBalance <= _reinvestRewardsMin) return;
    token.approve(address(lendingPool_), rewardBalance);
    lendingPool_.deposit(address(token), rewardBalance, address(this), 0);
  }

  function _swapRewards(uint256 amount, address outAddr) internal returns (uint256, uint256) {
    address[] memory path = _exchangePath();
    uint256 swapIn = IERC20Metadata(path[0]).balanceOf(address(this));
    if (swapIn < amount) {
      uint256 toWithdraw = amount - swapIn;
      if (rewardAToken().balanceOf(address(this)) < toWithdraw) {
        toWithdraw = type(uint256).max; // if not enought withdraw all
      }
      swapIn += lendingPool().withdraw(path[0], toWithdraw, address(this));
    } else {
      swapIn = amount;
    }
    uint256 swapOutMin = _rewardToCurrency(swapIn).wadMul(1e18 - _maxSlippage);
    IERC20Metadata(path[0]).approve(address(_swapRouter), swapIn);
    uint256[] memory amounts = _swapRouter.swapExactTokensForTokens(
      swapIn,
      swapOutMin,
      path,
      outAddr,
      block.timestamp
    );
    emit RewardSwapped(swapIn, amounts[1]);
    return (swapIn, amounts[1]);
  }

  function swapRewards(uint256 amount)
    external
    onlyPoolRole(SWAP_REWARDS_ROLE)
    returns (uint256, uint256)
  {
    (uint256 swapIn, uint256 swapOut) = _swapRewards(amount, address(this));
    ILendingPool lendingPool_ = lendingPool();
    IERC20Metadata token = currency();
    token.approve(address(lendingPool_), swapOut);
    lendingPool_.deposit(address(token), swapOut, address(this), 0);
    return (swapIn, swapOut);
  }

  function rebalance() public virtual override whenNotPaused {
    _claimRewards(false);
    super.rebalance();
    reinvestRewardToken();
  }

  function _invest(uint256 amount) internal override {
    ILendingPool lendingPool_ = lendingPool();
    IERC20Metadata token = currency();
    token.safeTransferFrom(address(_policyPool), address(this), amount);
    token.approve(address(lendingPool_), amount);
    lendingPool_.deposit(address(token), amount, address(this), 0);
    super._invest(amount);
  }

  function _deinvest(uint256 amount) internal override {
    uint256 remainingAmount = amount;
    uint256 toWithdraw = amount;
    if (aToken().balanceOf(address(this)) < toWithdraw) {
      toWithdraw = type(uint256).max;
    }
    remainingAmount -= lendingPool().withdraw(
      address(currency()),
      toWithdraw,
      address(_policyPool) // Withdraw directly to _policyPool
    );
    if (remainingAmount > 0) {
      // In this case, it's safe using getAmountsIn to compute how many rewards are needed to swap
      // but then, when I do the swap I validate the slippage with the market price (given by AAVE's Oracle)
      // is acceptable
      uint256 requiredRewards = _swapRouter.getAmountsIn(remainingAmount, _exchangePath())[0];
      (, uint256 currencyOut) = _swapRewards(requiredRewards, address(_policyPool));
      if (currencyOut < remainingAmount) {
        remainingAmount -= currencyOut;
      } else {
        remainingAmount = 0;
      }
    }
    super._deinvest(amount - remainingAmount);
  }

  /**
   * @dev Deinvest all the assets and return the cash back to the PolicyPool.
   *      Called from PolicyPool when new asset manager is assigned
   */
  function _liquidateAll() internal virtual override {
    _claimRewards(true);
    lendingPool().withdraw(
      address(currency()),
      type(uint256).max,
      address(_policyPool) // Withdraw directly to _policyPool
    );
    // Withdraw all rewards
    lendingPool().withdraw(address(_rewardToken), type(uint256).max, address(this));
    _swapRewards(_rewardToken.balanceOf(address(this)), address(_policyPool));
  }

  // Contract parameters
  function claimRewardsMin() external view returns (uint256) {
    return _claimRewardsMin;
  }

  function reinvestRewardsMin() external view returns (uint256) {
    return _reinvestRewardsMin;
  }

  function maxSlippage() external view returns (uint256) {
    return _maxSlippage;
  }

  function setClaimRewardsMin(uint256 newValue) external onlyPoolRole2(LEVEL2_ROLE, LEVEL3_ROLE) {
    bool tweak = !hasPoolRole(LEVEL2_ROLE);
    require(
      !tweak || _isTweakWad(_claimRewardsMin, newValue, 3e26),
      "Tweak exceeded: claimRewardsMin tweaks only up to 30%"
    );
    _claimRewardsMin = newValue;
    _parameterChanged(IPolicyPoolConfig.GovernanceActions.setClaimRewardsMin, newValue, tweak);
  }

  function setReinvestRewardsMin(uint256 newValue)
    external
    onlyPoolRole2(LEVEL2_ROLE, LEVEL3_ROLE)
  {
    bool tweak = !hasPoolRole(LEVEL2_ROLE);
    require(
      !tweak || _isTweakWad(_reinvestRewardsMin, newValue, 3e26),
      "Tweak exceeded: reinvestRewardsMin tweaks only up to 30%"
    );
    _reinvestRewardsMin = newValue;
    _parameterChanged(IPolicyPoolConfig.GovernanceActions.setReinvestRewardsMin, newValue, tweak);
  }

  function setMaxSlippage(uint256 newValue) external onlyPoolRole2(LEVEL2_ROLE, LEVEL3_ROLE) {
    require(newValue <= 1e17, "maxSlippage can't be more than 10%");
    bool tweak = !hasPoolRole(LEVEL2_ROLE);
    require(
      !tweak || _isTweakWad(_maxSlippage, newValue, 3e26),
      "Tweak exceeded: maxSlippage tweaks only up to 30%"
    );
    _maxSlippage = newValue;
    _parameterChanged(IPolicyPoolConfig.GovernanceActions.setMaxSlippage, newValue, tweak);
  }
}
