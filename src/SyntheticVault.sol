// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {Share} from "./Share.sol";

/// @title SyntheticVault
/// @notice A vault that issues shares equivalent to the underlying asset's value
/// @dev the vault needs to be a minter of the share token
/// TODO:
/// - fees
contract SyntheticVault is Ownable {
    using SafeERC20 for IERC20Metadata;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    event DepositCapLimitUpdated(uint256 oldDepositCapLimit, uint256 newDepositCapLimit);

    event DepositCapUpdated(uint256 oldDepositCap, uint256 newDepositCap);

    event ManagerUpdated(address oldManager, address newManager);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error DepositZeroShares();

    error RedeemZeroAssets();

    error DepositCapReached();

    error ManagerUnauthorized();

    error NewDepositCapTooHigh(uint256 depositCapLimit, uint256 actualDepositCap);

    /*//////////////////////////////////////////////////////////////
                          ERC-7575 STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20Metadata private _asset;

    Share private _share;

    IERC4626 private _vault;

    /*//////////////////////////////////////////////////////////////
                          SYNTHETIC VAULT STORAGE
    //////////////////////////////////////////////////////////////*/

    address public manager;

    uint256 public depositCapLimit;

    uint256 public depositCap;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address asset_, address share_, address vault_, address owner_, address manager_) Ownable(owner_) {
        _asset = IERC20Metadata(asset_);
        _share = Share(share_);
        _vault = IERC4626(vault_);
        manager = manager_;

        _asset.approve(address(vault_), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-7575 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the underlying asset
    function asset() public view returns (address) {
        return address(_asset);
    }

    /// @notice The address of the share token
    /// @dev This is the token that the user will receive when they deposit
    function share() public view returns (address) {
        return address(_share);
    }

    /// @notice The address of the underlying vault
    function vault() public view returns (address) {
        return address(_vault);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets and mints equivalent shares.
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the shares
    /// @return shares The amount of shares received
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, DepositZeroShares());

        // Need to transfer before minting or ERC777s could reenter.
        _asset.safeTransferFrom(msg.sender, address(this), assets);

        _share.mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets);
    }

    /// @notice Mints shares by depositing equivalent assets.
    /// @param shares The amount of shares to mint
    /// @param receiver The address to receive the shares
    /// @return assets The amount of assets used to mint the shares
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        _asset.safeTransferFrom(msg.sender, address(this), assets);

        _share.mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets);
    }

    /// @notice Withdraws assets from the vault and burns equivalent shares.
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address to receive the assets
    /// @param owner The address to burn the shares from
    /// @return shares The amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            _share.useAllowance(owner, msg.sender, shares);
        }

        beforeWithdraw(assets);

        _share.burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        _asset.safeTransfer(receiver, assets);
    }

    /// @notice Redeems shares and receives equivalent assets.
    /// @param shares The amount of shares to redeem
    /// @param receiver The address to receive the assets
    /// @param owner The address to burn the shares from
    /// @return assets The amount of assets received
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        if (msg.sender != owner) {
            _share.useAllowance(owner, msg.sender, shares);
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, RedeemZeroAssets());

        beforeWithdraw(assets);

        _share.burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        _asset.safeTransfer(receiver, assets);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total amount of assets managed by the vault.
    function totalAssets() public view returns (uint256 totalManagedAssets) {
        IERC4626 vault = _vault;

        return (vault.convertToAssets(vault.balanceOf(address(this))) + _asset.balanceOf(address(this)));
    }

    /// @notice Returns the amount of shares that the Vault would exchange for the amount of assets provided
    /// @param assets The amount of assets to convert
    /// @return shares The amount of shares received
    /// @dev assets and shares are 1:1, only decimals difference is handled here
    function convertToShares(uint256 assets) public view returns (uint256) {
        int8 decimalsDiff = int8(_share.decimals()) - int8(_asset.decimals());

        if (decimalsDiff == 0) {
            return assets;
        } else if (decimalsDiff > 0) {
            return assets * (10 ** uint8(decimalsDiff));
        } else {
            return assets / (10 ** uint8(-decimalsDiff));
        }
    }

    /// @notice Returns the amount of assets that the Vault would exchange for the amount of shares provided
    /// @param shares The amount of shares to convert
    /// @return assets The amount of assets received
    /// @dev assets and shares are 1:1, only decimals difference is handled here
    function convertToAssets(uint256 shares) public view returns (uint256) {
        int8 decimalsDiff = int8(_asset.decimals()) - int8(_share.decimals());

        if (decimalsDiff == 0) {
            return shares;
        } else if (decimalsDiff > 0) {
            return shares * (10 ** uint8(decimalsDiff));
        } else {
            return shares / (10 ** uint8(-decimalsDiff));
        }
    }

    /// @notice Returns the amount of shares that the Vault would exchange for the amount of assets provided
    /// @param assets The amount of assets to convert
    /// @return shares The amount of shares received
    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        return convertToShares(assets);
    }

    /// @notice Returns the amount of assets that the Vault would exchange for the amount of shares provided
    /// @param shares The amount of shares to convert
    /// @return assets The amount of assets received
    function previewMint(uint256 shares) public view returns (uint256 assets) {
        int8 decimalsDiff = int8(_asset.decimals()) - int8(_share.decimals());

        if (decimalsDiff == 0) {
            return shares;
        } else if (decimalsDiff > 0) {
            return shares * (10 ** uint8(decimalsDiff));
        } else {
            // The denominator can never be zero.
            return shares.divUp(10 ** uint8(-decimalsDiff));
        }
    }

    /// @notice Returns the amount of shares that the Vault would exchange for the amount of assets provided
    /// @param assets The amount of assets to convert
    /// @return shares The amount of shares received
    function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
        int8 decimalsDiff = int8(_share.decimals()) - int8(_asset.decimals());

        if (decimalsDiff == 0) {
            return assets;
        } else if (decimalsDiff > 0) {
            return assets * (10 ** uint8(decimalsDiff));
        } else {
            // The denominator can never be zero.
            return assets.divUp(10 ** uint8(-decimalsDiff));
        }
    }

    /// @notice Returns the amount of assets that the Vault would exchange for the amount of shares provided
    /// @param shares The amount of shares to convert
    /// @return assets The amount of assets received
    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the maximum amount of assets that can be deposited into the vault
    /// @param owner The address to check the limit for
    /// @return maxAssets The maximum amount of assets that can be deposited
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        uint256 total = totalAssets();
        uint256 cap = depositCap;

        if (total > cap) {
            return 0;
        }

        return cap - total;
    }

    /// @notice Returns the maximum amount of shares that can be minted by the vault
    /// @param receiver The address to check the limit for
    /// @return maxShares The maximum amount of shares that can be minted
    function maxMint(address receiver) public view returns (uint256 maxShares) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice Returns the maximum amount of assets that can be withdrawn from the vault
    /// @param owner The address to check the limit for
    /// @return maxAssets The maximum amount of assets that can be withdrawn
    function maxWithdraw(address owner) public view returns (uint256 maxAssets) {
        return convertToAssets(_share.balanceOf(owner));
    }

    /// @notice Returns the maximum amount of shares that can be redeemed by the vault
    /// @param owner The address to check the limit for
    /// @return maxShares The maximum amount of shares that can be redeemed
    function maxRedeem(address owner) public view returns (uint256 maxShares) {
        return _share.balanceOf(owner);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the manager of the vault
    /// @param newManager The address of the new manager
    function setManager(address newManager) public onlyOwner {
        emit ManagerUpdated(manager, newManager);
        manager = newManager;
    }

    /// @notice Sets the deposit cap limit of the vault
    /// @param newDepositCapLimit The new deposit cap limit
    /// @dev Only the owner can call this function, if you are the manager call setDepositCap instead
    function setDepositCapLimit(uint256 newDepositCapLimit) public onlyOwner {
        emit DepositCapLimitUpdated(depositCapLimit, newDepositCapLimit);
        depositCapLimit = newDepositCapLimit;

        if (depositCap > newDepositCapLimit) {
            emit DepositCapUpdated(depositCap, newDepositCapLimit);
            depositCap = newDepositCapLimit;
        }
    }

    /// @notice Sets the deposit cap of the vault
    /// @param newDepositCap The new deposit cap
    function setDepositCap(uint256 newDepositCap) public onlyManager {
        require(newDepositCap <= depositCapLimit, NewDepositCapTooHigh(depositCapLimit, newDepositCap));

        emit DepositCapUpdated(depositCap, newDepositCap);
        depositCap = newDepositCap;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 assets) internal {
        uint256 balance = _asset.balanceOf(address(this));

        // No need to withdraw if we already have enough assets.
        if (balance > assets) {
            return;
        }

        uint256 shares = _vault.previewWithdraw(assets);
        uint256 maxShares = _vault.maxRedeem(address(this));

        // Do not try to redeem more shares than we can.
        if (shares > maxShares) {
            shares = maxShares;
        }

        if (shares != 0) {
            _vault.redeem(shares, address(this), address(this));
        }
    }

    // TODO: use maxMint
    function afterDeposit(uint256) internal {
        require(totalAssets() <= depositCap, DepositCapReached());

        uint256 shares = _vault.previewDeposit(_asset.balanceOf(address(this)));

        if (shares != 0) {
            _vault.mint(shares, address(this));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-165
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC7575).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyManager() {
        _onlyManager();
        _;
    }

    function _onlyManager() internal {
        require(msg.sender == manager || msg.sender == owner(), ManagerUnauthorized());
    }
}
