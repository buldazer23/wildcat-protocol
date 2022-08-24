// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import { DefaultVaultState, VaultState, VaultStateCoder } from './types/VaultStateCoder.sol';
import './libraries/Math.sol';

abstract contract ScaledBalanceToken {
	using VaultStateCoder for VaultState;
	using Math for uint256;
	using Math for int256;

	error MaxSupplyExceeded();

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	VaultState internal _state;

	/*//////////////////////////////////////////////////////////////
                            ERC20 Storage
  //////////////////////////////////////////////////////////////*/

	mapping(address => uint256) public scaledBalanceOf;

	mapping(address => mapping(address => uint256)) public allowance;

	constructor(int256 _annualInterestBips) {
		_state = DefaultVaultState.setInitialState(
			_annualInterestBips,
			RayOne,
			block.timestamp
		);
	}

	/*//////////////////////////////////////////////////////////////
                          External Getters
  //////////////////////////////////////////////////////////////*/

	/**
	 * @notice Returns the normalized balance of `account` with interest.
	 */
	function balanceOf(address account) public view returns (uint256) {
		(uint256 scaleFactor, ) = _getCurrentScaleFactor(_state);
		return scaledBalanceOf[account].rayMul(scaleFactor);
	}

	/**
	 * @notice Returns the normalized total supply with interest.
	 */
	function totalSupply() public view returns (uint256) {
		VaultState state = _state;
		(uint256 scaleFactor, ) = _getCurrentScaleFactor(state);
		return state.getScaledTotalSupply().rayMul(scaleFactor);
	}

	function getState()
		public
		view
		returns (
			int256 annualInterestBips,
			uint256 scaledTotalSupply,
			uint256 scaleFactor,
			uint256 lastInterestAccruedTimestamp
		)
	{
		return _state.decode();
	}

	function maxTotalSupply() public view virtual returns (uint256);

	/*//////////////////////////////////////////////////////////////
                       Internal State Handlers
  //////////////////////////////////////////////////////////////*/

	function _getUpdatedScaleFactor() internal returns (uint256) {
		VaultState state = _state;
		(uint256 scaleFactor, bool changed) = _getCurrentScaleFactor(state);
		if (changed) {
			_state = state.setNewScaleOutputs(scaleFactor, block.timestamp);
		}
		return scaleFactor;
	}

	function _getCurrentState() internal view returns (VaultState state) {
		state = _state;
		(uint256 scaleFactor, bool changed) = _getCurrentScaleFactor(state);
		if (changed) {
			state = state.setNewScaleOutputs(scaleFactor, block.timestamp);
		}
	}

	/**
	 * @dev Returns scale factor at current time, with interest applied since the
	 * previous accrual but without updating the state.
	 */
	function _getCurrentScaleFactor(VaultState state)
		internal
		view
		returns (
			uint256, /* newScaleFactor */
			bool /* changed */
		)
	{
		(
			int256 annualInterestBips,
			uint256 scaleFactor,
			uint256 lastInterestAccruedTimestamp
		) = state.getNewScaleInputs();
		uint256 timeElapsed;
		unchecked {
			timeElapsed = block.timestamp - lastInterestAccruedTimestamp;
		}
		bool changed = timeElapsed > 0;
		if (changed) {
			int256 newInterest;
			int256 interestPerSecond = annualInterestBips.annualBipsToRayPerSecond();
			assembly {
				// Calculate interest accrued since last update
				newInterest := mul(timeElapsed, interestPerSecond)
			}
			// Calculate change to scale factor
			int256 scaleFactorChange = scaleFactor.rayMul(newInterest);
			assembly {
				scaleFactor := add(scaleFactor, scaleFactorChange)
				// Total scaleFactor must not underflow
				if slt(scaleFactor, 0) {
					mstore(0, Panic_error_signature)
					mstore(Panic_error_offset, Panic_arithmetic)
					revert(0, Panic_error_length)
				}
			}
		}
		return (scaleFactor, changed);
	}

	function _getMaximumDeposit(VaultState state, uint256 scaleFactor)
		internal
		view
		returns (uint256)
	{
		uint256 _totalSupply = state.getScaledTotalSupply().rayMul(scaleFactor);
		uint256 _maxTotalSupply = maxTotalSupply();
		return _maxTotalSupply.subMinZero(_totalSupply);
	}

	/*//////////////////////////////////////////////////////////////
                             ERC20 LOGIC
  //////////////////////////////////////////////////////////////*/

	function approve(address spender, uint256 amount) external returns (bool) {
		allowance[msg.sender][spender] = amount;

		emit Approval(msg.sender, spender, amount);

		return true;
	}

	function transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) external returns (bool) {
		uint256 allowed = allowance[sender][msg.sender];

		// Saves gas for unlimited approvals.
		if (allowed != type(uint256).max) {
			uint256 newAllowance = allowed - amount;
			allowance[sender][msg.sender] = newAllowance;
			emit Approval(sender, msg.sender, newAllowance);
		}

		_transfer(sender, recipient, amount);

		return true;
	}

	function transfer(address recipient, uint256 amount) external returns (bool) {
		_transfer(msg.sender, recipient, amount);
		return true;
	}

	/*//////////////////////////////////////////////////////////////
                     Internal Actions & Getters
  //////////////////////////////////////////////////////////////*/

	function _transfer(
		address from,
		address to,
		uint256 amount
	) internal virtual {
		uint256 scaleFactor = _getUpdatedScaleFactor();
		uint256 scaledAmount = amount.rayDiv(scaleFactor);
		scaledBalanceOf[from] -= scaledAmount;
		unchecked {
			scaledBalanceOf[to] += scaledAmount;
		}
		emit Transfer(from, to, amount);
	}

	function _mintUpTo(address to, uint256 amount)
		internal
		returns (uint256 actualAmount)
	{
		VaultState state = _getCurrentState();
		uint256 scaleFactor = state.getScaleFactor();
		actualAmount = Math.min(amount, _getMaximumDeposit(state, scaleFactor));
		uint256 scaledAmount = actualAmount.rayDiv(scaleFactor);
		_handleDeposit(to, amount, scaledAmount);
		scaledBalanceOf[to] += scaledAmount;
		unchecked {
			// If user's balance did not overflow uint256, neither will totalSupply
			// Coder checks for overflow of uint96
			state = state.setScaledTotalSupply(
				state.getScaledTotalSupply() + scaledAmount
			);
		}
		_state = state;
		emit Transfer(address(0), to, actualAmount);
	}

	function _mint(address to, uint256 amount) internal virtual {
		if (_mintUpTo(to, amount) != amount) {
			revert MaxSupplyExceeded();
		}
	}

	function _burn(address account, uint256 amount) internal virtual {
		VaultState state = _getCurrentState();
		uint256 scaleFactor = state.getScaleFactor();
		uint256 scaledAmount = amount.rayDiv(scaleFactor);

		scaledBalanceOf[account] -= scaledAmount;
		unchecked {
			// If user's balance did not underflow uint256, neither will totalSupply
			state = state.setScaledTotalSupply(
				state.getScaledTotalSupply() - scaledAmount
			);
		}
		_state = state;
		emit Transfer(account, address(0), amount);
	}

	function _handleDeposit(
		address to,
		uint256 amount,
		uint256 scaledAmount
	) internal virtual {}
}
