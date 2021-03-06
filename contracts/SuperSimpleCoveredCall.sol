// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;


import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@oz/security/ReentrancyGuard.sol";
import {IPriceFeed} from "../interfaces/chainlink/IPriceFeed.sol";

/// @dev Super Simple Covered Call, forces both party to put 100% of collateral upfront
/// @notice Allows taker to rescind early to unlock collateral
/// @notice Also can be reused, unless I messed something up
contract SuperSimpleCoveredCall {
  using SafeERC20 for IERC20;

  // Token in
  IERC20 public constant BADGER = IERC20(0x3472A5A71965499acd81997a54BBA8D852C6E53d);

  // Premium Token
  IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

  // Price feed for settlement
  IPriceFeed public constant BADGER_USDC_FEED = IPriceFeed(0x66a47b7206130e6FF64854EF0E1EDfa237E65339);

  // Can only exercise until then
  uint256 public expirationDate;

  // How many tokens we're selling (avoid seller being able to sell after contract has started)
  uint256 public tokensToSell;

  // Price at which you can exercuse the option
  uint256 public exercisePrice;

  uint256 public premium;

  address public taker;

  address public immutable maker;

  uint256 private constant SECONDS_PER_DAY = 86400;
  uint256 private constant SECONDS_PER_HOUR = 3600;

  constructor(uint256 amount, uint256 price, uint256 durationDays, uint256 outTokenPremium) {
    maker = msg.sender;
    setup(amount, durationDays, price, outTokenPremium);
  }


  /// @dev Setup the parameters, fund with the token
  function setup(uint256 amount, uint256 pricePerToken, uint256 durationDays, uint256 outTokenPremium) public {
    require(expirationDate == 0); // Flag value for non-started contract

    expirationDate = block.timestamp + durationDays * SECONDS_PER_DAY;
    exercisePrice = pricePerToken;
    tokensToSell = amount;
    premium = outTokenPremium;

    BADGER.safeTransferFrom(msg.sender, address(this), amount);
  }

  /// @dev Buy the Call, send the premium to maker and lock in your collateral
  function buy() external {
    require(taker == address(0));

    taker = msg.sender;
    active = true;

    USDC.safeTransferFrom(msg.sender, maker, premium);
  }

  /// @dev Exercise the option, receive the underlying tokens
  function exercise() external {
    // Cache addresses for later
    address cachedTaker = taker;
    address cachedMaker = maker;
    
    require(block.timestamp <= expirationDate); // Must exercise before or at expiration
    require(msg.sender == cachedTaker); // Taker has the privilege of exercising, no-one else

    uint256 cachedExercisePrice = exercisePrice;

    // Check Price
    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = BADGER_USDC_FEED.latestRoundData();
    require(block.timestamp - updatedAt < SECONDS_PER_HOUR); // Check for freshness of feed
    require(answer >= int256(cachedExercisePrice)); // Check if condition is met

    uint256 settlementPrice = cachedExercisePrice * tokensToSell;

    //  Let's settle

    // Reset everything for next time
    _reset();

    // Pay Maker via the agree strike price
    USDC.safeTransferFrom(cachedTaker, cachedMaker, settlementPrice);

    // Send Taker the tokens they bought
    BADGER.safeTransfer(cachedTaker, BADGER.balanceOf(address(this)));
  }

  /// @dev Cancel the option
  /// @notice Either if contract expired or if the taker doesn't want it anymore
  function cancel() external {
    // Taker can cancel, by loosing the premium, as premium is sent to maker immediately
    require(block.timestamp > expirationDate || msg.sender == taker); // Taker can cancel early, else cancel exclusively after expiry

    _reset();

    BADGER.safeTransfer(maker, tokensToSell); // Send back the underlying
  }

  /// @dev Break the contract early, if you change your mind
  /// @notice Resets, you can always setup a new one next time
  function rescind() external {
    address cachedMaker = maker; 
    require(msg.sender == cachedMaker);  // Only maker can undo the setup else griefable
    require(taker == address(0)); // Taker not set == not active

    _reset();

    BADGER.safeTransfer(cachedMaker, tokensToSell);
  }

  /// @dev Convenience function to reset storage to neutral
  function _reset() internal {
    // No difference with delete
    premium = 0;
    expirationDate = 0;
    active = false; // Costs an extra 100 gas but w/e
    exercisePrice = 0;
    tokensToSell = 0;
    taker = address(0);
  }
}