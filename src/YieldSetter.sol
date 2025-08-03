// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Share} from "./Share.sol";

contract YieldSetter is Ownable {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SignerUpdated(address signer);

    event MaxYieldUpdated(uint256 maxYield);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidNewSigner(address newSigner);

    error InvalidSigner(address expectedSigner, address actualSigner);

    error NonceTooLow(uint256 expectedNonce, uint256 actualNonce);

    error YieldTooHigh(uint256 maxYield, uint256 actualYield);

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    /// @notice keep track of the nonce for each week so that we can update the yield.
    /// @dev mapping: week => nonce
    mapping(uint256 => uint256) public weekYieldNonces;

    /*//////////////////////////////////////////////////////////////
                            YieldSetter STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public maxYield;

    address public signer;

    Share public share;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_, address signer_, address share_, uint256 maxYield_) Ownable(owner_) {
        signer = signer_;
        share = Share(share_);
        maxYield = maxYield_;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                // NOTE: we do not use the chain id as we want the signature to be valid across chains
                keccak256("EIP712Domain(address verifyingContract)"),
                address(this)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            YieldSetter LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the signer
    /// @param newSigner The new signer
    function setSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), InvalidNewSigner(newSigner));
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    /// @notice Sets the max yield
    /// @param newMaxYield The new max yield
    function setMaxYield(uint256 newMaxYield) external onlyOwner {
        maxYield = newMaxYield;
        emit MaxYieldUpdated(newMaxYield);
    }

    /// @notice Gets the set yield message hash
    /// @param yield The yield to set
    /// @param week The week to set the yield for
    /// @param nonce The nonce to use
    /// @return The set yield message hash
    function getSetYieldMessageHash(uint256 yield, uint256 week, uint256 nonce) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(keccak256("SetYield(uint256 yield,uint256 week,uint256 nonce)"), yield, week, nonce)
                )
            )
        );
    }

    /// @notice Sets the yield for a given week
    /// @param yield The yield to set
    /// @param week The week to set the yield for
    /// @param nonce The nonce to use
    /// @param v The v value
    /// @param r The r value
    /// @param s The s value
    function setYield(uint256 yield, uint256 week, uint256 nonce, uint8 v, bytes32 r, bytes32 s) external {
        // nonce does not need to be sequential, but it must be greater than the last one
        // This is done so we can update the yield for a week multiple times if needed
        require(weekYieldNonces[week] <= nonce, NonceTooLow(weekYieldNonces[week], nonce));

        // yield must be less than the max yield
        require(yield <= maxYield, YieldTooHigh(maxYield, yield));

        address recoveredAddress = ECDSA.recover(getSetYieldMessageHash(yield, week, nonce), v, r, s);

        require(recoveredAddress == signer, InvalidSigner(signer, recoveredAddress));

        weekYieldNonces[week] = nonce + 1;
        Share(share).setYield(yield, week);
    }
}
