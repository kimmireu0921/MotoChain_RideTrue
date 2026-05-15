// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract VINToken is ERC721 {
    uint256 private _nextTokenId = 1;

    struct VINData {
        string vin;
        string make;
        string model;
        uint16 year;
        uint32 odometer;
        address originalOwner;
        uint256 mintedAt;
    }

    struct ServiceRecord {
        address mechanic;
        string shopName;
        uint256 timestamp;
        string serviceType;
        string description;
        uint32 odometer;
    }

    struct MechanicInfo {
        string shopName;
        uint8 tier;       // 0=Basic, 1=Verified, 2=Expert
        uint256 registeredAt;
        bool isActive;
    }

    mapping(uint256 => VINData)          public vinData;
    mapping(string  => bool)             public vinMinted;
    mapping(string  => uint256)          public vinToTokenId;
    mapping(uint256 => ServiceRecord[])  private _serviceHistory;
    mapping(address => MechanicInfo)     public mechanics;

    event VINMinted(uint256 indexed tokenId, string vin, address indexed owner);
    event MechanicRegistered(address indexed mechanic, string shopName, uint8 tier);
    event ServiceLogged(uint256 indexed tokenId, string vin, address indexed mechanic, string serviceType, uint256 timestamp);

    constructor() ERC721("MotoChain VIN Token", "VIN") {}

    function mintVIN(
        string calldata vin,
        string calldata make,
        string calldata model,
        uint16 year,
        uint32 odometer
    ) external returns (uint256) {
        require(bytes(vin).length == 17, "VIN must be 17 characters");
        require(!vinMinted[vin], "VIN already registered on-chain");

        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        vinData[tokenId] = VINData({
            vin: vin, make: make, model: model, year: year,
            odometer: odometer, originalOwner: msg.sender, mintedAt: block.timestamp
        });
        vinMinted[vin] = true;
        vinToTokenId[vin] = tokenId;

        emit VINMinted(tokenId, vin, msg.sender);
        return tokenId;
    }

    function registerMechanic(string calldata shopName, uint8 tier) external {
        require(tier <= 2, "Invalid tier: 0=Basic 1=Verified 2=Expert");
        require(!mechanics[msg.sender].isActive, "Already registered");
        mechanics[msg.sender] = MechanicInfo({
            shopName: shopName, tier: tier,
            registeredAt: block.timestamp, isActive: true
        });
        emit MechanicRegistered(msg.sender, shopName, tier);
    }

    function logService(
        uint256 tokenId,
        string calldata serviceType,
        string calldata description,
        uint32 odometer
    ) external {
        require(mechanics[msg.sender].isActive, "Not a registered mechanic");
        require(_ownerOf(tokenId) != address(0), "Token does not exist");

        _serviceHistory[tokenId].push(ServiceRecord({
            mechanic:    msg.sender,
            shopName:    mechanics[msg.sender].shopName,
            timestamp:   block.timestamp,
            serviceType: serviceType,
            description: description,
            odometer:    odometer
        }));

        emit ServiceLogged(tokenId, vinData[tokenId].vin, msg.sender, serviceType, block.timestamp);
    }

    function getServiceHistory(uint256 tokenId)
        external view returns (ServiceRecord[] memory)
    {
        return _serviceHistory[tokenId];
    }

    function getTokenIdByVIN(string calldata vin)
        external view returns (uint256)
    {
        return vinToTokenId[vin];
    }

    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }
}
