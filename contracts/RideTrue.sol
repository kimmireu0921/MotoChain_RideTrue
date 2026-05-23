// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  RideTrue
 * @notice Behavior-based insurance pool for MotoChain riders.
 *
 *  Demo note: premiums are paid in ETH (Sepolia testnet).
 *  Mainnet deployment would accept USDC via an ERC-20 approve + transferFrom flow.
 *
 *  MOTO tokenomics (answers whitepaper feedback):
 *    - Riders holding ≥ 1 000 MOTO receive a 20% premium discount automatically.
 *    - Each policy activation mints 50 MOTO to the rider (earning model).
 *    - Policy auto-lapse: anyone can call lapsePolicy() once coverageEnd passes.
 *
 *  Flow:
 *    1. Admin seeds the pool (seedPool).
 *    2. Admin sets rider safety scores (setSafetyScore).
 *    3. Rider calls activatePolicy(vinTokenId, planTier) with ETH premium.
 *       → If rider holds ≥ MOTO_DISCOUNT_THRESHOLD, only 80% of base price required.
 *       → 50 MOTO minted to rider as a participation reward.
 *    4. Rider calls submitClaim(description, requestedAmount) if an accident occurs.
 *    5. Admin approves or rejects each claim (approveClaim / rejectClaim).
 *    6. Anyone calls lapsePolicy(rider) once their 30-day window expires.
 */
contract RideTrue is Ownable {

    // ── Interfaces ────────────────────────────────────────────────────────────

    interface IVINToken {
        function ownerOf(uint256 tokenId) external view returns (address);
        function safetyScores(address rider) external view returns (uint16);
    }

    interface IMOTOToken {
        function balanceOf(address account) external view returns (uint256);
        function mint(address to, uint256 amount) external;
    }

    // ── Types ─────────────────────────────────────────────────────────────────

    enum PolicyStatus { Inactive, Active, Claimed, Lapsed }
    enum ClaimStatus  { Pending, Approved, Rejected }

    struct Policy {
        uint256      vinTokenId;
        uint8        planTier;       // 0 = Basic, 1 = Standard, 2 = Premium
        uint256      stakedAmount;   // ETH in wei
        uint256      startTime;
        uint256      coverageEnd;    // startTime + 30 days
        PolicyStatus status;
        uint16       safetyScore;    // snapshot at activation time
        bool         motoDiscounted; // whether MOTO discount was applied
    }

    struct Claim {
        address     rider;
        uint256     vinTokenId;
        string      description;
        uint256     timestamp;
        uint256     requestedAmount;
        ClaimStatus status;
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    // Riders holding at least this many MOTO get a 20% premium discount.
    uint256 public constant MOTO_DISCOUNT_THRESHOLD = 1_000 * 1e18;
    uint256 public constant MOTO_DISCOUNT_BPS       = 2_000;         // 20 %
    uint256 public constant POLICY_MOTO_REWARD      = 50  * 1e18;   // 50 MOTO per activation

    // ── State ─────────────────────────────────────────────────────────────────

    IVINToken  public vinContract;
    IMOTOToken public motoToken;

    uint256[3] public planPrices = [
        0.001 ether,   // Basic
        0.002 ether,   // Standard
        0.004 ether    // Premium
    ];
    string[3] public planNames = ["Basic", "Standard", "Premium"];

    mapping(address => Policy) public policies;
    mapping(address => uint16) public safetyScores;

    Claim[] private _claims;

    // ── Events ────────────────────────────────────────────────────────────────

    event PolicyActivated(
        address indexed rider,
        uint256 indexed vinTokenId,
        uint8   planTier,
        uint256 amount,
        uint16  safetyScore,
        bool    motoDiscounted
    );
    event PolicyLapsed(address indexed rider, uint256 indexed vinTokenId);
    event PolicyRewardMinted(address indexed rider, uint256 amount);
    event ClaimSubmitted(
        uint256 indexed claimId,
        address indexed rider,
        uint256 indexed vinTokenId,
        uint256 requestedAmount
    );
    event ClaimApproved(uint256 indexed claimId, address indexed rider, uint256 payout);
    event ClaimRejected(uint256 indexed claimId, address indexed rider);
    event SafetyScoreSet(address indexed rider, uint16 score);
    event PlanPriceUpdated(uint8 tier, uint256 newPrice);
    event MotoTokenSet(address indexed motoToken);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _vinContract) Ownable(msg.sender) {
        vinContract = IVINToken(_vinContract);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setMotoToken(address _motoToken) external onlyOwner {
        motoToken = IMOTOToken(_motoToken);
        emit MotoTokenSet(_motoToken);
    }

    function setSafetyScore(address rider, uint16 score) external onlyOwner {
        require(score <= 100, "Score must be 0-100");
        safetyScores[rider] = score;
        emit SafetyScoreSet(rider, score);
    }

    function setPlanPrice(uint8 tier, uint256 priceWei) external onlyOwner {
        require(tier <= 2, "Invalid tier");
        planPrices[tier] = priceWei;
        emit PlanPriceUpdated(tier, priceWei);
    }

    function seedPool() external payable onlyOwner {}

    // ── Policy Lifecycle ──────────────────────────────────────────────────────

    /**
     * @notice Activate a 30-day insurance policy for the given VIN token.
     * @param  vinTokenId  The MotoChain VIN NFT the rider owns.
     * @param  planTier    0 = Basic, 1 = Standard, 2 = Premium.
     *
     * Caller must send at least planPrices[planTier] ETH (or 80% of that if
     * they hold ≥ MOTO_DISCOUNT_THRESHOLD MOTO tokens).
     * 50 MOTO are minted to the rider as a participation reward.
     */
    function activatePolicy(uint256 vinTokenId, uint8 planTier) external payable {
        require(planTier <= 2, "Invalid plan tier");
        require(
            vinContract.ownerOf(vinTokenId) == msg.sender,
            "You do not own this VIN token"
        );
        require(
            policies[msg.sender].status != PolicyStatus.Active,
            "Policy already active"
        );

        uint256 basePrice  = planPrices[planTier];
        bool    discounted = _hasMotoDiscount(msg.sender);
        uint256 required   = discounted
            ? basePrice * (10_000 - MOTO_DISCOUNT_BPS) / 10_000
            : basePrice;

        require(msg.value >= required, "Insufficient premium");

        uint16 score = safetyScores[msg.sender] > 0
            ? safetyScores[msg.sender]
            : vinContract.safetyScores(msg.sender);

        policies[msg.sender] = Policy({
            vinTokenId:     vinTokenId,
            planTier:       planTier,
            stakedAmount:   msg.value,
            startTime:      block.timestamp,
            coverageEnd:    block.timestamp + 30 days,
            status:         PolicyStatus.Active,
            safetyScore:    score,
            motoDiscounted: discounted
        });

        emit PolicyActivated(msg.sender, vinTokenId, planTier, msg.value, score, discounted);

        // Mint MOTO participation reward to the rider.
        if (address(motoToken) != address(0)) {
            motoToken.mint(msg.sender, POLICY_MOTO_REWARD);
            emit PolicyRewardMinted(msg.sender, POLICY_MOTO_REWARD);
        }
    }

    /**
     * @notice Anyone can lapse an expired policy. This frees the rider to
     *         activate a new policy and keeps on-chain state accurate.
     */
    function lapsePolicy(address rider) external {
        Policy storage p = policies[rider];
        require(p.status == PolicyStatus.Active, "Policy not active");
        require(block.timestamp > p.coverageEnd, "Coverage not yet expired");
        p.status = PolicyStatus.Lapsed;
        emit PolicyLapsed(rider, p.vinTokenId);
    }

    // ── Claims ────────────────────────────────────────────────────────────────

    /**
     * @notice Submit an insurance claim. Caller must have an active policy.
     * @param  description     Human-readable description of the incident.
     * @param  requestedAmount ETH requested (must not exceed pool balance).
     */
    function submitClaim(
        string  calldata description,
        uint256 requestedAmount
    ) external {
        require(
            policies[msg.sender].status == PolicyStatus.Active,
            "No active policy"
        );
        require(
            requestedAmount <= address(this).balance,
            "Requested amount exceeds pool balance"
        );
        require(bytes(description).length > 0, "Description required");

        uint256 claimId = _claims.length;
        _claims.push(Claim({
            rider:           msg.sender,
            vinTokenId:      policies[msg.sender].vinTokenId,
            description:     description,
            timestamp:       block.timestamp,
            requestedAmount: requestedAmount,
            status:          ClaimStatus.Pending
        }));

        emit ClaimSubmitted(claimId, msg.sender, policies[msg.sender].vinTokenId, requestedAmount);
    }

    /**
     * @notice Admin approves a claim, transferring ETH to the rider.
     */
    function approveClaim(uint256 claimId) external onlyOwner {
        require(claimId < _claims.length, "Claim does not exist");
        Claim storage c = _claims[claimId];
        require(c.status == ClaimStatus.Pending, "Claim is not pending");
        require(policies[c.rider].status == PolicyStatus.Active, "Rider policy is not active");
        require(c.requestedAmount <= address(this).balance, "Insufficient pool funds");

        c.status = ClaimStatus.Approved;
        policies[c.rider].status = PolicyStatus.Claimed;

        (bool ok,) = payable(c.rider).call{value: c.requestedAmount}("");
        require(ok, "ETH transfer failed");

        emit ClaimApproved(claimId, c.rider, c.requestedAmount);
    }

    /**
     * @notice Admin rejects a pending claim.
     */
    function rejectClaim(uint256 claimId) external onlyOwner {
        require(claimId < _claims.length, "Claim does not exist");
        Claim storage c = _claims[claimId];
        require(c.status == ClaimStatus.Pending, "Claim is not pending");
        c.status = ClaimStatus.Rejected;
        emit ClaimRejected(claimId, c.rider);
    }

    // ── View ──────────────────────────────────────────────────────────────────

    function getPoolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getPolicy(address rider) external view returns (Policy memory) {
        return policies[rider];
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        require(claimId < _claims.length, "Claim does not exist");
        return _claims[claimId];
    }

    function getClaimsCount() external view returns (uint256) {
        return _claims.length;
    }

    function getPlanPrice(uint8 tier) external view returns (uint256) {
        require(tier <= 2, "Invalid tier");
        return planPrices[tier];
    }

    function getEffectivePrice(address rider, uint8 tier) external view returns (uint256 price, bool discounted) {
        require(tier <= 2, "Invalid tier");
        discounted = _hasMotoDiscount(rider);
        price = discounted
            ? planPrices[tier] * (10_000 - MOTO_DISCOUNT_BPS) / 10_000
            : planPrices[tier];
    }

    function getSafetyScore(address rider) external view returns (uint16) {
        return safetyScores[rider] > 0
            ? safetyScores[rider]
            : vinContract.safetyScores(rider);
    }

    function hasMotoDiscount(address rider) external view returns (bool) {
        return _hasMotoDiscount(rider);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _hasMotoDiscount(address rider) internal view returns (bool) {
        if (address(motoToken) == address(0)) return false;
        return motoToken.balanceOf(rider) >= MOTO_DISCOUNT_THRESHOLD;
    }

    receive() external payable {}
}
