// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "layerzero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTCore} from "layerzero/oft-evm/OFTCore.sol";
import {OFTReceipt, SendParam} from "layerzero/oft-evm/interfaces/IOFT.sol";

import {Share} from "./Share.sol";

/// @title LayerZeroOFTAdapterFactory
/// @notice Allow the bridging of shares through LayerZero.
/// It deploys an adapter for the endpoint available on the current chain
/// and handle minting and burning of the share token.
contract LayerZeroOFTAdapterFactory is Ownable {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event EndpointApproved(address indexed endpoint);

    event EndpointRevoked(address indexed endpoint);

    event PeerApproved(bytes32 indexed peer);

    event PeerRevoked(bytes32 indexed peer);

    event OFTAdapterDeployed(address indexed adapter);

    /*//////////////////////////////////////////////////////////////
                                ERRORS 
    //////////////////////////////////////////////////////////////*/

    error OFTAdapterDeploymentForbidden(address endpoint);

    error AdapterUnauthorized(address adapter);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice EVM LayerZero endpoints that are allowed.
    mapping(address => bool) public approvedEndpoints;

    /// @notice Peers that are allowed.
    mapping(bytes32 => bool) public approvedPeers;

    Share public immutable share;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_, address[] memory approvedEndpoints_, bytes32[] memory approvedPeers_, address share_)
        Ownable(owner_)
    {
        share = Share(share_);

        for (uint256 i = 0; i < approvedEndpoints_.length; ++i) {
            _approveEndpoint(approvedEndpoints_[i]);
        }

        for (uint256 i = 0; i < approvedPeers_.length; ++i) {
            _approvePeer(approvedPeers_[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ENDPOINT APPROVAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _approveEndpoint(address endpoint) internal {
        approvedEndpoints[endpoint] = true;

        emit EndpointApproved(endpoint);

        address adapter = computeOFTAdapterAddress(endpoint);

        // Automatically approve peer from endpoint
        _approvePeer(bytes32(uint256(uint160(adapter))));
    }

    /// @notice Approve a new EVM LayerZero endpoint.
    /// @param endpoint The LayerZero endpoint to approve
    /// @dev Also approve the associated peer.
    function approveEndpoint(address endpoint) public onlyOwner {
        _approveEndpoint(endpoint);
    }

    /// @notice revoke a EVM LayerZero endpoint.
    /// @param endpoint The LayerZero endpoint to revoke
    /// TODO: should pause the adapter
    function revokeEndpoint(address endpoint) public onlyOwner {
        approvedEndpoints[endpoint] = false;
        emit EndpointRevoked(endpoint);
    }

    /*//////////////////////////////////////////////////////////////
                        PEER APPROVAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _approvePeer(bytes32 peer) internal {
        approvedPeers[peer] = true;
        emit PeerApproved(peer);
    }

    /// @notice Approve a new peer.
    /// @param peer The peer to revoke
    /// @dev If it's an EVM peer, it might be better to add the endpoint instead.
    function approvePeer(bytes32 peer) public onlyOwner {
        _approvePeer(peer);
    }

    /// @notice Revoke a peer.
    /// @param peer The peer to revoke
    function revokePeer(bytes32 peer) public onlyOwner {
        approvedPeers[peer] = false;
        emit PeerRevoked(peer);
    }

    /*//////////////////////////////////////////////////////////////
                        SHARE MINTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint token.
    /// @dev Used by the OFTAdapter when receiving a message from LayerZero.
    /// @param to The address to mint the tokens to.
    /// @param value The amount of tokens to mint.
    function mintToken(address to, uint256 value) public onlyAdapter {
        share.mint(to, value);
    }

    /// @notice Burn token.
    /// @dev Used by the OFTAdapter when sending a message to LayerZero
    /// @param from The address from which the tokens are going to be burn.
    /// @param value The amount of tokens to burn.
    function burnToken(address from, uint256 value) public onlyAdapter {
        share.burn(from, value);
    }

    /*//////////////////////////////////////////////////////////////
                        OFTAdapterFactory LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy OFTAdapter to be able to connect with LayerZero and send/receive tokens.
    /// @param endpoint The endpoint of the peer we are deploying
    /// @return adapter The peer EVM address
    function deployOFTAdapter(address endpoint) public returns (address adapter) {
        require(approvedEndpoints[endpoint], OFTAdapterDeploymentForbidden(endpoint));

        bytes memory bytecode = getOFTAdapterBytecode(endpoint);
        bytes32 salt = keccak256(abi.encodePacked(endpoint));

        adapter = Create2.deploy(0, salt, bytecode);

        emit OFTAdapterDeployed(adapter);

        LayerZeroOFTAdapter(adapter).transferOwnership(owner());
    }

    /// @notice Get address of peer associated with endpoint.
    /// @dev Used to approve peers from other EVM chains.
    /// @param endpoint The endpoint of the peer those address we want
    /// @return peerAddress The peer EVM address
    function computeOFTAdapterAddress(address endpoint) public view returns (address peerAddress) {
        bytes memory bytecode = getOFTAdapterBytecode(endpoint);
        bytes32 bytecodeHash = keccak256(bytecode);
        bytes32 salt = keccak256(abi.encodePacked(endpoint));
        peerAddress = Create2.computeAddress(salt, bytecodeHash, address(this));
    }

    function getOFTAdapterBytecode(address endpoint) internal view returns (bytes memory bytecode) {
        bytecode = abi.encodePacked(
            type(LayerZeroOFTAdapter).creationCode, abi.encode(address(this), address(this), endpoint, address(this))
        );
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdapter() {
        _onlyAdapter();
        _;
    }

    function _onlyAdapter() internal {
        bytes32 peer = bytes32(uint256(uint160(msg.sender)));
        require(approvedPeers[peer], AdapterUnauthorized(msg.sender));
    }
}

/// @title LayerZeroOFTAdapter
/// @notice Handle the connection with LayerZero endpoint and the factory.
/// TODO:
/// - review delegate and owner
contract LayerZeroOFTAdapter is OFTCore {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract that deploy this contract and handle the token logic.
    LayerZeroOFTAdapterFactory public factory;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address factory_, address owner_, address lzEndpoint_, address delegate_)
        Ownable(owner_)
        OFTCore(LayerZeroOFTAdapterFactory(factory_).share().decimals(), lzEndpoint_, delegate_)
    {
        factory = LayerZeroOFTAdapterFactory(factory_);
    }

    /*//////////////////////////////////////////////////////////////
                            OFTAdapter logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Retrieves the address of the underlying ERC20 implementation.
    /// @return The address of the adapted ERC-20 token.
    function token() public view override returns (address) {
        return address(factory.share());
    }

    /**
     * /// @notice Indicates whether the OFT contract requires approval of the 'token()' to send.
     * /// @return requiresApproval Needs approval of the underlying token implementation.
     */
    function approvalRequired() external pure override returns (bool) {
        return false;
    }

    /// @dev Burns tokens from the sender's specified balance, ie. pull method.
    /// @param from The address to debit from.
    /// @param amountLD The amount of tokens to send in local decimals.
    /// @param minAmountLD The minimum amount to send in local decimals.
    /// @param dstEid The destination chain ID.
    /// @return amountSentLD The amount sent in local decimals.
    /// @return amountReceivedLD The amount received in local decimals on the remote.
    function _debit(address from, uint256 amountLD, uint256 minAmountLD, uint32 dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(amountLD, minAmountLD, dstEid);
        // @dev Burn tokens
        factory.burnToken(from, amountSentLD);
    }

    /// @dev Credits tokens to the specified address.
    /// @param to The address to credit the tokens to.
    /// @param amountLD The amount of tokens to credit in local decimals.
    /// @dev srcEid The source chain ID.
    /// @return amountReceivedLD The amount of tokens ACTUALLY received in local decimals.
    function _credit(address to, uint256 amountLD, uint32 /*srcEid*/ )
        internal
        virtual
        override
        returns (uint256 amountReceivedLD)
    {
        // @dev Mint tokens
        factory.mintToken(to, amountLD);
        // @dev In the case of NON-default OFTAdapter, the amountLD MIGHT not be == amountReceivedLD.
        return amountLD;
    }

    /*//////////////////////////////////////////////////////////////
                        OFTCore LOGIC OVERWRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Provides a quote for the send() operation.
    /// @param sendParam The parameters for the send() operation.
    /// @param payInLzToken Flag indicating whether the caller is paying in the LZ token.
    /// @return msgFee The calculated LayerZero messaging fee from the send() operation.
    ///
    /// @dev MessagingFee: LayerZero msg fee
    ///  - nativeFee: The native fee.
    ///  - lzTokenFee: The lzToken fee.
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        override
        returns (MessagingFee memory msgFee)
    {
        // @dev mock the amount to receive, this is the same operation used in the send().
        // The quote is as similar as possible to the actual send() operation.
        (, uint256 amountReceivedLD) = _debitView(sendParam.amountLD, sendParam.minAmountLD, sendParam.dstEid);

        // @dev Builds the options and OFT message to quote in the endpoint.
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(sendParam, amountReceivedLD);

        // @dev Calculates the LayerZero fee for the send() operation.
        return endpoint.quote(
            MessagingParams(sendParam.dstEid, sendParam.to, message, options, payInLzToken), address(this)
        );
    }

    /// @dev Executes the send operation.
    /// @param sendParam The parameters for the send operation.
    /// @param fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param refundAddress The address to receive any excess funds.
    /// @return msgReceipt The receipt for the send operation.
    /// @return oftReceipt The OFT receipt information.
    ///
    /// @dev MessagingReceipt: LayerZero msg receipt
    ///  - guid: The unique identifier for the sent message.
    ///  - nonce: The nonce of the sent message.
    ///  - fee: The LayerZero fee incurred for the message.
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        override
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {
        // @dev Applies the token transfers regarding this send() operation.
        // - amountSentLD is the amount in local decimals that was ACTUALLY sent/debited from the sender.
        // - amountReceivedLD is the amount in local decimals that will be received/credited to the recipient on the remote OFT instance.
        (uint256 amountSentLD, uint256 amountReceivedLD) =
            _debit(msg.sender, sendParam.amountLD, sendParam.minAmountLD, sendParam.dstEid);

        // @dev Builds the options and OFT message to quote in the endpoint.
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(sendParam, amountReceivedLD);

        // @dev Push corresponding fees to the endpoint, any excess is sent back to the refundAddress from the endpoint.
        uint256 messageValue = _payNative(fee.nativeFee);
        if (fee.lzTokenFee > 0) _payLzToken(fee.lzTokenFee);

        // @dev Sends the message to the LayerZero endpoint and returns the LayerZero msg receipt.
        msgReceipt = endpoint.send{value: messageValue}(
            MessagingParams(sendParam.dstEid, sendParam.to, message, options, fee.lzTokenFee > 0), refundAddress
        );
        // @dev Formulate the OFT receipt.
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /// @dev Entry point for receiving messages or packets from the endpoint.
    /// @param origin The origin information containing the source endpoint and sender address.
    ///  - srcEid: The source chain endpoint ID.
    ///  - sender: The sender address on the src chain.
    ///  - nonce: The nonce of the message.
    /// @param guid The unique identifier for the received LayerZero message.
    /// @param message The payload of the received message.
    /// @param executor The address of the executor for the received message.
    /// @param extraData Additional arbitrary data provided by the corresponding executor.
    ///
    /// @dev Entry point for receiving msg/packet from the LayerZero endpoint.
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) public payable override {
        // Ensures that only the endpoint can attempt to lzReceive() messages to this OApp.
        if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);

        // Ensure that the sender is valid
        if (!factory.approvedPeers(origin.sender)) revert OnlyPeer(origin.srcEid, origin.sender);

        // Call the internal OApp implementation of lzReceive.
        _lzReceive(origin, guid, message, executor, extraData);
    }

    /// @notice Checks if the path initialization is allowed based on the provided origin.
    /// @param origin The origin information containing the source endpoint and sender address.
    /// @return Whether the path has been initialized.
    function allowInitializePath(Origin calldata origin) public view override returns (bool) {
        return factory.approvedPeers(origin.sender);
    }

    /// @dev Check if the peer is considered 'trusted' by the OApp.
    /// @param eid The endpoint ID to check.
    /// @param peer The peer to check.
    /// @return Whether the peer passed is considered 'trusted' by the OApp.
    ///
    /// @dev Enables OAppPreCrimeSimulator to check whether a potential Inbound Packet is from a trusted source.
    function isPeer(uint32 eid, bytes32 peer) public view override returns (bool) {
        return factory.approvedPeers(peer);
    }
}
