// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IPolicyPool} from "../interfaces/IPolicyPool.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPolicyNFT} from "../interfaces/IPolicyNFT.sol";

/**
 * @title PolicyNFT - NFT that keeps track of issued policies and its owners
 * @dev Every time a new policy is accepted by the PolicyPool, a new NFT is minted generating a new
 *      policyId owned by the customer. Only the PolicyPool can mint NFTs.
 *      After creation, NFTs can be transferred in the ERC721 standard way and that changes the policy holder.
 * @custom:security-contact security@ensuro.co
 * @author Ensuro
 */
contract PolicyNFT is UUPSUpgradeable, ERC721Upgradeable, PausableUpgradeable, IPolicyNFT {
  bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
  bytes32 public constant LEVEL1_ROLE = keccak256("LEVEL1_ROLE");

  IPolicyPool internal _policyPool;

  modifier onlyPolicyPool() {
    require(_msgSender() == address(_policyPool), "The caller must be the PolicyPool");
    _;
  }

  modifier onlyPoolRole2(bytes32 role1, bytes32 role2) {
    _policyPool.config().checkRole2(role1, role2, msg.sender);
    _;
  }

  modifier onlyPoolRole(bytes32 role) {
    _policyPool.config().checkRole(role, msg.sender);
    _;
  }

  function initialize(
    string memory name_,
    string memory symbol_,
    IPolicyPool policyPool_
  ) public initializer {
    __UUPSUpgradeable_init();
    __Pausable_init();
    __ERC721_init(name_, symbol_);
    __PolicyNFT_init_unchained(policyPool_);
  }

  // solhint-disable-next-line func-name-mixedcase
  function __PolicyNFT_init_unchained(IPolicyPool policyPool_) internal initializer {
    _policyPool = policyPool_;
  }

  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address) internal override onlyPoolRole2(GUARDIAN_ROLE, LEVEL1_ROLE) {}

  function pause() public onlyPoolRole(GUARDIAN_ROLE) {
    _pause();
  }

  function unpause() public onlyPoolRole2(GUARDIAN_ROLE, LEVEL1_ROLE) {
    _unpause();
  }

  /**
   * @dev This function can be called only once in contract's lifetime. It links the NFT with the
   *      PolicyPool contract. It's called in PolicyPool initialization.
   */
  function connect() external override {
    require(
      address(_policyPool) == address(0) || address(_policyPool) == _msgSender(),
      "PolicyPool already connected"
    );
    _policyPool = IPolicyPool(_msgSender());
    // Not possible to do this validation because connect is called in _policyPool initialize :'(
    // require(_policyPool.policyNFT() == address(this), "PolicyPool not connected to this config");
  }

  function policyPool() external view returns (IPolicyPool) {
    return _policyPool;
  }

  function safeMint(address to, uint256 policyId) external override onlyPolicyPool whenNotPaused {
    _safeMint(to, policyId, "");
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 tokenId
  ) internal override whenNotPaused {
    super._beforeTokenTransfer(from, to, tokenId);
  }
}
