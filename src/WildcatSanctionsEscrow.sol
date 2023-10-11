// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import { IERC20 } from './interfaces/IERC20.sol';
import { IChainalysisSanctionsList } from './interfaces/IChainalysisSanctionsList.sol';
import { SanctionsList } from './libraries/Chainalysis.sol';
import { WildcatSanctionsSentinel } from './WildcatSanctionsSentinel.sol';
import { IWildcatSanctionsEscrow } from './interfaces/IWildcatSanctionsEscrow.sol';

contract WildcatSanctionsEscrow is IWildcatSanctionsEscrow {
  address public immutable override borrower;
  address public immutable override account;

  IChainalysisSanctionsList internal constant chainalysisSanctionsList = SanctionsList;
  address internal immutable asset;

  constructor() {
    (borrower, account, asset) = WildcatSanctionsSentinel(msg.sender).tmpVaultParams();
  }

  function balance() public view override returns (uint256) {
    return IERC20(asset).balanceOf(address(this));
  }

  function canReleaseEscrow() public view override returns (bool) {
    return !chainalysisSanctionsList.isSanctioned(account);
  }

  function escrowedAsset() public view override returns (address, uint256) {
    return (asset, balance());
  }

  function releaseEscrow() public override {
    if (msg.sender != borrower && !canReleaseEscrow()) revert CanNotReleaseEscrow();

    uint256 amount = balance();

    IERC20(asset).transfer(account, amount);

    emit EscrowReleased(msg.sender, account, asset, amount);
  }
}
