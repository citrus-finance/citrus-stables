// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

enum RebaseOptions {
    NonRebasing,
    Rebasing,
    YieldDelegation
}

/**
 * @title Share
 * @notice ERC20 compatible that represent a one to one claim with the underlying assets.
 * By default, the token the user receive as non rebasing which means their balance does not grow over time.
 * However, the user can opt in to rebasing which means their balance will grow over time.
 * TODO:
 * - yield delegation
 */
contract Share is Ownable, IERC20 {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterAdded(address indexed minter);

    event MinterRemoved(address indexed minter);

    event YieldSetterUpdated(address indexed yieldSetter);

    event YieldSet(uint256 indexed week, uint256 yield);

    /*//////////////////////////////////////////////////////////////
                                ERRORS 
    //////////////////////////////////////////////////////////////*/

    error MinterUnauthorized(address minter);

    error YieldSetterUnauthorized(address yieldSetter);

    error TransferFromZeroAddress();

    error TransferToZeroAddress();

    error PermitExpired(uint256 deadline);

    error PermitInvalidSigner(address owner, address recoveredAddress);

    error RebaseUserAlreadyOptedIn();

    error RebaseUserAlreadyOptedOut();

    error MinterAlreadyAdded(address minter);

    error MinterNotAdded(address minter);

    /*//////////////////////////////////////////////////////////////
                            METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The name of the token.
    string public name;

    /// @notice The symbol of the token.
    string public symbol;

    /// @notice The number of decimals used to get its user representation.
    uint8 public immutable decimals;

    /*//////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}.
     * @dev This is zero by default.
     * @dev mapping: owner => spender => allowance
     */
    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                            REBASE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The total non-rebasing supply of the token.
    uint256 public nonRebasingTotalSupply;

    /// @notice The total rebasing supply index of the token.
    /// @dev You need to multiply with the rebasing index to get the rebasing total supply.
    uint256 public rebasingTotalSupply;

    /// @notice The balance of the token for each account.
    mapping(address => uint256) public nonRebasingBalanceOf;

    /// @notice The rebasing balance index of the token for each account.
    /// @dev You need to multiply with the rebasing index to get the rebasing balance.
    mapping(address => uint256) public rebasingBalanceOf;

    /// @notice The rebasing state of the token for each account.
    /// @dev mapping: account => rebase state
    mapping(address => RebaseOptions) public rebaseState;

    /// @notice The rebasing index of the token.
    uint256 public storedRebasingIndex;

    /// @notice The timestamp of the last rebasing index update.
    uint256 public storedLastRebasingTimestamp;

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    bytes32 internal constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice The nonce use for the permit signature of each account.
    /// @dev mapping: account => nonce
    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                                YIELD STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The yield setter address.
    address public yieldSetter;

    /// @notice The yield per second for each week.
    /// @dev mapping: week => yield per second
    mapping(uint256 => uint256) public yieldByWeek;

    /*//////////////////////////////////////////////////////////////
                                SHARE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Approved minters.
    /// @dev mapping: minter => is approved
    mapping(address => bool) public minters;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_, string memory name_, string memory symbol_, uint8 decimals_) Ownable(owner_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();

        storedRebasingIndex = 1e27;
        storedLastRebasingTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        // TODO: add rebasing total supply
        return nonRebasingTotalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual returns (uint256) {
        RebaseOptions state = rebaseState[account];

        // If non-rebasing, simply return the non-rebasing balance.
        if (state == RebaseOptions.NonRebasing) {
            return nonRebasingBalanceOf[account];
        }

        // For rebasing balance, we have to multiply with the rebasing index.
        // As the rebasing index grows over time, the rebasing balance will also grow.
        // NOTE: we use 1e36 as rebasingIndex and rebasingBalanceOf uses 27 decimals.
        // Which means to get 18 decimals, we do 27 + 27 - 18 = 36.
        return rebasingBalanceOf[account].mulDiv(rebasingIndex(), 1e36);
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual returns (bool) {
        updateRebasingIndex();

        require(from != address(0), TransferFromZeroAddress());
        require(to != address(0), TransferToZeroAddress());

        decreaseBalance(from, amount);
        increaseBalance(to, amount);

        emit Transfer(from, to, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) public virtual returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        return _transfer(from, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     * @param owner The address which owns the tokens to be approved.
     * @param spender The address which will be allowed to spend the tokens.
     * @param value The amount of tokens to be spent.
     * @param deadline The timestamp at which the spending is no longer valid.
     * @param v The `v` component of the signature.
     * @param r The `r` component of the signature.
     * @param s The `s` component of the signature.
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
    {
        require(deadline >= block.timestamp, PermitExpired(deadline));

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ECDSA.recover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress == owner, PermitInvalidSigner(owner, recoveredAddress));

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    /**
     * @notice Returns the domain separator to be used in the permit signature.
     * @return The domain separator.
     */
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256("1"), block.chainid, address(this)));
    }

    /*//////////////////////////////////////////////////////////////
                                REBASE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The calling account will start receiving yield after a successful call.
     */
    function rebaseOptIn() external {
        updateRebasingIndex();

        // To avoid any issues, make sure the user has not opted in already.
        require(rebaseState[msg.sender] == RebaseOptions.NonRebasing, RebaseUserAlreadyOptedIn());

        uint256 amount = balanceOf(msg.sender);

        // First we reset the balance of the user to zero.
        decreaseBalance(msg.sender, amount);

        // Then we change the rebase state to rebasing.
        rebaseState[msg.sender] = RebaseOptions.Rebasing;

        // Finally we set back the balance of the user. Which is now rebasing.
        increaseBalance(msg.sender, amount);
    }

    /**
     * @notice The calling account will no longer receive yield
     */
    function rebaseOptOut() external {
        updateRebasingIndex();

        // To avoid any issues, make sure the user has opted out already.
        require(rebaseState[msg.sender] == RebaseOptions.Rebasing, RebaseUserAlreadyOptedOut());

        uint256 amount = balanceOf(msg.sender);

        // First we reset the balance of the user to zero.
        decreaseBalance(msg.sender, amount);

        // Then we change the rebase state to non-rebasing.
        rebaseState[msg.sender] = RebaseOptions.NonRebasing;

        // Finally we set back the balance of the user. Which is now non-rebasing.
        increaseBalance(msg.sender, amount);
    }

    /**
     * @notice Returns the current rebasing index.
     * @return The current rebasing index.
     */
    function rebasingIndex() public view returns (uint256) {
        uint256 fromTimestamp = storedLastRebasingTimestamp;
        uint256 blockTimestamp = block.timestamp;

        uint256 multiplier = 1e27;

        // We iterate over the weeks from the last rebasing timestamp to the current timestamp.
        while (fromTimestamp < blockTimestamp) {
            uint256 week = fromTimestamp / 1 weeks;
            uint256 yield = yieldByWeek[week];
            uint256 toTimestamp = (week + 1) * 1 weeks;

            if (toTimestamp > blockTimestamp) {
                toTimestamp = blockTimestamp;
            }

            // skip weeks without yield
            if (yield == 0) {
                fromTimestamp = toTimestamp;

                continue;
            }

            uint256 deltaT = toTimestamp - fromTimestamp;

            // skip if this week has already been processed
            if (deltaT == 0) {
                fromTimestamp = toTimestamp;

                continue;
            }

            // NOTE: deltaT cannot be larger than 1 week, so rpow is safe to use
            multiplier = multiplier.mulDiv((1e27 + yield).rpow(deltaT, 1e27), 1e27);

            fromTimestamp = toTimestamp;
        }

        return storedRebasingIndex.mulDiv(multiplier, 1e27);
    }

    function updateRebasingIndex() internal {
        storedRebasingIndex = rebasingIndex();
        storedLastRebasingTimestamp = block.timestamp;
    }

    function decreaseBalance(address account, uint256 balanceChange) internal {
        RebaseOptions state = rebaseState[account];

        if (state == RebaseOptions.Rebasing) {
            uint256 currentIndex = rebasingIndex();
            uint256 diff = balanceChange.mulDivUp(1e36, currentIndex);

            rebasingBalanceOf[account] -= diff;
            rebasingTotalSupply -= diff;

            // NOTE/TODO: Because of YieldDelegation we need to check if the balance is still positive
        } else {
            // NOTE: NonRebasing and YieldDelegation are treated the same

            nonRebasingBalanceOf[account] -= balanceChange;
            nonRebasingTotalSupply -= balanceChange;
        }
    }

    function increaseBalance(address account, uint256 balanceChange) internal {
        RebaseOptions state = rebaseState[account];

        if (state == RebaseOptions.Rebasing) {
            uint256 currentIndex = rebasingIndex();
            // NOTE: we round up, so that the correct amount is added to the rebasing balance
            uint256 diff = balanceChange.mulDivUp(1e36, currentIndex);

            rebasingBalanceOf[account] += diff;
            rebasingTotalSupply += diff;
        } else {
            // NOTE: NonRebasing and YieldDelegation are treated the same

            nonRebasingBalanceOf[account] += balanceChange;
            nonRebasingTotalSupply += balanceChange;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a minter
    /// @param minter The address of the new minter
    function addMinter(address minter) public onlyOwner {
        require(!minters[minter], MinterAlreadyAdded(minter));
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    /// @notice Removes a minter
    /// @param minter The address of the minter to remove
    function removeMinter(address minter) public onlyOwner {
        require(minters[minter], MinterNotAdded(minter));
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    /// @notice Mints shares for a given address
    /// @param to The address to mint shares for
    /// @param value The amount of shares to mint
    function mint(address to, uint256 value) public onlyMinter {
        updateRebasingIndex();

        increaseBalance(to, value);

        emit Transfer(address(0), to, value);
    }

    /// @notice Burns shares from a given address
    /// @param from The address to burn shares from
    /// @param value The amount of shares to burn
    function burn(address from, uint256 value) public onlyMinter {
        updateRebasingIndex();

        decreaseBalance(from, value);

        emit Transfer(from, address(0), value);
    }

    /// @notice Allows a minter to use allowance
    /// @param owner The address of the owner
    /// @param spender The address of the spender
    /// @param value The amount of allowance to use
    /// @dev This should be called when allowance should be used
    function useAllowance(address owner, address spender, uint256 value) public onlyMinter {
        uint256 allowed = allowance[owner][spender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) {
            // @dev will error if not enough allowance due to underflow
            allowance[owner][spender] = allowed - value;
        }
    }

    modifier onlyMinter() {
        _onlyMinter();
        _;
    }

    function _onlyMinter() internal {
        require(minters[msg.sender], MinterUnauthorized(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD SETTER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the yield setter
    /// @param newYieldSetter The new yield setter
    function setYieldSetter(address newYieldSetter) external onlyOwner {
        yieldSetter = newYieldSetter;
        emit YieldSetterUpdated(newYieldSetter);
    }

    /// @notice Sets the yield for a given week
    /// @param yield The yield to set
    /// @param week The week to set the yield for
    function setYield(uint256 yield, uint256 week) external {
        require(msg.sender == yieldSetter, YieldSetterUnauthorized(msg.sender));

        yieldByWeek[week] = yield;
        emit YieldSet(week, yield);
    }
}
