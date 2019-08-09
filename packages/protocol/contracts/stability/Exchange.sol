pragma solidity ^0.5.8;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./interfaces/IExchange.sol";
import "./interfaces/ISortedOracles.sol";
import "./interfaces/IReserve.sol";
import "./interfaces/IStableToken.sol";
import "../common/FractionUtil.sol";
import "../common/Initializable.sol";
import "../common/UsingFixidity.sol";
import "../common/UsingRegistry.sol";
import "../common/interfaces/IERC20Token.sol";


/**
 * @title Contract that allows to exchange StableToken for GoldToken and vice versa
 * using a Constant Product Market Maker Model
 */
contract Exchange is IExchange, Initializable, Ownable, UsingRegistry, UsingFixidity {
  using SafeMath for uint256;
  using FractionUtil for FractionUtil.Fraction;

  event Exchanged(
    address indexed exchanger,
    uint256 sellAmount,
    uint256 buyAmount,
    bool soldGold
  );

  event UpdateFrequencySet(
    uint256 updateFrequency
  );

  event MinimumReportsSet(
    uint256 minimumReports
  );

  int256 public spread;
  // Fraction of the Reserve that is committed to the gold bucket when updating
  // buckets.
  int256 public reserveFraction;

  address public stable;

  // Size of the Uniswap gold bucket
  uint256 public goldBucket;
  // Size of the Uniswap stable token bucket
  uint256 public stableBucket;

  uint256 public lastBucketUpdate = 0;
  uint256 public updateFrequency;
  uint256 public minimumReports;

  modifier updateBucketsIfNecessary() {
    _updateBucketsIfNecessary();
    _;
  }

  // TODO: Remove this one with https://github.com/celo-org/celo-monorepo/issues/2000
  // solhint-disable-next-line
  function() external payable {}

  /**
   * @dev Initializes the exchange, setting initial bucket sizes
   * @param registryAddress Address of the Registry contract
   * @param stableToken Address of the stable token
   * @param _spread Spread charged on exchanges
   * @param _reserveFraction Fraction to commit
   * to the gold bucket
   * @param _updateFrequency The time period that needs to elapse between bucket
   * updates
   * @param _minimumReports The minimum number of fresh reports that need to be
   * present in the oracle to update buckets
   * commit to the gold bucket
   */
  function initialize(
    address registryAddress,
    address stableToken,
    int256 _spread,
    int256 _reserveFraction,
    uint256 _updateFrequency,
    uint256 _minimumReports
  )
    external
    initializer
  {
    _transferOwnership(msg.sender);
    setRegistry(registryAddress);
    stable = stableToken;
    spread = _spread;
    reserveFraction = _reserveFraction;
    updateFrequency = _updateFrequency;
    minimumReports = _minimumReports;
    _updateBucketsIfNecessary();
  }

  /**
   * @dev Exchanges sellAmount of sellToken in exchange for at least minBuyAmount of buyToken
   * Requires the sellAmount to have been approved to the exchange
   * @param sellAmount The amount of sellToken the user is selling to the exchange
   * @param minBuyAmount The minimum amount of buyToken the user has to receive for this
   * transaction to succeed
   * @param sellGold `true` if gold is the sell token
   * @return The amount of buyToken that was transfered
   */
  function exchange(
    uint256 sellAmount,
    uint256 minBuyAmount,
    bool sellGold
  )
    external
    updateBucketsIfNecessary
    returns (uint256)
  {
    uint256 buyAmount = _getBuyTokenAmount(sellAmount, sellGold);

    require(buyAmount >= minBuyAmount, "Calculated buyAmount was less than specified minBuyAmount");

    IReserve reserve = IReserve(registry.getAddressForOrDie(RESERVE_REGISTRY_ID));

    if (sellGold) {
      goldBucket = goldBucket.add(sellAmount);
      stableBucket = stableBucket.sub(buyAmount);
      require(
        gold().transferFrom(msg.sender, address(reserve), sellAmount),
        "Transfer of sell token failed"
      );
      require(IStableToken(stable).mint(msg.sender, buyAmount), "Mint of stable token failed");
    } else {
      stableBucket = stableBucket.add(sellAmount);
      goldBucket = goldBucket.sub(buyAmount);
      require(
        IERC20Token(stable).transferFrom(msg.sender, address(this), sellAmount),
        "Transfer of sell token failed"
      );
      IStableToken(stable).burn(sellAmount);

      require(reserve.transferGold(msg.sender, buyAmount), "Transfer of buyToken failed");
    }

    emit Exchanged(msg.sender, sellAmount, buyAmount, sellGold);
    return buyAmount;
  }

  /**
   * @dev Returns the amount of buyToken a user would get for sellAmount of sellToken
   * @param sellAmount The amount of sellToken the user is selling to the exchange
   * @param sellGold `true` if gold is the sell token
   * @return The corresponding buyToken amount.
   */
  function getBuyTokenAmount(
    uint256 sellAmount,
    bool sellGold
  )
    external
    view
    returns (uint256)
  {
    uint256 sellTokenBucket;
    uint256 buyTokenBucket;
    (buyTokenBucket, sellTokenBucket) = getBuyAndSellBuckets(sellGold);

    int256 reducedSellAmount = getReducedSellAmount(sellAmount);
    int256 numerator = reducedSellAmount.multiply(toFixed(buyTokenBucket));
    int256 denominator = toFixed(sellTokenBucket).add(reducedSellAmount);

    return uint256(numerator.divide(denominator).fromFixed());
  }

  /**
   * @dev Returns the amount of sellToken a user would need to exchange to receive buyAmount of
   * buyToken.
   * @param buyAmount The amount of buyToken the user would like to purchase.
   * @param sellGold `true` if gold is the sell token
   * @return The corresponding sellToken amount.
   */
  function getSellTokenAmount(
    uint256 buyAmount,
    bool sellGold
  )
    external
    view
    returns (uint256)
  {
    uint256 sellTokenBucket;
    uint256 buyTokenBucket;
    (buyTokenBucket, sellTokenBucket) = getBuyAndSellBuckets(sellGold);

    int256 numerator = toFixed(buyAmount.mul(sellTokenBucket));
    int256 denominator = toFixed(buyTokenBucket.sub(buyAmount))
      .multiply(FIXED1.subtract(spread));

    return uint256(numerator.divide(denominator).fromFixed());
  }

  /**
   * @notice Returns the buy token and sell token bucket sizes, in order. The ratio of
   * the two also represents the exchange rate between the two.
   * @param sellGold `true` if gold is the sell token
   * @return (buyTokenBucket, sellTokenBucket)
   */
  function getBuyAndSellBuckets(bool sellGold) public view returns (uint256, uint256) {
    uint256 currentGoldBucket = goldBucket;
    uint256 currentStableBucket = stableBucket;

    if (shouldUpdateBuckets()) {
      (currentGoldBucket, currentStableBucket) = getUpdatedBuckets();
    }

    if (sellGold) {
      return (currentStableBucket, currentGoldBucket);
    } else {
      return (currentGoldBucket, currentStableBucket);
    }
  }

  /**
    * @notice Allows owner to set the update frequency
    * @param newUpdateFrequency The new update frequency
    */
  function setUpdateFrequency(uint256 newUpdateFrequency) public onlyOwner {
    updateFrequency = newUpdateFrequency;
    emit UpdateFrequencySet(newUpdateFrequency);
  }

  /**
    * @notice Allows owner to set the minimum number of reports required
    * @param newMininumReports The new update minimum number of reports required
    */
  function setMinimumReports(uint256 newMininumReports) public onlyOwner {
    minimumReports = newMininumReports;
    emit MinimumReportsSet(newMininumReports);
  }

  /**
   * @notice Returns the sell token and buy token bucket sizes, in order. The ratio of
   * the two also represents the exchange rate between the two.
   * @param sellGold `true` if gold is the sell token
   * @return (sellTokenBucket, buyTokenBucket)
   */
  function _getBuyAndSellBuckets(bool sellGold) private view returns (uint256, uint256) {
    if (sellGold) {
      return (stableBucket, goldBucket);
    } else {
      return (goldBucket, stableBucket);
    }
  }

  /**
   * @dev Returns the amount of buyToken a user would get for sellAmount of sellToken
   * @param sellAmount The amount of sellToken the user is selling to the exchange
   * @param sellGold `true` if gold is the sell token
   * @return The corresponding buyToken amount.
   */
  function _getBuyTokenAmount(
    uint256 sellAmount,
    bool sellGold
  )
    private
    view
    returns (uint256)
  {
    uint256 sellTokenBucket;
    uint256 buyTokenBucket;
    (buyTokenBucket, sellTokenBucket) = _getBuyAndSellBuckets(sellGold);

    int256 reducedSellAmount = getReducedSellAmount(sellAmount);
    int256 numerator = reducedSellAmount.multiply(toFixed(buyTokenBucket));
    int256 denominator = toFixed(sellTokenBucket).add(reducedSellAmount);

    return uint256(numerator.divide(denominator).fromFixed());
  }

  function getUpdatedBuckets() private view returns (uint256, uint256) {
    uint256 updatedGoldBucket = getUpdatedGoldBucket();
    uint256 updatedStableBucket = getOracleExchangeRate().mul(updatedGoldBucket);

    return (updatedGoldBucket, updatedStableBucket);
  }

  function getUpdatedGoldBucket() private view returns (uint256) {
    uint256 reserveGoldBalance = gold().balanceOf(registry.getAddressForOrDie(RESERVE_REGISTRY_ID));
    return uint256(reserveFraction.multiply(toFixed(reserveGoldBalance)).fromFixed());
  }

  /**
   * @notice If conditions are met, updates the Uniswap bucket sizes to track
   * the price reported by the Oracle.
   */
  function _updateBucketsIfNecessary() private {
    if (shouldUpdateBuckets()) {
      // solhint-disable-next-line not-rely-on-time
      lastBucketUpdate = now;

      (goldBucket, stableBucket) = getUpdatedBuckets();
    }
  }

  /**
   * @dev Calculates the sell amount reduced by the spread.
   * @param sellAmount The original sell amount.
   * @return The reduced sell amount, computed as (1 - spread) * sellAmount
   */
  function getReducedSellAmount(uint256 sellAmount) private view returns (int256) {
    return FIXED1
      .subtract(spread)
      .multiply(toFixed(sellAmount));
  }

  /*
   * Checks conditions required for bucket updates.
   * @return Whether or not buckets should be updated.
   * TODO: check the oldest report isn't expired
   */
  function shouldUpdateBuckets() private view returns (bool) {
    ISortedOracles sortedOracles =
      ISortedOracles(registry.getAddressForOrDie(SORTED_ORACLES_REGISTRY_ID));
    // solhint-disable-next-line not-rely-on-time
    bool timePassed = now >= lastBucketUpdate.add(updateFrequency);
    bool enoughReports = sortedOracles.numRates(stable) >= minimumReports;
    bool medianReportRecent =
    // solhint-disable-next-line not-rely-on-time
      sortedOracles.medianTimestamp(stable) > now.sub(updateFrequency);
    return timePassed && enoughReports && medianReportRecent;
  }

  function getOracleExchangeRate() private view returns (FractionUtil.Fraction memory) {
    uint128 rateNumerator;
    uint128 rateDenominator;
    (rateNumerator, rateDenominator) =
      ISortedOracles(registry.getAddressForOrDie(SORTED_ORACLES_REGISTRY_ID)).medianRate(stable);
    return FractionUtil.Fraction(rateNumerator, rateDenominator);
  }

  function gold() private view returns (IERC20Token) {
    return IERC20Token(registry.getAddressForOrDie(GOLD_TOKEN_REGISTRY_ID));
  }
}
