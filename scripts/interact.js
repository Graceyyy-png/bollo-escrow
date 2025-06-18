const hre = require("hardhat");

async function main() {
  const [buyer, seller, arbiter] = await hre.ethers.getSigners();
  
  console.log("Buyer address:", buyer.address);
  console.log("Seller address:", seller.address);
  console.log("Arbiter address:", arbiter.address);
  
  const EscrowFactory = await hre.ethers.getContractFactory("EscrowFactory");
  const escrowFactory = EscrowFactory.attach("ESCROW_FACTORY_ADDRESS_HERE");
  
  const amount = hre.ethers.utils.parseEther("1.0");
  
  console.log("\n--- Creating Escrow ---");
  const createTx = await escrowFactory.connect(buyer).createEscrow(
    seller.address,
    arbiter.address,
    amount
  );
  const receipt = await createTx.wait();
  
  const escrowCreatedEvent = receipt.events?.find(e => e.event === 'EscrowCreated');
  const escrowAddress = escrowCreatedEvent?.args?.escrowAddress;
  
  console.log("Escrow created at:", escrowAddress);
  
  const Escrow = await hre.ethers.getContractFactory("Escrow");
  const escrow = Escrow.attach(escrowAddress);
  
  console.log("\n--- Depositing Payment ---");
  const depositTx = await escrow.connect(buyer).depositPayment({ value: amount });
  await depositTx.wait();
  console.log("Payment deposited successfully");
  
  console.log("\n--- Current State ---");
  const state = await escrow.currentState();
  const balance = await escrow.getContractBalance();
  console.log("Escrow state:", state.toString());
  console.log("Contract balance:", hre.ethers.utils.formatEther(balance), "ETH");
  
  console.log("\n--- Buyer Signs Agreement ---");
  const buyerSignTx = await escrow.connect(buyer).signAgreement();
  await buyerSignTx.wait();
  console.log("Buyer signed agreement");
  
  console.log("\n--- Seller Signs Agreement ---");
  const sellerSignTx = await escrow.connect(seller).signAgreement();
  await sellerSignTx.wait();
  console.log("Seller signed agreement");
  
  console.log("\n--- Final State ---");
  const finalState = await escrow.currentState();
  const finalBalance = await escrow.getContractBalance();
  const agreements = await escrow.getAllAgreements();
  
  console.log("Final escrow state:", finalState.toString());
  console.log("Final contract balance:", hre.ethers.utils.formatEther(finalBalance), "ETH");
  console.log("Agreements - Buyer:", agreements.buyerAgreed, "Seller:", agreements.sellerAgreed, "Arbiter:", agreements.arbiterAgreed);
  
  console.log("\n--- Getting User Escrows ---");
  const buyerEscrows = await escrowFactory.getUserEscrows(buyer.address);
  console.log("Buyer escrows:", buyerEscrows);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });