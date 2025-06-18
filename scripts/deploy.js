const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());

  const EscrowFactory = await hre.ethers.getContractFactory("EscrowFactory");
  const escrowFactory = await EscrowFactory.deploy();
  
  await escrowFactory.deployed();
  
  console.log("EscrowFactory deployed to:", escrowFactory.address);
  
  const Escrow = await hre.ethers.getContractFactory("Escrow");
  console.log("Escrow contract compiled and ready for deployment via factory");
  
  return {
    escrowFactory: escrowFactory.address,
  };
}

main()
  .then((addresses) => {
    console.log("Deployment completed successfully!");
    console.log("Contract addresses:", addresses);
    process.exit(0);
  })
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });