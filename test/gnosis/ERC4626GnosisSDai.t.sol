// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IBufferRouter } from "@balancer-v3-monorepo/interfaces/vault/IBufferRouter.sol";
import { IVault } from "@balancer-v3-monorepo/interfaces/vault/IVault.sol";

/**
 * @notice sDAI fork tests
 * @dev sDAI requires a special test due to its unusual behavior. On every deposit, the sDAI rate decreases (which
 * means, the wrapped token loses a bit of value) which could lead to a buffer that leaks value. There's no reason
 * to don't use this token in pools, but initialize the buffer and add liquidity to the buffer of this token with
 * caution.
 */
contract ERC4626GnosisSDaiTest is Test {
    using SafeERC20 for IERC20;

    uint128 internal constant MAX_UINT128 = type(uint128).max;
    uint256 internal constant BUFFER_MINIMUM_TOTAL_SUPPLY = 1e6;

    // Variables to be defined by setUpForkTestVariables().
    string internal network;
    uint256 internal blockNumber;
    IERC4626 internal wrapper;
    address internal underlyingDonor;
    uint256 internal amountToDonate;

    IBufferRouter internal bufferRouter;
    IVault internal vault;
    IPermit2 internal permit2;

    IERC20 internal underlyingToken;
    uint256 internal underlyingToWrappedFactor;

    address internal alice;
    address internal lp;
    address internal user;
    uint256 internal userInitialUnderlying;
    uint256 internal userInitialShares;

    uint256 internal constant MIN_DEPOSIT = 100;
    // Tolerance of 1 wei difference between convert/preview and actual operation.
    uint256 internal constant TOLERANCE = 1;

    function setUp() public virtual {
        setUpForkTestVariables();

        _configurePermit2AndBufferToNetwork();

        vm.label(address(wrapper), "wrapper");

        vm.createSelectFork({ blockNumber: blockNumber, urlOrAlias: network });

        underlyingToken = IERC20(wrapper.asset());
        vm.label(address(underlyingToken), "underlying");

        underlyingToWrappedFactor = 10 ** (wrapper.decimals() - IERC20Metadata(address(underlyingToken)).decimals());

        (user, ) = makeAddrAndKey("User");
        vm.label(user, "User");
        _initializeWallet(user);

        userInitialUnderlying = underlyingToken.balanceOf(user);
        userInitialShares = wrapper.balanceOf(user);

        (lp, ) = makeAddrAndKey("lp");
        vm.label(lp, "lp");
        _initializeWallet(lp);
        _setupAllowance(lp);

        (alice, ) = makeAddrAndKey("Alice");
        vm.label(alice, "Alice");
        _initializeWallet(alice);
        _setupAllowance(alice);
    }

    function setUpForkTestVariables() internal {
        network = "gnosis";

        // sDAI
        wrapper = IERC4626(0xaf204776c7245bF4147c2612BF6e5972Ee483701);
        // Donor of wxDAI
        underlyingDonor = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
        amountToDonate = 1e4 * 1e18;
    }

    function testPreConditions() public view {
        assertEq(userInitialUnderlying, amountToDonate / 2, "User balance of underlying is wrong.");
        assertEq(userInitialShares, wrapper.balanceOf(user), "User balance of shares is wrong.");
    }

    function testDeposit__Fork__Fuzz(uint256 amountToDeposit) public {
        amountToDeposit = bound(amountToDeposit, MIN_DEPOSIT, userInitialUnderlying);

        uint256 convertedShares = wrapper.convertToShares(amountToDeposit);
        uint256 previewedShares = wrapper.previewDeposit(amountToDeposit);

        uint256 balanceUnderlyingBefore = underlyingToken.balanceOf(user);
        uint256 balanceSharesBefore = wrapper.balanceOf(user);

        vm.startPrank(user);
        underlyingToken.forceApprove(address(wrapper), amountToDeposit);
        uint256 mintedShares = wrapper.deposit(amountToDeposit, user);
        vm.stopPrank();

        uint256 balanceUnderlyingAfter = underlyingToken.balanceOf(user);
        uint256 balanceSharesAfter = wrapper.balanceOf(user);

        assertEq(balanceUnderlyingAfter, balanceUnderlyingBefore - amountToDeposit, "Deposit is not EXACT_IN");
        assertEq(balanceSharesAfter, balanceSharesBefore + mintedShares, "Deposit minted shares do not match");
        assertApproxEqAbs(
            convertedShares,
            mintedShares,
            TOLERANCE,
            "Convert and actual operation difference is higher than tolerance"
        );
        assertApproxEqAbs(
            previewedShares,
            mintedShares,
            TOLERANCE,
            "Preview and actual operation difference is higher than tolerance"
        );
    }

    function testMint__Fork__Fuzz(uint256 amountToMint) public {
        // When user mints, a round up may occur and add some wei in the amount of underlying required to deposit.
        // This can cause the user to not have enough tokens to deposit.
        // So, the maximum amountToMint must be the initialShares (which is exactly the initialUnderlying, converted to
        // shares) less a tolerance.
        amountToMint = bound(
            amountToMint,
            MIN_DEPOSIT * underlyingToWrappedFactor,
            userInitialShares - (TOLERANCE * underlyingToWrappedFactor)
        );

        uint256 convertedUnderlying = wrapper.convertToAssets(amountToMint);
        uint256 previewedUnderlying = wrapper.previewMint(amountToMint);

        uint256 balanceUnderlyingBefore = underlyingToken.balanceOf(user);
        uint256 balanceSharesBefore = wrapper.balanceOf(user);

        vm.startPrank(user);
        underlyingToken.forceApprove(address(wrapper), previewedUnderlying);
        uint256 depositedUnderlying = wrapper.mint(amountToMint, user);
        vm.stopPrank();

        uint256 balanceUnderlyingAfter = underlyingToken.balanceOf(user);
        uint256 balanceSharesAfter = wrapper.balanceOf(user);

        assertEq(balanceUnderlyingAfter, balanceUnderlyingBefore - depositedUnderlying, "Mint is not EXACT_OUT");
        assertEq(balanceSharesAfter, balanceSharesBefore + amountToMint, "Mint shares do not match");
        assertApproxEqAbs(
            convertedUnderlying,
            depositedUnderlying,
            TOLERANCE,
            "Convert and actual operation difference is higher than tolerance"
        );
        assertApproxEqAbs(
            previewedUnderlying,
            depositedUnderlying,
            TOLERANCE,
            "Preview and actual operation difference is higher than tolerance"
        );
    }

    function testWithdraw__Fork__Fuzz(uint256 amountToWithdraw) public {
        // WARNING: Since the wrapper may leaked value, we use convertToAssets to predict the amount of underlying
        // tokens that we can withdraw. This is the main difference from the other ERC4626 tests.
        amountToWithdraw = bound(amountToWithdraw, MIN_DEPOSIT, wrapper.convertToAssets(userInitialShares) - TOLERANCE);

        uint256 convertedShares = wrapper.convertToShares(amountToWithdraw);
        uint256 previewedShares = wrapper.previewWithdraw(amountToWithdraw);

        uint256 balanceUnderlyingBefore = underlyingToken.balanceOf(user);
        uint256 balanceSharesBefore = wrapper.balanceOf(user);

        vm.startPrank(user);
        uint256 burnedShares = wrapper.withdraw(amountToWithdraw, user, user);
        vm.stopPrank();

        uint256 balanceUnderlyingAfter = underlyingToken.balanceOf(user);
        uint256 balanceSharesAfter = wrapper.balanceOf(user);

        assertEq(balanceUnderlyingAfter, balanceUnderlyingBefore + amountToWithdraw, "Withdraw is not EXACT_OUT");
        assertEq(balanceSharesAfter, balanceSharesBefore - burnedShares, "Withdraw burned shares do not match");
        assertApproxEqAbs(
            convertedShares,
            burnedShares,
            TOLERANCE,
            "Convert and actual operation difference is higher than tolerance"
        );
        assertApproxEqAbs(
            previewedShares,
            burnedShares,
            TOLERANCE,
            "Preview and actual operation difference is higher than tolerance"
        );
    }

    function testRedeem__Fork__Fuzz(uint256 amountToRedeem) public {
        // When user deposited to underlying, a round down may occur and remove some wei. So, makes sure
        // amountToWithdraw does not pass the amount deposited - a wei tolerance.
        amountToRedeem = bound(amountToRedeem, MIN_DEPOSIT * underlyingToWrappedFactor, userInitialShares - TOLERANCE);

        uint256 convertedAssets = wrapper.convertToAssets(amountToRedeem);
        uint256 previewedAssets = wrapper.previewRedeem(amountToRedeem);

        uint256 balanceUnderlyingBefore = underlyingToken.balanceOf(user);
        uint256 balanceSharesBefore = wrapper.balanceOf(user);

        vm.startPrank(user);
        uint256 withdrawnAssets = wrapper.redeem(amountToRedeem, user, user);
        vm.stopPrank();

        uint256 balanceUnderlyingAfter = underlyingToken.balanceOf(user);
        uint256 balanceSharesAfter = wrapper.balanceOf(user);

        assertEq(balanceUnderlyingAfter, balanceUnderlyingBefore + withdrawnAssets, "Redeem is not EXACT_IN");
        assertEq(balanceSharesAfter, balanceSharesBefore - amountToRedeem, "Redeem burned shares do not match");
        assertApproxEqAbs(
            convertedAssets,
            withdrawnAssets,
            TOLERANCE,
            "Convert and actual operation difference is higher than tolerance"
        );
        assertApproxEqAbs(
            previewedAssets,
            withdrawnAssets,
            TOLERANCE,
            "Preview and actual operation difference is higher than tolerance"
        );
    }

    function testAddLiquidityToBuffer__Fork__Fuzz(
        uint256 underlyingToInitialize,
        uint256 wrappedToInitialize,
        uint256 sharesToIssue
    ) public {
        underlyingToInitialize = bound(
            underlyingToInitialize,
            BUFFER_MINIMUM_TOTAL_SUPPLY,
            underlyingToken.balanceOf(lp) / 10
        );
        wrappedToInitialize = bound(wrappedToInitialize, BUFFER_MINIMUM_TOTAL_SUPPLY, wrapper.balanceOf(lp) / 10);
        sharesToIssue = bound(sharesToIssue, BUFFER_MINIMUM_TOTAL_SUPPLY, underlyingToken.balanceOf(lp) / 2);

        vm.prank(lp);
        bufferRouter.initializeBuffer(wrapper, underlyingToInitialize, wrappedToInitialize, 0);
        // Since the buffer burns part of the shares, we measure the total shares in the vault instead of using the
        // value returned by initializeBuffer;
        uint256 totalShares = vault.getBufferTotalShares(wrapper);

        vm.prank(lp);
        (uint256 underlyingDeposited, uint256 wrappedDeposited) = bufferRouter.addLiquidityToBuffer(
            wrapper,
            MAX_UINT128,
            MAX_UINT128,
            sharesToIssue
        );

        // Measures if the underlying and wrapped deposited on addLiquidityToBuffer are worth the same number of shares
        // than in initialized liquidity (or less).
        assertGe(
            underlyingDeposited,
            (sharesToIssue * underlyingToInitialize) / totalShares,
            "User spent less underlying tokens than it should"
        );
        assertGe(
            wrappedDeposited,
            (sharesToIssue * wrappedToInitialize) / totalShares,
            "User spent less wrapped tokens than it should"
        );
    }

    function testRemoveLiquidityFromBuffer__Fork__Fuzz(
        uint256 underlyingToInitialize,
        uint256 wrappedToInitialize,
        uint256 sharesToRemove
    ) public {
        underlyingToInitialize = bound(
            underlyingToInitialize,
            BUFFER_MINIMUM_TOTAL_SUPPLY,
            underlyingToken.balanceOf(lp) / 10
        );
        wrappedToInitialize = bound(wrappedToInitialize, BUFFER_MINIMUM_TOTAL_SUPPLY, wrapper.balanceOf(lp) / 10);

        vm.prank(lp);
        uint256 lpShares = bufferRouter.initializeBuffer(wrapper, underlyingToInitialize, wrappedToInitialize, 0);
        // Since the buffer burns part of the shares, we measure the total shares in the vault instead of using the
        // value returned by initializeBuffer;
        uint256 totalShares = vault.getBufferTotalShares(wrapper);

        sharesToRemove = bound(sharesToRemove, 0, lpShares);

        vm.prank(lp);
        (uint256 underlyingRemoved, uint256 wrappedRemoved) = vault.removeLiquidityFromBuffer(
            wrapper,
            sharesToRemove,
            0,
            0
        );

        // Measures if the underlying and wrapped received from `removeLiquidityFromBuffer` are worth the same number
        // of shares than in initialized liquidity (or less).
        assertLe(
            underlyingRemoved,
            (sharesToRemove * underlyingToInitialize) / totalShares,
            "User received more underlying tokens than it should"
        );
        assertLe(
            wrappedRemoved,
            (sharesToRemove * wrappedToInitialize) / totalShares,
            "User received more wrapped tokens than it should"
        );
    }

    function testAddAndRemoveLiquidityFromBuffer__Fork__Fuzz(
        uint256 underlyingToInitialize,
        uint256 wrappedToInitialize,
        uint256 sharesToIssueAndRemove
    ) public {
        uint256 initToAddFactor = 1000;
        underlyingToInitialize = bound(
            underlyingToInitialize,
            BUFFER_MINIMUM_TOTAL_SUPPLY,
            underlyingToken.balanceOf(lp) / initToAddFactor
        );
        wrappedToInitialize = bound(
            wrappedToInitialize,
            BUFFER_MINIMUM_TOTAL_SUPPLY,
            wrapper.balanceOf(lp) / initToAddFactor
        );

        vm.prank(lp);
        uint256 initShares = bufferRouter.initializeBuffer(wrapper, underlyingToInitialize, wrappedToInitialize, 0);

        sharesToIssueAndRemove = bound(sharesToIssueAndRemove, 0, initShares * initToAddFactor);

        vm.prank(alice);
        (uint256 underlyingDeposited, uint256 wrappedDeposited) = bufferRouter.addLiquidityToBuffer(
            wrapper,
            MAX_UINT128,
            MAX_UINT128,
            sharesToIssueAndRemove
        );

        vm.prank(alice);
        (uint256 underlyingRemoved, uint256 wrappedRemoved) = vault.removeLiquidityFromBuffer(
            wrapper,
            sharesToIssueAndRemove,
            0,
            0
        );

        assertLe(underlyingRemoved, underlyingDeposited, "User received more than they added");
        assertLe(wrappedRemoved, wrappedDeposited, "User received more than they added");
    }

    function testPreviewDepositRounding__Fork__Fuzz(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000e18);
        uint256 previewRoundDown = wrapper.previewDeposit(amount - 1);
        vm.assume(previewRoundDown > 0);
        previewRoundDown -= 1;
        uint256 preview = wrapper.previewDeposit(amount);
        assertLe(previewRoundDown, preview, "Preview round down does not match expectations");
    }

    function testPreviewMintRounding__Fork__Fuzz(uint256 amount) public view {
        amount = bound(amount, 0, 100_000_000e18);
        uint256 previewRoundUp = wrapper.previewMint(amount + 1) + 1;
        uint256 preview = wrapper.previewMint(amount);
        assertGe(previewRoundUp, preview, "Preview round up does not match expectations");
    }

    function testPreviewRedeemRounding__Fork__Fuzz(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000e18);
        uint256 previewRoundDown = wrapper.previewRedeem(amount - 1);
        vm.assume(previewRoundDown > 0);
        previewRoundDown -= 1;
        uint256 preview = wrapper.previewRedeem(amount);
        assertLe(previewRoundDown, preview, "Preview round down does not match expectations");
    }

    function testPreviewWithdrawRounding__Fork__Fuzz(uint256 amount) public view {
        amount = bound(amount, 0, 100_000_000e18);
        uint256 previewRoundUp = wrapper.previewWithdraw(amount + 1) + 1;
        uint256 preview = wrapper.previewWithdraw(amount);
        assertGe(previewRoundUp, preview, "Preview round up does not match expectations");
    }

    function _initializeWallet(address receiver) private {
        uint256 initialDeposit = amountToDonate / 2;

        vm.prank(underlyingDonor);
        underlyingToken.safeTransfer(receiver, amountToDonate);

        vm.startPrank(receiver);
        underlyingToken.forceApprove(address(wrapper), initialDeposit);
        wrapper.deposit(initialDeposit, receiver);
        vm.stopPrank();
    }

    function _setupAllowance(address sender) private {
        vm.startPrank(sender);
        underlyingToken.forceApprove(address(permit2), type(uint256).max);
        wrapper.approve(address(permit2), type(uint256).max);

        permit2.approve(address(underlyingToken), address(bufferRouter), type(uint160).max, type(uint48).max);
        permit2.approve(address(wrapper), address(bufferRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _configurePermit2AndBufferToNetwork() private {
        // Block Numbers are based on the deployment of BufferRouter.

        if (_compareStrings(network, "mainnet")) {
            blockNumber = 21339384;
            permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
            bufferRouter = IBufferRouter(0x9179C06629ef7f17Cb5759F501D89997FE0E7b45);
            vault = IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9);
        } else if (_compareStrings(network, "gnosis")) {
            blockNumber = 37377481;
            permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
            bufferRouter = IBufferRouter(0x86e67E115f96DF37239E0479441303De0de7bc2b);
            vault = IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9);
        } else if (_compareStrings(network, "sepolia")) {
            blockNumber = 7219291;
            permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
            bufferRouter = IBufferRouter(0xb5F3A41515457CC6E2716c62a011D260441CcfC9);
            vault = IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9);
        } else {
            revert("Network not registered in ERC4626WrapperBase.sol");
        }
    }

    function _compareStrings(string memory a, string memory b) private pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
