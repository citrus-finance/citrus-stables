// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "layerzero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {
    OFTReceipt, SendParam
} from "lib/layerzero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/interfaces/IOFT.sol";

import {ArrayLib} from "./utils/ArrayLib.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockERC4626} from "./utils/MockERC4626.sol";

import {LayerZeroOFTAdapter, LayerZeroOFTAdapterFactory} from "../src/LayerZeroOFTAdapterFactory.sol";
import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";

contract LayerZeroOFTAdapterFactoryTest is Test {
    ILayerZeroEndpointV2 endpoint;

    LayerZeroOFTAdapterFactory public factory;

    MockERC20 asset;
    address vault;
    Share share;
    SyntheticVault syntheticVault;

    function setUp() public {
        endpoint = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);

        asset = new MockERC20("USD", "USD", 18);
        vault = address(new MockERC4626(address(asset), "Mock Token Vault", "vwTKN"));
        share = new Share("Citrus USD", "cUSD", 18);
        syntheticVault =
            new SyntheticVault(address(asset), address(share), address(vault), address(this), address(this));

        share.addMinter(address(syntheticVault));
        syntheticVault.setDepositCapLimit(type(uint256).max);
        syntheticVault.setDepositCap(type(uint256).max);

        factory = new LayerZeroOFTAdapterFactory(
            address(this), ArrayLib.toArray(address(endpoint)), new bytes32[](0), address(share)
        );

        vm.createSelectFork("https://eth.drpc.org");
    }

    function test_PeerApprovedByDefault() public {
        address peerAddress = factory.computeOFTAdapterAddress(address(endpoint));
        bytes32 peer = bytes32(uint256(uint160(peerAddress)));

        assertTrue(factory.approvedPeers(peer));
    }

    function test_DeployOFTAdaptor() public {
        address expectedAddress = factory.computeOFTAdapterAddress(address(endpoint));
        address actualAddress = factory.deployOFTAdapter(address(endpoint));

        assertEq(expectedAddress, actualAddress);
        assertNotEq(actualAddress.code, "");
    }

    function test_TryToDeployOFTAdaptorUsingUnapprovedEndpoint() public {
        factory.revokeEndpoint(address(endpoint));

        vm.expectRevert(
            abi.encodeWithSelector(LayerZeroOFTAdapterFactory.OFTAdapterDeploymentForbidden.selector, address(endpoint))
        );
        factory.deployOFTAdapter(address(endpoint));
    }
}
