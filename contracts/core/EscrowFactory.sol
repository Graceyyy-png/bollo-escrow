// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Escrow.sol";

contract EscrowFactory {
    address[] public escrows;
    mapping(address => address[]) public userEscrows;
    
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount
    );
    
    function createEscrow(
        address payable _seller,
        address payable _arbiter,
        uint256 _amount
    ) external returns (address) {
        Escrow newEscrow = new Escrow(
            payable(msg.sender),
            _seller,
            _arbiter,
            _amount
        );
        
        address escrowAddress = address(newEscrow);
        escrows.push(escrowAddress);
        userEscrows[msg.sender].push(escrowAddress);
        userEscrows[_seller].push(escrowAddress);
        userEscrows[_arbiter].push(escrowAddress);
        
        emit EscrowCreated(escrowAddress, msg.sender, _seller, _arbiter, _amount);
        
        return escrowAddress;
    }
    
    function getEscrowCount() external view returns (uint256) {
        return escrows.length;
    }
    
    function getUserEscrows(address user) external view returns (address[] memory) {
        return userEscrows[user];
    }
    
    function getAllEscrows() external view returns (address[] memory) {
        return escrows;
    }
}