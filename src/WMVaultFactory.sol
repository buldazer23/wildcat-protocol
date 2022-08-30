// SPDX-License-Identifier: NONE
pragma solidity ^0.8.13;

import './interfaces/IWMPermissions.sol';
import './interfaces/IWMRegistry.sol';
import './interfaces/IWMVault.sol';

import './WMVault.sol';
import './WMRegistry.sol';

contract WMVaultFactory {
	error NotWintermute();

	address internal wmPermissionAddress;

	IWMRegistry internal wmRegistry;

	bytes32 public immutable VaultInitCodeHash =
		keccak256(type(WMVault).creationCode);

	// todo Set these all to 1 in constructor, reset to 1 after each deploy
	// to minimize writes from 0->1 (does this actually matter when it goes 0->1->0 in same tx?)
	address public factoryVaultUnderlying = address(0x00);
	address public factoryPermissionRegistry = address(0x00);

	// can shave these values down to appropriate uintX later
	uint256 public factoryVaultMaximumCapacity = 0;
	int256 public factoryVaultAnnualAPR = 0;
	uint256 public factoryVaultCollatRatio = 0;

	string public factoryVaultNamePrefix = "";
	string public factoryVaultSymbolPrefix = "";

	event WMVaultRegistered(address, address);

	modifier isWintermute() {
		if (msg.sender != IWMPermissions(wmPermissionAddress).wintermute()) {
			revert NotWintermute();
		}
		_;
	}

	constructor(address _permissions) {
		wmPermissionAddress = _permissions;
		WMRegistry registry = new WMRegistry{ salt: bytes32(0x0) }();
		wmRegistry = IWMRegistry(address(registry));
	}

	function deployVault(
		address _underlying,
		uint256 _maxCapacity,
		int256 _annualAPR,
		uint256 _collatRatio,
		string memory _namePrefix,
		string memory _symbolPrefix,
		bytes32 _salt
	) public isWintermute returns (address vault) {
		// Set variables for vault creation
		factoryVaultUnderlying = _underlying;
		factoryPermissionRegistry = wmPermissionAddress;
		factoryVaultMaximumCapacity = _maxCapacity;
		factoryVaultAnnualAPR = _annualAPR;
		factoryVaultCollatRatio = _collatRatio;
		factoryVaultNamePrefix = _namePrefix;
		factoryVaultSymbolPrefix = _symbolPrefix;

		vault = address(new WMVault{ salt: _salt }());
		wmRegistry.registerVault(vault);

		// Reset variables for gas refund
		factoryVaultUnderlying = address(0x00);
		factoryPermissionRegistry = address(0x00);
		factoryVaultMaximumCapacity = 0;
		factoryVaultAnnualAPR = 0;
		factoryVaultCollatRatio = 0;
		factoryVaultNamePrefix = "";
		factoryVaultSymbolPrefix = "";
	}

	function vaultPermissionsAddress() external view returns (address) {
		return wmPermissionAddress;
	}

	function vaultRegistryAddress() external view returns (address) {
		return address(wmRegistry);
	}

	function computeVaultAddress(bytes32 salt) external view returns (address) {
		return
			address(
				uint160(
					uint256(
						keccak256(
							abi.encodePacked(
								bytes1(0xff),
								address(this),
								salt,
								VaultInitCodeHash
							)
						)
					)
				)
			);
	}
}
