// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/tokens/IVeSlokToken.sol";

contract Presale is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 allocation; // amount taken into account to obtain SLOK (amount spent + discount)
        uint256 contribution; // amount spent to buy SLOK
        uint256 discount; // discount % for this user
        uint256 discountEligibleAmount; // max contribution amount eligible for a discount
        address ref; // referral for this account
        uint256 refEarnings; // referral earnings made by this account
        uint256 claimedRefEarnings; // amount of claimed referral earnings
        bool hasClaimed; // has already claimed its allocation
    }

    IERC20 public immutable SLOK; // SLOK token contract
    IVeSlokToken public immutable VeSLOK; // veSLOK token contract
    IERC20 public immutable SALE_TOKEN; // token used to participate
    IERC20 public immutable LP_TOKEN; // SLOK LP address

    uint256 public immutable START_TIME; // sale start time
    uint256 public immutable END_TIME; // sale end time

    uint256 public constant REFERRAL_SHARE = 3; // 3%

    mapping(address => UserInfo) public userInfo; // buyers and referrers info
    uint256 public totalRaised; // raised amount, does not take into account referral shares
    uint256 public totalAllocation; // takes into account discounts

    uint256 public constant MAX_SLOK_TO_DISTRIBUTE = 15000 ether; // max SLOK amount to distribute during the sale

    // (=300,000 USDC, with USDC having 6 decimals ) amount to reach to distribute max SLOK amount
    uint256 public constant MIN_TOTAL_RAISED_FOR_MAX_SLOK = 300000000000;

    uint256 public constant VeSLOK_SHARE = 35; // ~1/3 of SLOK bought is returned as veSLOK

    address public immutable treasury; // treasury multisig, will receive raised amount

    bool public unsoldTokensBurnt;

    constructor(
        IERC20 slokToken,
        IVeSlokToken veSlokToken,
        IERC20 saleToken,
        IERC20 lpToken,
        uint256 startTime,
        uint256 endTime,
        address treasury_
    ) {
        require(startTime < endTime, "invalid dates");
        require(treasury_ != address(0), "invalid treasury");

        SLOK = slokToken;
        VeSLOK = veSlokToken;
        SALE_TOKEN = saleToken;
        LP_TOKEN = lpToken;
        START_TIME = startTime;
        END_TIME = endTime;
        treasury = treasury_;
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event Buy(address indexed user, uint256 amount);
    event ClaimRefEarnings(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 slokAmount, uint256 veSlokAmount);
    event NewRefEarning(address referrer, uint256 amount);
    event DiscountUpdated();

    event EmergencyWithdraw(address token, uint256 amount);

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/

    /**
     * @dev Check whether the sale is currently active
     *
     * Will be marked as inactive if SLOK has not been deposited into the contract
     */
    modifier isSaleActive() {
        require(
            hasStarted() &&
                !hasEnded() &&
                SLOK.balanceOf(address(this)) >= MAX_SLOK_TO_DISTRIBUTE,
            "isActive: sale is not active"
        );
        _;
    }

    /**
     * @dev Check whether users can claim their purchased SLOK
     *
     * Sale must have ended, and LP tokens must have been formed
     */
    modifier isClaimable() {
        require(hasEnded(), "isClaimable: sale has not ended");
        require(LP_TOKEN.totalSupply() > 0, "isClaimable: no LP tokens");
        _;
    }

    /**************************************************/
    /****************** PUBLIC VIEWS ******************/
    /**************************************************/

    /**
     * @dev Get remaining duration before the end of the sale
     */
    function getRemainingTime() external view returns (uint256) {
        if (hasEnded()) return 0;
        return END_TIME.sub(_currentBlockTimestamp());
    }

    /**
     * @dev Returns whether the sale has already started
     */
    function hasStarted() public view returns (bool) {
        return _currentBlockTimestamp() >= START_TIME;
    }

    /**
     * @dev Returns whether the sale has already ended
     */
    function hasEnded() public view returns (bool) {
        return END_TIME <= _currentBlockTimestamp();
    }

    /**
     * @dev Returns the amount of SLOK to be distributed based on the current total raised
     */
    function slokToDistribute() public view returns (uint256) {
        if (MIN_TOTAL_RAISED_FOR_MAX_SLOK > totalRaised) {
            return
                MAX_SLOK_TO_DISTRIBUTE.mul(totalRaised).div(
                    MIN_TOTAL_RAISED_FOR_MAX_SLOK
                );
        }
        return MAX_SLOK_TO_DISTRIBUTE;
    }

    /**
     * @dev Get user share times 1e5
     */
    function getExpectedClaimAmounts(
        address account
    ) public view returns (uint256 slokAmount, uint256 veSlokAmount) {
        if (totalAllocation == 0) return (0, 0);

        UserInfo memory user = userInfo[account];
        uint256 totalSlokAmount = user.allocation.mul(slokToDistribute()).div(
            totalAllocation
        );

        veSlokAmount = totalSlokAmount.mul(VeSLOK_SHARE).div(100);
        slokAmount = totalSlokAmount.sub(veSlokAmount);
    }

    /****************************************************************/
    /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
    /****************************************************************/

    /**
     * @dev Purchase an allocation for the sale for a value of "amount" SALE_TOKEN, referred by "referralAddress"
     */
    function buy(
        uint256 amount,
        address referralAddress
    ) external isSaleActive nonReentrant {
        require(amount > 0, "buy: zero amount");

        uint256 participationAmount = amount;
        UserInfo storage user = userInfo[msg.sender];

        // handle user's referral
        if (
            user.allocation == 0 &&
            user.ref == address(0) &&
            referralAddress != address(0) &&
            referralAddress != msg.sender
        ) {
            // If first buy, and does not have any ref already set
            user.ref = referralAddress;
        }
        referralAddress = user.ref;

        if (referralAddress != address(0)) {
            UserInfo storage referrer = userInfo[referralAddress];

            // compute and send referrer share
            uint256 refShareAmount = REFERRAL_SHARE.mul(amount).div(100);
            SALE_TOKEN.safeTransferFrom(
                msg.sender,
                address(this),
                refShareAmount
            );

            referrer.refEarnings = referrer.refEarnings.add(refShareAmount);
            participationAmount = participationAmount.sub(refShareAmount);

            emit NewRefEarning(referralAddress, refShareAmount);
        }

        uint256 allocation = amount;
        if (
            user.discount > 0 && user.contribution < user.discountEligibleAmount
        ) {
            // Get eligible amount for the active user's discount
            uint256 discountEligibleAmount = user.discountEligibleAmount.sub(
                user.contribution
            );
            if (discountEligibleAmount > amount) {
                discountEligibleAmount = amount;
            }
            // Readjust user new allocation
            allocation = allocation.add(
                discountEligibleAmount.mul(user.discount).div(100)
            );
        }

        // update raised amounts
        user.contribution = user.contribution.add(amount);
        totalRaised = totalRaised.add(amount);

        // update allocations
        user.allocation = user.allocation.add(allocation);
        totalAllocation = totalAllocation.add(allocation);

        emit Buy(msg.sender, amount);
        // transfer contribution to treasury
        SALE_TOKEN.safeTransferFrom(msg.sender, treasury, participationAmount);
    }

    /**
     * @dev Claim referral earnings
     */
    function claimRefEarnings() public {
        UserInfo storage user = userInfo[msg.sender];
        uint256 toClaim = user.refEarnings.sub(user.claimedRefEarnings);

        if (toClaim > 0) {
            user.claimedRefEarnings = user.claimedRefEarnings.add(toClaim);

            emit ClaimRefEarnings(msg.sender, toClaim);
            SALE_TOKEN.safeTransfer(msg.sender, toClaim);
        }
    }

    /**
     * @dev Claim purchased SLOK during the sale
     */
    function claim() external isClaimable {
        UserInfo storage user = userInfo[msg.sender];

        require(
            totalAllocation > 0 && user.allocation > 0,
            "claim: zero allocation"
        );
        require(!user.hasClaimed, "claim: already claimed");
        user.hasClaimed = true;

        (uint256 slokAmount, uint256 veSlokAmount) = getExpectedClaimAmounts(
            msg.sender
        );

        emit Claim(msg.sender, slokAmount, veSlokAmount);

        // approve SLOK conversion to veSLOK
        if (SLOK.allowance(address(this), address(VeSLOK)) < veSlokAmount) {
            SLOK.safeApprove(address(VeSLOK), 0);
            SLOK.safeApprove(address(VeSLOK), type(uint256).max);
        }

        // send SLOK and veSLOK allocations
        if (veSlokAmount > 0) VeSLOK.convertTo(veSlokAmount, msg.sender);
        _safeClaimTransfer(msg.sender, slokAmount);
    }

    /****************************************************************/
    /********************** OWNABLE FUNCTIONS  **********************/
    /****************************************************************/

    struct DiscountSettings {
        address account;
        uint256 discount;
        uint256 eligibleAmount;
    }

    /**
     * @dev Assign custom discounts, used for v1 users
     *
     * Based on saved v1 tokens amounts in our snapshot
     */
    function setUsersDiscount(
        DiscountSettings[] calldata users
    ) public onlyOwner {
        for (uint256 i = 0; i < users.length; ++i) {
            DiscountSettings memory userDiscount = users[i];
            UserInfo storage user = userInfo[userDiscount.account];
            require(userDiscount.discount <= 35, "discount too high");
            user.discount = userDiscount.discount;
            user.discountEligibleAmount = userDiscount.eligibleAmount;
        }

        emit DiscountUpdated();
    }

    /********************************************************/
    /****************** /!\ EMERGENCY ONLY ******************/
    /********************************************************/

    /**
     * @dev Failsafe
     */
    function emergencyWithdrawFunds(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(token, amount);
    }

    /**
     * @dev Burn unsold SLOK tokens if MIN_TOTAL_RAISED_FOR_MAX_SLOK has not been reached
     *
     * Must only be called by the owner
     */
    function burnUnsoldTokens() external onlyOwner {
        require(hasEnded(), "burnUnsoldTokens: presale has not ended");
        require(!unsoldTokensBurnt, "burnUnsoldTokens: already burnt");

        uint256 totalSold = slokToDistribute();
        require(
            totalSold < MAX_SLOK_TO_DISTRIBUTE,
            "burnUnsoldTokens: no token to burn"
        );

        unsoldTokensBurnt = true;
        SLOK.transfer(
            0x000000000000000000000000000000000000dEaD,
            MAX_SLOK_TO_DISTRIBUTE.sub(totalSold)
        );
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/

    /**
     * @dev Safe token transfer function, in case rounding error causes contract to not have enough tokens
     */
    function _safeClaimTransfer(address to, uint256 amount) internal {
        uint256 slokBalance = SLOK.balanceOf(address(this));
        bool transferSuccess = false;

        if (amount > slokBalance) {
            transferSuccess = SLOK.transfer(to, slokBalance);
        } else {
            transferSuccess = SLOK.transfer(to, amount);
        }

        require(transferSuccess, "safeClaimTransfer: Transfer failed");
    }

    /**
     * @dev Utility function to get the current block timestamp
     */
    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
