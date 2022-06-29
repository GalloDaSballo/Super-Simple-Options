// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;


import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@oz/security/ReentrancyGuard.sol";
import {IPriceFeed} from "../interfaces/chainlink/IPriceFeed.sol";

contract SuperSimpleCallOption {
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

  // Active only once counterparty has funded
  bool active = false;

  address public taker;

  address public immutable maker;

  uint256 private constant SECONDS_PER_DAY = 86400;
  uint256 private constant SECONDS_PER_HOUR = 3600;

  constructor(uint256 amount, uint256 durationDays, uint256 price) {
    maker = msg.sender;
    setup(amount, durationDays, price);
  }


  function setup(uint256 amount, uint256 pricePerToken, uint256 durationDays) public {
    require(expirationDate == 0); // Flag value for non-started contract

    expirationDate = block.timestamp + durationDays * SECONDS_PER_DAY;
    exercisePrice = pricePerToken;
    tokensToSell = amount;

    BADGER.safeTransferFrom(msg.sender, address(this), amount);
  }

  function buy() external {
    require(taker == address(0));
    require(!active);

    taker = msg.sender;
    active = true;

    uint256 toSend = exercisePrice * tokensToSell;

    USDC.safeTransferFrom(msg.sender, address(this), toSend);
  }

  /// @dev Exercise the option, receive the underlying tokens
  function exercise() external {
    // Check
    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = BADGER_USDC_FEED.latestRoundData();
    require(block.timestamp <= expirationDate); // Must exercise before or at expiration
    require(block.timestamp - updatedAt < SECONDS_PER_HOUR); // Check for freshness of feed
    require(answer >= int256(exercisePrice)); // Check if condition is met

    //  Let's settle

    // Pay Maker
    USDC.safeTransfer(maker, USDC.balanceOf(address(this)));

    // Send Taker the tokens
    BADGER.safeTransfer(taker, BADGER.balanceOf(address(this)));

    // GG
  }

  function cancel() external {
    // Taker can cancel, by loosing the premium, as premium is sent to maker immediately
    address cachedTaker = taker;
    require(block.timestamp <= expirationDate || msg.sender == cachedTaker); // Taker can cancel early, else cancel exclusively after expiry

    expirationDate = 0;
    active = false;
    exercisePrice = 0;
    tokensToSell = 0;

    USDC.safeTransfer(cachedTaker, USDC.balanceOf(address(this))); // Send back the deposit

    BADGER.safeTransfer(maker, BADGER.balanceOf(address(this))); // Send back the underlying
  }

  /// @dev Cancel the option
  /// @notice Either if contract expired or if 
  function rescind() external {
    require(!active);

    uint256 toWithdraw = tokensToSell;

    expirationDate = 0;
    exercisePrice = 0;
    tokensToSell = 0;

    BADGER.safeTransfer(maker, toWithdraw);
  }
}