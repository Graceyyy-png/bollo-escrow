// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Escrow.sol";

contract EscrowRegistry {
    struct EscrowInfo {
        address escrowAddress;
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 createdAt;
        string category;
        string description;
        bool isActive;
    }
    
    struct UserStats {
        uint256 totalEscrows;
        uint256 completedEscrows;
        uint256 cancelledEscrows;
        uint256 disputedEscrows;
        uint256 totalVolume;
        uint256 rating;
        uint256 ratingCount;
    }
    
    mapping(address => EscrowInfo) public escrows;
    mapping(address => UserStats) public userStats;
    mapping(address => address[]) public userEscrowHistory;
    mapping(string => address[]) public categoryEscrows;
    mapping(address => bool) public registeredArbiters;
    mapping(address => uint256) public arbiterFees;
    mapping(address => string) public arbiterSpecialties;
    
    address[] public allEscrows;
    address[] public activeEscrows;
    string[] public categories;
    address[] public arbiters;
    
    address public owner;
    uint256 public registrationFee;
    uint256 public totalEscrowVolume;
    uint256 public totalEscrowCount;
    
    event EscrowRegistered(
        address indexed escrowAddress,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount,
        string category
    );
    
    event EscrowCompleted(address indexed escrowAddress, uint256 amount);
    event EscrowCancelled(address indexed escrowAddress);
    event EscrowDisputed(address indexed escrowAddress);
    event ArbiterRegistered(address indexed arbiter, uint256 fee, string specialty);
    event ArbiterRemoved(address indexed arbiter);
    event UserRated(address indexed user, uint256 rating, address ratedBy);
    event CategoryAdded(string category);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }
    
    modifier onlyRegisteredArbiter() {
        require(registeredArbiters[msg.sender], "Only registered arbiter");
        _;
    }
    
    modifier validEscrow(address escrowAddress) {
        require(escrows[escrowAddress].escrowAddress != address(0), "Escrow not registered");
        _;
    }
    
    constructor() {
        owner = msg.sender;
        registrationFee = 0.001 ether;
        categories.push("General");
        categories.push("Digital Goods");
        categories.push("Physical Goods");
        categories.push("Services");
        categories.push("Real Estate");
        categories.push("Freelance");
    }
    
    function registerEscrow(
        address escrowAddress,
        address buyer,
        address seller,
        address arbiter,
        uint256 amount,
        string memory category,
        string memory description
    ) external payable {
        require(msg.value >= registrationFee, "Insufficient registration fee");
        require(escrows[escrowAddress].escrowAddress == address(0), "Escrow already registered");
        require(registeredArbiters[arbiter], "Arbiter not registered");
        
        escrows[escrowAddress] = EscrowInfo({
            escrowAddress: escrowAddress,
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            amount: amount,
            createdAt: block.timestamp,
            category: category,
            description: description,
            isActive: true
        });
        
        allEscrows.push(escrowAddress);
        activeEscrows.push(escrowAddress);
        userEscrowHistory[buyer].push(escrowAddress);
        userEscrowHistory[seller].push(escrowAddress);
        userEscrowHistory[arbiter].push(escrowAddress);
        categoryEscrows[category].push(escrowAddress);
        
        userStats[buyer].totalEscrows++;
        userStats[seller].totalEscrows++;
        userStats[buyer].totalVolume += amount;
        userStats[seller].totalVolume += amount;
        
        totalEscrowVolume += amount;
        totalEscrowCount++;
        
        emit EscrowRegistered(escrowAddress, buyer, seller, arbiter, amount, category);
    }
    
    function registerArbiter(
        address arbiter,
        uint256 feePercentage,
        string memory specialty
    ) external onlyOwner {
        require(!registeredArbiters[arbiter], "Arbiter already registered");
        require(feePercentage <= 1000, "Fee cannot exceed 10%");
        
        registeredArbiters[arbiter] = true;
        arbiterFees[arbiter] = feePercentage;
        arbiterSpecialties[arbiter] = specialty;
        arbiters.push(arbiter);
        
        emit ArbiterRegistered(arbiter, feePercentage, specialty);
    }
    
    function removeArbiter(address arbiter) external onlyOwner {
        require(registeredArbiters[arbiter], "Arbiter not registered");
        
        registeredArbiters[arbiter] = false;
        arbiterFees[arbiter] = 0;
        arbiterSpecialties[arbiter] = "";
        
        for (uint256 i = 0; i < arbiters.length; i++) {
            if (arbiters[i] == arbiter) {
                arbiters[i] = arbiters[arbiters.length - 1];
                arbiters.pop();
                break;
            }
        }
        
        emit ArbiterRemoved(arbiter);
    }
    
    function updateEscrowStatus(address escrowAddress, uint8 status) external validEscrow(escrowAddress) {
        Escrow escrow = Escrow(escrowAddress);
        require(
            msg.sender == escrow.buyer() || 
            msg.sender == escrow.seller() || 
            msg.sender == escrow.arbiter(),
            "Unauthorized"
        );
        
        EscrowInfo storage info = escrows[escrowAddress];
        
        if (status == 2) {
            userStats[info.buyer].completedEscrows++;
            userStats[info.seller].completedEscrows++;
            info.isActive = false;
            _removeFromActiveEscrows(escrowAddress);
            emit EscrowCompleted(escrowAddress, info.amount);
        } else if (status == 3) {
            userStats[info.buyer].cancelledEscrows++;
            userStats[info.seller].cancelledEscrows++;
            info.isActive = false;
            _removeFromActiveEscrows(escrowAddress);
            emit EscrowCancelled(escrowAddress);
        }
    }
    
    function reportDispute(address escrowAddress) external validEscrow(escrowAddress) {
        Escrow escrow = Escrow(escrowAddress);
        require(
            msg.sender == escrow.buyer() || 
            msg.sender == escrow.seller(),
            "Only parties can report disputes"
        );
        
        EscrowInfo storage info = escrows[escrowAddress];
        userStats[info.buyer].disputedEscrows++;
        userStats[info.seller].disputedEscrows++;
        
        emit EscrowDisputed(escrowAddress);
    }
    
    function rateUser(address user, uint256 rating) external {
        require(rating >= 1 && rating <= 5, "Rating must be between 1-5");
        require(user != msg.sender, "Cannot rate yourself");
        
        UserStats storage stats = userStats[user];
        uint256 totalRating = stats.rating * stats.ratingCount + rating;
        stats.ratingCount++;
        stats.rating = totalRating / stats.ratingCount;
        
        emit UserRated(user, rating, msg.sender);
    }
    
    function addCategory(string memory category) external onlyOwner {
        categories.push(category);
        emit CategoryAdded(category);
    }
    
    function setRegistrationFee(uint256 newFee) external onlyOwner {
        registrationFee = newFee;
    }
    
    function withdrawFees() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    function _removeFromActiveEscrows(address escrowAddress) internal {
        for (uint256 i = 0; i < activeEscrows.length; i++) {
            if (activeEscrows[i] == escrowAddress) {
                activeEscrows[i] = activeEscrows[activeEscrows.length - 1];
                activeEscrows.pop();
                break;
            }
        }
    }
    
    function getEscrowInfo(address escrowAddress) external view returns (EscrowInfo memory) {
        return escrows[escrowAddress];
    }
    
    function getUserStats(address user) external view returns (UserStats memory) {
        return userStats[user];
    }
    
    function getUserEscrows(address user) external view returns (address[] memory) {
        return userEscrowHistory[user];
    }
    
    function getEscrowsByCategory(string memory category) external view returns (address[] memory) {
        return categoryEscrows[category];
    }
    
    function getActiveEscrows() external view returns (address[] memory) {
        return activeEscrows;
    }
    
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }
    
    function getRegisteredArbiters() external view returns (address[] memory) {
        return arbiters;
    }
    
    function getArbiterInfo(address arbiter) external view returns (
        bool isRegistered,
        uint256 feePercentage,
        string memory specialty
    ) {
        return (
            registeredArbiters[arbiter],
            arbiterFees[arbiter],
            arbiterSpecialties[arbiter]
        );
    }
    
    function getCategories() external view returns (string[] memory) {
        return categories;
    }
    
    function getRegistryStats() external view returns (
        uint256 totalEscrows,
        uint256 activeEscrowCount,
        uint256 totalVolume,
        uint256 totalArbiters
    ) {
        return (
            totalEscrowCount,
            activeEscrows.length,
            totalEscrowVolume,
            arbiters.length
        );
    }
    
    function searchEscrowsByAmount(uint256 minAmount, uint256 maxAmount) external view returns (address[] memory) {
        address[] memory results = new address[](activeEscrows.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < activeEscrows.length; i++) {
            EscrowInfo memory info = escrows[activeEscrows[i]];
            if (info.amount >= minAmount && info.amount <= maxAmount) {
                results[count] = activeEscrows[i];
                count++;
            }
        }
        
        address[] memory filteredResults = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            filteredResults[i] = results[i];
        }
        
        return filteredResults;
    }
    
    function isEscrowRegistered(address escrowAddress) external view returns (bool) {
        return escrows[escrowAddress].escrowAddress != address(0);
    }
}