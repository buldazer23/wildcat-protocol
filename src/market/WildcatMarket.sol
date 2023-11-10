// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import '../libraries/FeeMath.sol';
import './WildcatMarketBase.sol';
import './WildcatMarketConfig.sol';
import './WildcatMarketToken.sol';
import './WildcatMarketWithdrawals.sol';
import '../WildcatSanctionsSentinel.sol';

contract WildcatMarket is
  WildcatMarketBase,
  WildcatMarketConfig,
  WildcatMarketToken,
  WildcatMarketWithdrawals
{
  using MathUtils for uint256;
  using SafeCastLib for uint256;
  using SafeTransferLib for address;

  /**
   * @dev Apply pending interest, delinquency fees and protocol fees
   *      to the state and process the pending withdrawal batch if
   *      one exists and has expired, then update the market's
   *      delinquency status.
   */
  function updateState() public nonReentrant {
    MarketState memory state = _getUpdatedState();
    _writeState(state);
  }

  /**
   * @dev Deposit up to `amount` underlying assets and mint market tokens
   *      for `msg.sender`.
   *
   *      The actual deposit amount is limited by the market's maximum deposit
   *      amount, which is the configured `maxTotalSupply` minus the current
   *      total supply.
   *
   *      Reverts if the market is closed or if the scaled token amount
   *      that would be minted for the deposit is zero.
   */
  function depositUpTo(
    uint256 amount
  ) public virtual nonReentrant returns (uint256 /* actualAmount */) {

    // Get current state
    MarketState memory state = _getUpdatedState();

    if (IWildcatSanctionsSentinel(sentinel).isSanctioned(borrower, msg.sender)) {
      _blockAccount(state, msg.sender);
      _writeState(state);
    }
    else {
      if (state.isClosed) {
        revert DepositToClosedMarket();
      }

      // Reduce amount if it would exceed totalSupply
      amount = MathUtils.min(amount, state.maximumDeposit());

      // Scale the mint amount
      uint104 scaledAmount = state.scaleAmount(amount).toUint104();
      if (scaledAmount == 0) revert NullMintAmount();

      // Transfer deposit from caller
      asset.safeTransferFrom(msg.sender, address(this), amount);

      // Cache account data and revert if not authorized to deposit.
      Account memory account = _getAccountWithRole(msg.sender, AuthRole.DepositAndWithdraw);
      account.scaledBalance += scaledAmount;
      _accounts[msg.sender] = account;

      emit Transfer(address(0), msg.sender, amount);
      emit Deposit(msg.sender, amount, scaledAmount);

      // Increase supply
      state.scaledTotalSupply += scaledAmount;

      // Update stored state
      _writeState(state);

      return amount;
    }
  }

  /**
   * @dev Deposit exactly `amount` underlying assets and mint market tokens
   *      for `msg.sender`.
   *
   *     Reverts if the deposit amount would cause the market to exceed the
   *     configured `maxTotalSupply`.
   */
  function deposit(uint256 amount) external virtual {
    uint256 actualAmount = depositUpTo(amount);
    if (amount != actualAmount) {
      revert MaxSupplyExceeded();
    }
  }

  /**
   * @dev Withdraw available protocol fees to the fee recipient.
   */
  function collectFees() external nonReentrant {
    MarketState memory state = _getUpdatedState();
    if (state.accruedProtocolFees == 0) {
      revert NullFeeAmount();
    }
    uint128 withdrawableFees = state.withdrawableProtocolFees(totalAssets());
    if (withdrawableFees == 0) {
      revert InsufficientReservesForFeeWithdrawal();
    }
    state.accruedProtocolFees -= withdrawableFees;
    asset.safeTransfer(feeRecipient, withdrawableFees);
    _writeState(state);
    emit FeesCollected(withdrawableFees);
  }

  /**
   * @dev Withdraw funds from the market to the borrower.
   *
   *      Can only withdraw up to the assets that are not required
   *      to meet the borrower's collateral obligations.
   *
   *      Reverts if the market is closed.
   */
  function borrow(uint256 amount) external onlyBorrower nonReentrant {

    if (WildcatSanctionsSentinel(sentinel).isFlaggedByChainalysis(borrower)) {
      revert BorrowWhileSanctioned();
    }

    MarketState memory state = _getUpdatedState();
    if (state.isClosed) {
      revert BorrowFromClosedMarket();
    }
    uint256 borrowable = state.borrowableAssets(totalAssets());
    if (amount > borrowable) {
      revert BorrowAmountTooHigh();
    }
    asset.safeTransfer(msg.sender, amount);
    _writeState(state);
    emit Borrow(amount);
  }

  /**
   * @dev Transfers funds from the caller to the market.
   *
   *      Any payments made through this function are considered
   *      repayments from the borrower. Do *not* use this function
   *      if you are a lender or an unrelated third party.
   *
   *      Reverts if the market is closed.
   */
  function repay(uint256 amount) external nonReentrant {
    MarketState memory state = _getUpdatedState();
    if (state.isClosed) {
      revert RepayToClosedMarket();
    }

    asset.safeTransferFrom(msg.sender, address(this), amount);
    updateState();
    
    emit MarketRepayment(msg.sender, amount, block.timestamp);
  }

  /**
   * @dev Sets the market APR to 0% and marks market as closed.
   *
   *      Can not be called if there are any unpaid withdrawal batches.
   *
   *      Transfers remaining debts from borrower if market is not fully
   *      collateralized; otherwise, transfers any assets in excess of
   *      debts to the borrower.
   */
  function closeMarket() external onlyController nonReentrant {
    if (_withdrawalData.unpaidBatches.length() > 0) {
      revert CloseMarketWithUnpaidWithdrawals();
    }

    MarketState memory state = _getUpdatedState();

    state.annualInterestBips = 0;
    state.isClosed = true;
    state.reserveRatioBips = 10000;
    // Ensures that delinquency fee doesn't increase scale factor further
    // as doing so would mean last lender in market couldn't fully redeem
    state.timeDelinquent = 0;

    uint256 currentlyHeld = totalAssets();
    uint256 totalDebts = state.totalDebts();
    if (currentlyHeld < totalDebts) {
      // Transfer remaining debts from borrower
      asset.safeTransferFrom(borrower, address(this), totalDebts - currentlyHeld);
    } else if (currentlyHeld > totalDebts) {
      // Transfer excess assets to borrower
      asset.safeTransfer(borrower, currentlyHeld - totalDebts);
    }
    _writeState(state);
    emit MarketClosed(block.timestamp);
  }
}
