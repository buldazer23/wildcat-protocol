// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import { MockERC20 } from 'solmate/test/utils/mocks/MockERC20.sol';

import './shared/Test.sol';

import 'src/WildcatVaultController.sol';
import 'src/WildcatVaultFactory.sol';
import './helpers/Assertions.sol';
import './helpers/VmUtils.sol';
import './helpers/MockController.sol';
import './shared/TestConstants.sol';

contract ExpectedStateTracker is Assertions, IVaultEventsAndErrors {
	using FeeMath for VaultState;
	using SafeCastLib for uint256;
	using MathUtils for uint256;

	VaultParameters internal parameters;
	WildcatMarket internal vault;
	VaultState internal previousState;
	WithdrawalData internal _withdrawalData;
	uint256 internal lastTotalAssets;
	address[] internal accountsAffected;
	mapping(address => Account) internal accounts;

	function pendingState() internal returns (VaultState memory state) {
		state = previousState;
		if (block.timestamp >= state.pendingWithdrawalExpiry && state.pendingWithdrawalExpiry != 0) {
			uint256 expiry = state.pendingWithdrawalExpiry;
			state.updateScaleFactorAndFees(
				parameters.protocolFeeBips,
				parameters.delinquencyFeeBips,
				parameters.delinquencyGracePeriod,
				expiry
			);
			_processExpiredWithdrawalBatch(state);
		}
		state.updateScaleFactorAndFees(
			parameters.protocolFeeBips,
			parameters.delinquencyFeeBips,
			parameters.delinquencyGracePeriod,
			block.timestamp
		);
	}

	function updateState(VaultState memory state) internal {
		state.isDelinquent = state.liquidityRequired() > lastTotalAssets;
		previousState = state;
	}

	function _checkState() internal {
		VaultState memory state = vault.currentState();
		assertEq(previousState, state, 'state');

		// assertEq(lastProtocolFees, vault.lastAccruedProtocolFees(), 'protocol fees');
	}

	/**
	 * @dev When a withdrawal batch expires, the vault will checkpoint the scale factor
	 *      as of the time of expiry and retrieve the current liquid assets in the vault
	 * (assets which are not already owed to protocol fees or prior withdrawal batches).
	 */
	function _processExpiredWithdrawalBatch(VaultState memory state) internal {
		WithdrawalBatch storage batch = _withdrawalData.batches[state.pendingWithdrawalExpiry];

		// Get the liquidity which is not already reserved for prior withdrawal batches
		// or owed to protocol fees.
		uint256 availableLiquidity = _availableLiquidityForPendingBatch(batch, state);
		if (availableLiquidity > 0) {
			_applyWithdrawalBatchPayment(batch, state, state.pendingWithdrawalExpiry, availableLiquidity);
		}
		// vm.expectEmit(address(vault));
		emit WithdrawalBatchExpired(
			state.pendingWithdrawalExpiry,
			batch.scaledTotalAmount,
			batch.scaledAmountBurned,
			batch.normalizedAmountPaid
		);

		if (batch.scaledAmountBurned < batch.scaledTotalAmount) {
			_withdrawalData.unpaidBatches.push(state.pendingWithdrawalExpiry);
		} else {
			// vm.expectEmit(address(vault));
			emit WithdrawalBatchClosed(state.pendingWithdrawalExpiry);
		}

		state.pendingWithdrawalExpiry = 0;
	}

	function _availableLiquidityForPendingBatch(
		WithdrawalBatch storage batch,
		VaultState memory state
	) internal view returns (uint256) {
		uint104 scaledAmountOwed = batch.scaledTotalAmount - batch.scaledAmountBurned;
		uint256 unavailableAssets = state.reservedAssets +
			state.accruedProtocolFees +
			state.normalizeAmount(state.scaledPendingWithdrawals - scaledAmountOwed);

		return lastTotalAssets.satSub(unavailableAssets);
	}

	/**
	 * @dev Process withdrawal payment, burning vault tokens and reserving
	 *      underlying assets so they are only available for withdrawals.
	 */
	function _applyWithdrawalBatchPayment(
		WithdrawalBatch storage batch,
		VaultState memory state,
		uint32 expiry,
		uint256 availableLiquidity
	) internal {
		uint104 scaledAvailableLiquidity = state.scaleAmount(availableLiquidity).toUint104();
		uint104 scaledAmountOwed = batch.scaledTotalAmount - batch.scaledAmountBurned;
		if (scaledAmountOwed == 0) {
			return;
		}
		uint104 scaledAmountBurned = uint104(MathUtils.min(scaledAvailableLiquidity, scaledAmountOwed));
		uint128 normalizedAmountPaid = state.normalizeAmount(scaledAmountBurned).toUint128();

		batch.scaledAmountBurned += scaledAmountBurned;
		batch.normalizedAmountPaid += normalizedAmountPaid;
		state.scaledPendingWithdrawals -= scaledAmountBurned;

		// Update reservedAssets so the tokens are only accessible for withdrawals.
		state.reservedAssets += normalizedAmountPaid;

		// Burn vault tokens to stop interest accrual upon withdrawal payment.
		state.scaledTotalSupply -= scaledAmountBurned;

		// Emit transfer for external trackers to indicate burn.
		// vm.expectEmit(address(vault));
		emit Transfer(address(this), address(0), normalizedAmountPaid);
		// vm.expectEmit(address(vault));
		emit WithdrawalBatchPayment(expiry, scaledAmountBurned, normalizedAmountPaid);
	}
}

contract BaseVaultTest is Test, ExpectedStateTracker {
	using stdStorage for StdStorage;
	using FeeMath for VaultState;
	using SafeCastLib for uint256;

	WildcatVaultFactory internal factory;
	WildcatVaultController internal controller;
	MockERC20 internal asset;

	address internal wildcatController = address(0x69);
	address internal wintermuteController = address(0x70);
	address internal wlUser = address(0x42);
	address internal nonwlUser = address(0x43);

	address internal _pranking;

	function setUp() public {
		factory = new WildcatVaultFactory();
		controller = new MockController(feeRecipient, address(factory));
		controller.authorizeLender(alice);
		asset = new MockERC20('Token', 'TKN', 18);
		parameters = VaultParameters({
			asset: address(asset),
			namePrefix: 'Wildcat ',
			symbolPrefix: 'WC',
			borrower: borrower,
			controller: address(controller),
			feeRecipient: feeRecipient,
			sentinel: sentinel,
			maxTotalSupply: uint128(DefaultMaximumSupply),
			protocolFeeBips: DefaultProtocolFeeBips,
			annualInterestBips: DefaultInterest,
			delinquencyFeeBips: DefaultDelinquencyFee,
			withdrawalBatchDuration: DefaultWithdrawalBatchDuration,
			liquidityCoverageRatio: DefaultLiquidityCoverage,
			delinquencyGracePeriod: DefaultGracePeriod
		});
		setupVault();
	}

	function _deposit(address from, uint256 amount) internal asAccount(from) returns (uint256) {
		if (_pranking != address(0)) {
			vm.stopPrank();
		}
		controller.authorizeLender(from);
		if (_pranking != address(0)) {
			vm.startPrank(_pranking);
		}
		uint256 currentBalance = vault.balanceOf(from);
		uint256 currentScaledBalance = vault.scaledBalanceOf(from);
		asset.mint(from, amount);
		asset.approve(address(vault), amount);
		VaultState memory state = pendingState();
		uint256 expectedNormalizedAmount = MathUtils.min(amount, state.maximumDeposit());
		uint256 scaledAmount = state.scaleAmount(expectedNormalizedAmount);
		state.scaledTotalSupply += scaledAmount.toUint104();
		uint256 actualNormalizedAmount = vault.depositUpTo(amount);
		assertEq(actualNormalizedAmount, expectedNormalizedAmount, 'Actual amount deposited');
		lastTotalAssets += actualNormalizedAmount;
		updateState(state);
		_checkState();
		assertApproxEqAbs(vault.balanceOf(from), currentBalance + amount, 1);
		assertEq(vault.scaledBalanceOf(from), currentScaledBalance + scaledAmount);
		return actualNormalizedAmount;
	}

	function _requestWithdrawal(address from, uint256 amount) internal asAccount(from) {
		VaultState memory state = pendingState();
		uint256 currentBalance = vault.balanceOf(from);
		uint256 currentScaledBalance = vault.scaledBalanceOf(from);
		uint104 scaledAmount = state.scaleAmount(amount).toUint104();

		if (state.pendingWithdrawalExpiry == 0) {
			// vm.expectEmit(address(vault));
			state.pendingWithdrawalExpiry = uint32(block.timestamp + parameters.withdrawalBatchDuration);
			emit WithdrawalBatchCreated(state.pendingWithdrawalExpiry);
		}
		WithdrawalBatch storage batch = _withdrawalData.batches[state.pendingWithdrawalExpiry];
		batch.scaledTotalAmount += scaledAmount;
		state.scaledPendingWithdrawals += scaledAmount;
		_withdrawalData
		.accountStatuses[state.pendingWithdrawalExpiry][from].scaledAmount += scaledAmount;

		// vm.expectEmit(address(vault));
		emit WithdrawalQueued(state.pendingWithdrawalExpiry, from, scaledAmount);

		uint256 availableLiquidity = _availableLiquidityForPendingBatch(batch, state);
		if (availableLiquidity > 0) {
			_applyWithdrawalBatchPayment(batch, state, state.pendingWithdrawalExpiry, availableLiquidity);
		}
		vault.queueWithdrawal(amount);
		updateState(state);
		_checkState();
		assertApproxEqAbs(vault.balanceOf(from), currentBalance - amount, 1, 'balance');
		assertEq(vault.scaledBalanceOf(from), currentScaledBalance - scaledAmount, 'scaledBalance');
	}

	function _withdraw(address from, uint256 amount) internal asAccount(from) {
		// VaultState memory state = pendingState();
		// uint256 scaledAmount = state.scaleAmount(amount);
		// @todo fix
		/* 		VaultState memory state = pendingState();
    uint256 scaledAmount = state.scaleAmount(amount);
    state.decreaseScaledTotalSupply(scaledAmount);
    vault.withdraw(amount);
    updateState(state);
    lastTotalAssets -= amount;
    _checkState(); */
	}

	event DebtRepaid(uint256 assetAmount);

	function _borrow(uint256 amount) internal asAccount(borrower) {
		VaultState memory state = pendingState();

		// vm.expectEmit(address(vault));
		emit Borrow(amount);
		// _expectTransfer(address(asset), borrower, address(vault), amount);
		vault.borrow(amount);

		lastTotalAssets -= amount;
		updateState(state);
		_checkState();
	}

	modifier asAccount(address account) {
		address previousPrank = _pranking;
		if (account != previousPrank) {
			if (previousPrank != address(0)) vm.stopPrank();
			vm.startPrank(account);
			_pranking = account;
			_;
			vm.stopPrank();
			if (previousPrank != address(0)) vm.startPrank(previousPrank);
			_pranking = previousPrank;
		} else {
			_;
		}
	}

	function _approve(address from, address to, uint256 amount) internal asAccount(from) {
		asset.approve(to, amount);
	}

	function _deployVault() internal {
		vault = WildcatMarket(factory.deployVault(parameters));
	}

	function setupVault() internal {
		_deployVault();
		previousState = VaultState({
			maxTotalSupply: parameters.maxTotalSupply,
			scaledTotalSupply: 0,
			isDelinquent: false,
			timeDelinquent: 0,
			liquidityCoverageRatio: parameters.liquidityCoverageRatio,
			annualInterestBips: parameters.annualInterestBips,
			scaleFactor: uint112(RAY),
			lastInterestAccruedTimestamp: uint32(block.timestamp),
			scaledPendingWithdrawals: 0,
			pendingWithdrawalExpiry: 0,
			reservedAssets: 0,
			accruedProtocolFees: 0
		});
		lastTotalAssets = 0;

		asset.mint(alice, type(uint128).max);
		asset.mint(bob, type(uint128).max);

		_approve(alice, address(vault), type(uint256).max);
		_approve(bob, address(vault), type(uint256).max);
	}
}
