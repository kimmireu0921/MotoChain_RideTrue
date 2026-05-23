// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  VINToken
 * @notice MotoChain identity layer — one ERC-721 per motorcycle VIN.
 *
 *  Mechanic trust model (answers whitepaper feedback):
 *    - Registration requires a MOTO token stake (no licence needed — stake = credential).
 *    - Tier stake amounts: Basic 100 MOTO · Verified 500 MOTO · Expert 2 000 MOTO.
 *    - Admin can slash a mechanic: their staked MOTO is burned and they are deactivated.
 *    - Mechanic earns 10 MOTO per service record the rider confirms.
 *
 *  Service record co-sign flow:
 *    1. Mechanic calls logService()     → creates a PendingRecord.
 *    2. VIN owner calls confirmService() → moves it to permanent history,
 *       updates on-chain odometer, mints MOTO reward to mechanic.
 */
contract VINToken is ERC721, Ownable {

    // ── External interface ────────────────────────────────────────────────────

    interface IMOTOToken {
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
        function burn(uint256 amount) external;
        function mint(address to, uint256 amount) external;
        function balanceOf(address account) external view returns (uint256);
    }

    // ── Types ─────────────────────────────────────────────────────────────────

    struct VINData {
        string  vin;
        string  make;
        string  model;
        uint16  year;
        uint32  odometer;
        address originalOwner;
        uint256 mintedAt;
    }

    struct ServiceRecord {
        address mechanic;
        string  shopName;
        uint256 timestamp;
        string  serviceType;
        string  description;
        uint32  odometer;
    }

    struct PendingRecord {
        address mechanic;
        string  shopName;
        uint256 timestamp;
        string  serviceType;
        string  description;
        uint32  odometer;
        bool    confirmed;
    }

    struct MechanicInfo {
        string  shopName;
        uint8   tier;           // 0 = Basic, 1 = Verified, 2 = Expert
        uint256 registeredAt;
        bool    isActive;
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    // MOTO staked per mechanic tier at registration time.
    uint256[3] public tierStakeAmounts = [
        100  * 1e18,   // Basic
        500  * 1e18,   // Verified
        2_000 * 1e18   // Expert
    ];

    // MOTO minted to the mechanic each time a rider confirms their service record.
    uint256 public constant MECHANIC_SERVICE_REWARD = 10 * 1e18;

    // ── Storage ───────────────────────────────────────────────────────────────

    uint256 private _nextTokenId = 1;

    IMOTOToken public motoToken;

    mapping(uint256 => VINData)         public  vinData;
    mapping(string  => bool)            public  vinMinted;
    mapping(string  => uint256)         public  vinToTokenId;
    mapping(uint256 => ServiceRecord[]) private _serviceHistory;
    mapping(uint256 => PendingRecord[]) private _pending;
    mapping(address => MechanicInfo)    public  mechanics;
    mapping(address => uint256)         public  mechStakes;    // MOTO held in escrow
    mapping(address => uint16)          public  safetyScores;  // 0-100

    // ── Events ────────────────────────────────────────────────────────────────

    event VINMinted(uint256 indexed tokenId, string vin, address indexed owner);
    event VINTransferred(
        uint256 indexed tokenId, string vin,
        address indexed from, address indexed to, uint256 timestamp
    );
    event MechanicRegistered(address indexed mechanic, string shopName, uint8 tier);
    event MechanicSlashed(address indexed mechanic, uint256 stakeSlashed);
    event MechanicDeregistered(address indexed mechanic, uint256 stakeReturned);
    event ServicePending(
        uint256 indexed tokenId, string vin,
        address indexed mechanic, string serviceType,
        uint256 pendingIdx, uint256 timestamp
    );
    event ServiceConfirmed(
        uint256 indexed tokenId, string vin,
        uint256 pendingIdx, uint256 timestamp
    );
    event ServiceLogged(
        uint256 indexed tokenId, string vin,
        address indexed mechanic, string serviceType, uint256 timestamp
    );
    event ServiceRewardMinted(address indexed mechanic, uint256 amount, uint256 indexed tokenId);
    event SafetyScoreSet(address indexed rider, uint16 score);
    event MotoTokenSet(address indexed motoToken);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor() ERC721("MotoChain VIN Token", "VIN") Ownable(msg.sender) {}

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setMotoToken(address _motoToken) external onlyOwner {
        motoToken = IMOTOToken(_motoToken);
        emit MotoTokenSet(_motoToken);
    }

    function setTierStake(uint8 tier, uint256 amount) external onlyOwner {
        require(tier <= 2, "Invalid tier");
        tierStakeAmounts[tier] = amount;
    }

    function setSafetyScore(address rider, uint16 score) external onlyOwner {
        require(score <= 100, "Score must be 0-100");
        safetyScores[rider] = score;
        emit SafetyScoreSet(rider, score);
    }

    // ── VIN Minting ───────────────────────────────────────────────────────────

    function mintVIN(
        string calldata vin,
        string calldata make,
        string calldata model,
        uint16  year,
        uint32  odometer
    ) external returns (uint256) {
        require(bytes(vin).length == 17, "VIN must be 17 characters");
        require(!vinMinted[vin], "VIN already registered on-chain");

        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        vinData[tokenId] = VINData({
            vin:           vin,
            make:          make,
            model:         model,
            year:          year,
            odometer:      odometer,
            originalOwner: msg.sender,
            mintedAt:      block.timestamp
        });
        vinMinted[vin]    = true;
        vinToTokenId[vin] = tokenId;

        emit VINMinted(tokenId, vin, msg.sender);
        return tokenId;
    }

    // ── VIN Transfer ──────────────────────────────────────────────────────────

    function transferVIN(uint256 tokenId, address to) external {
        require(ownerOf(tokenId) == msg.sender, "Not the token owner");
        require(to != address(0), "Cannot transfer to zero address");
        _transfer(msg.sender, to, tokenId);
        emit VINTransferred(tokenId, vinData[tokenId].vin, msg.sender, to, block.timestamp);
    }

    // ── Mechanic Registration ─────────────────────────────────────────────────

    /**
     * @notice Register as a mechanic. If MOTO token is configured, the caller
     *         must have approved this contract to spend their tier's stake amount
     *         before calling this function.
     *
     *         Stake-as-credential: no licence check required. Bad actors lose
     *         their stake when slashed by the admin.
     */
    function registerMechanic(string calldata shopName, uint8 tier) external {
        require(tier <= 2, "Invalid tier: 0=Basic 1=Verified 2=Expert");
        require(!mechanics[msg.sender].isActive, "Already registered");

        uint256 stakeRequired = tierStakeAmounts[tier];
        if (address(motoToken) != address(0) && stakeRequired > 0) {
            require(
                motoToken.transferFrom(msg.sender, address(this), stakeRequired),
                "MOTO stake transfer failed — approve VINToken first"
            );
            mechStakes[msg.sender] = stakeRequired;
        }

        mechanics[msg.sender] = MechanicInfo({
            shopName:     shopName,
            tier:         tier,
            registeredAt: block.timestamp,
            isActive:     true
        });
        emit MechanicRegistered(msg.sender, shopName, tier);
    }

    /**
     * @notice Admin slashes a mechanic for misconduct: deactivates them and
     *         burns their staked MOTO.
     */
    function slashMechanic(address mechanic) external onlyOwner {
        require(mechanics[mechanic].isActive, "Not an active mechanic");
        uint256 stake = mechStakes[mechanic];
        mechanics[mechanic].isActive = false;
        mechStakes[mechanic] = 0;
        if (address(motoToken) != address(0) && stake > 0) {
            motoToken.burn(stake);  // VINToken burns its own MOTO holding
        }
        emit MechanicSlashed(mechanic, stake);
    }

    /**
     * @notice Mechanic voluntarily deregisters; stake is returned.
     */
    function deregisterMechanic() external {
        require(mechanics[msg.sender].isActive, "Not an active mechanic");
        uint256 stake = mechStakes[msg.sender];
        mechanics[msg.sender].isActive = false;
        mechStakes[msg.sender] = 0;
        if (address(motoToken) != address(0) && stake > 0) {
            motoToken.transfer(msg.sender, stake);
        }
        emit MechanicDeregistered(msg.sender, stake);
    }

    // ── Service Records (co-sign flow) ────────────────────────────────────────

    /**
     * @notice Mechanic submits a service record. Sits as pending until the
     *         VIN owner confirms. Odometer must not decrease.
     */
    function logService(
        uint256 tokenId,
        string  calldata serviceType,
        string  calldata description,
        uint32  odometer
    ) external {
        require(mechanics[msg.sender].isActive, "Not a registered mechanic");
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        require(odometer >= vinData[tokenId].odometer, "Odometer cannot decrease");

        uint256 idx = _pending[tokenId].length;
        _pending[tokenId].push(PendingRecord({
            mechanic:    msg.sender,
            shopName:    mechanics[msg.sender].shopName,
            timestamp:   block.timestamp,
            serviceType: serviceType,
            description: description,
            odometer:    odometer,
            confirmed:   false
        }));

        emit ServicePending(
            tokenId, vinData[tokenId].vin,
            msg.sender, serviceType, idx, block.timestamp
        );
    }

    /**
     * @notice VIN owner confirms a pending service record. Moves it into
     *         permanent history, updates on-chain odometer, and mints a
     *         MOTO reward to the mechanic.
     */
    function confirmService(uint256 tokenId, uint256 pendingIdx) external {
        require(ownerOf(tokenId) == msg.sender, "Only VIN owner can confirm");
        require(pendingIdx < _pending[tokenId].length, "Index out of range");

        PendingRecord storage pr = _pending[tokenId][pendingIdx];
        require(!pr.confirmed, "Already confirmed");
        require(
            pr.odometer >= vinData[tokenId].odometer,
            "Odometer conflict — another record updated the counter first"
        );

        pr.confirmed = true;

        _serviceHistory[tokenId].push(ServiceRecord({
            mechanic:    pr.mechanic,
            shopName:    pr.shopName,
            timestamp:   pr.timestamp,
            serviceType: pr.serviceType,
            description: pr.description,
            odometer:    pr.odometer
        }));

        vinData[tokenId].odometer = pr.odometer;

        emit ServiceConfirmed(tokenId, vinData[tokenId].vin, pendingIdx, block.timestamp);
        emit ServiceLogged(
            tokenId, vinData[tokenId].vin,
            pr.mechanic, pr.serviceType, pr.timestamp
        );

        // Mint MOTO reward to the mechanic for the confirmed service.
        if (address(motoToken) != address(0)) {
            motoToken.mint(pr.mechanic, MECHANIC_SERVICE_REWARD);
            emit ServiceRewardMinted(pr.mechanic, MECHANIC_SERVICE_REWARD, tokenId);
        }
    }

    // ── View Functions ────────────────────────────────────────────────────────

    function getServiceHistory(uint256 tokenId)
        external view returns (ServiceRecord[] memory)
    {
        return _serviceHistory[tokenId];
    }

    function getPendingRecords(uint256 tokenId)
        external view returns (PendingRecord[] memory)
    {
        return _pending[tokenId];
    }

    function getTokenIdByVIN(string calldata vin)
        external view returns (uint256)
    {
        return vinToTokenId[vin];
    }

    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function getMechanicStake(address mechanic) external view returns (uint256) {
        return mechStakes[mechanic];
    }
}
