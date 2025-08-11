// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "layerzero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTReceipt, SendParam} from "layerzero/oft-evm/interfaces/IOFT.sol";

import {ArrayLib} from "./utils/ArrayLib.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockERC4626} from "./utils/MockERC4626.sol";

import {LayerZeroOFTAdapter, LayerZeroOFTAdapterFactory} from "../src/LayerZeroOFTAdapterFactory.sol";
import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";

contract LayerZeroOFTAdapterTest is Test {
    uint32 dstEid = 30332;
    uint32 srcEid = 30101;

    ILayerZeroEndpointV2 srcEndpoint = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);
    ILayerZeroEndpointV2 dstEndpoint = ILayerZeroEndpointV2(0x6F475642a6e85809B1c36Fa62763669b1b48DD5B);

    bytes32 salt = keccak256("citrus-finance");

    function test_TransferShare() public {
        vm.createSelectFork("https://eth.drpc.org");

        MockERC20 asset = new MockERC20{salt: salt}("USD", "USD", 18);
        address vault = address(new MockERC4626{salt: salt}(address(asset), "Mock Token Vault", "vwTKN"));
        Share share = new Share{salt: salt}(address(this), "Citrus USD", "cUSD", 18);
        SyntheticVault syntheticVault =
            new SyntheticVault{salt: salt}(address(asset), address(share), vault, address(this), address(this));

        share.addMinter(address(syntheticVault));
        syntheticVault.setDepositCapLimit(type(uint256).max);
        syntheticVault.setDepositCap(type(uint256).max);

        asset.mint(address(this), 1e18);
        asset.approve(address(syntheticVault), 1e18);

        syntheticVault.deposit(1e18, address(this));

        LayerZeroOFTAdapterFactory factory = new LayerZeroOFTAdapterFactory{salt: salt}(
            address(this),
            ArrayLib.toArray(address(srcEndpoint), address(dstEndpoint)),
            new bytes32[](0),
            address(share)
        );

        share.addMinter(address(factory));

        factory.deployOFTAdapter(address(srcEndpoint));

        bytes memory lzReceiveOption = abi.encodePacked(uint128(21000));
        bytes memory options = abi.encodePacked(
            uint16(3), // TYPE 3
            uint8(1), // WORKER_ID
            uint16(lzReceiveOption.length) + 1, // +1 for optionType
            uint8(1), // OPTION_TYPE_LZRECEIVE
            lzReceiveOption
        );

        bytes32 receiver = bytes32(uint256(uint160(factory.computeOFTAdapterAddress(address(dstEndpoint)))));

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: receiver,
            amountLD: 1e18,
            minAmountLD: 1e18,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        LayerZeroOFTAdapter srcAdapter = LayerZeroOFTAdapter(factory.computeOFTAdapterAddress(address(srcEndpoint)));

        MessagingFee memory msgFee = srcAdapter.quoteSend(sendParam, false);

        assertEq(share.balanceOf(address(this)), 1e18);

        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            srcAdapter.send{value: msgFee.nativeFee}(sendParam, msgFee, address(this));

        assertEq(share.balanceOf(address(this)), 0);

        vm.createSelectFork("https://lb.drpc.org/sonic/AkxCMJuiX0QnnblQwURID1YtBoj0ZOcR8K0YEklbR4ac");

        new Share{salt: salt}(address(this), "Citrus USD", "cUSD", 18);

        share.addMinter(address(factory));

        assertEq(share.balanceOf(address(this)), 0);

        new LayerZeroOFTAdapterFactory{salt: salt}(
            address(this),
            ArrayLib.toArray(address(srcEndpoint), address(dstEndpoint)),
            new bytes32[](0),
            address(share)
        );

        address dstAdapter = factory.deployOFTAdapter(address(dstEndpoint));

        bytes32 sender = bytes32(uint256(uint160(address(srcAdapter))));

        Origin memory origin = Origin({srcEid: srcEid, sender: sender, nonce: msgReceipt.nonce});

        bytes memory message = abi.encodePacked(receiver, uint64(oftReceipt.amountReceivedLD / (1e12)));

        {
            bytes32 payloadHash = keccak256(abi.encodePacked(msgReceipt.guid, message));

            address receiveLib = ILayerZeroEndpointV2(dstEndpoint).defaultReceiveLibrary(dstEid);

            vm.prank(receiveLib);
            ILayerZeroEndpointV2(dstEndpoint).verify(origin, address(dstAdapter), payloadHash);
        }

        dstEndpoint.lzReceive(origin, address(dstAdapter), msgReceipt.guid, message, "");

        assertEq(share.balanceOf(address(this)), 0);
    }
}
