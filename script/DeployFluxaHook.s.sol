// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FluxaHook} from "../src/FluxaHook.sol";
import {MockChronicleOracle} from "../src/mocks/MockChronicleOracle.sol";
import {MockERC8004, MockERC7857} from "../src/mocks/MockERC8004.sol";
import {IChronicleOracle} from "../src/interfaces/IChronicleOracle.sol";
import {IERC8004Registry, IERC7857Agent} from "../src/interfaces/IERC8004Registry.sol";

contract DeployFluxaHook is Script {
    // Uniswap v4 PoolManager on Base Sepolia
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73f8fDBfaC0D898690dd09B0922fE5C68A69A;

    // Universal CREATE2 deployer (used by Forge script for salted `new`)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Permission flags required for FluxaHook
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== FluxaHook Deploy Script ===");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy mock infrastructure
        MockChronicleOracle chronicle = new MockChronicleOracle();
        MockERC8004 erc8004 = new MockERC8004();
        MockERC7857 agentNft = new MockERC7857();

        console2.log("MockChronicleOracle:", address(chronicle));
        console2.log("MockERC8004:", address(erc8004));
        console2.log("MockERC7857:", address(agentNft));

        // Step 2: Mine CREATE2 salt for FluxaHook with correct permission bits
        // In forge script, salted `new` routes through the CREATE2 deployer proxy
        bytes memory constructorArgs = abi.encode(
            IPoolManager(BASE_SEPOLIA_POOL_MANAGER),
            IChronicleOracle(address(chronicle)),
            IERC8004Registry(address(erc8004)),
            IERC7857Agent(address(agentNft)),
            deployer
        );

        (address expectedAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            FLAGS,
            type(FluxaHook).creationCode,
            constructorArgs
        );
        console2.log("Expected hook address:", expectedAddr);

        // Step 3: Deploy FluxaHook via CREATE2 (routed through CREATE2 deployer by forge)
        FluxaHook hook = new FluxaHook{salt: salt}(
            IPoolManager(BASE_SEPOLIA_POOL_MANAGER),
            IChronicleOracle(address(chronicle)),
            IERC8004Registry(address(erc8004)),
            IERC7857Agent(address(agentNft)),
            deployer
        );

        require(address(hook) == expectedAddr, "Hook address mismatch!");
        console2.log("FluxaHook deployed at:", address(hook));

        vm.stopBroadcast();

        console2.log("\n=== Deployment Summary ===");
        console2.log("FluxaHook:", address(hook));
        console2.log("MockChronicleOracle:", address(chronicle));
        console2.log("MockERC8004:", address(erc8004));
        console2.log("MockERC7857:", address(agentNft));
        console2.log("PoolManager:", BASE_SEPOLIA_POOL_MANAGER);
        console2.log("Owner:", deployer);
        console2.log("Salt:", vm.toString(salt));
    }
}
