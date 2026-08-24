// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FluxaHook} from "../src/FluxaHook.sol";
import {IFluxaHook} from "../src/interfaces/IFluxaHook.sol";
import {MockChronicleOracle} from "../src/mocks/MockChronicleOracle.sol";
import {MockERC8004, MockERC7857} from "../src/mocks/MockERC8004.sol";
import {MockRWAInstrument} from "../src/mocks/MockRWAInstrument.sol";
import {MockEigenLayerAVS} from "../src/mocks/MockEigenLayerAVS.sol";
import {MockERC8183Escrow} from "../src/mocks/MockERC8183Escrow.sol";
import {IChronicleOracle} from "../src/interfaces/IChronicleOracle.sol";
import {IERC8004Registry, IERC7857Agent} from "../src/interfaces/IERC8004Registry.sol";
import {IEigenLayerAVS} from "../src/interfaces/IEigenLayerAVS.sol";

contract DeployFluxaHook is Script {
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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

        console2.log("=== FluxaHook Deploy Script (v4 - full agent layer) ===");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Deploy mock infrastructure ──
        MockChronicleOracle chronicle = new MockChronicleOracle();
        MockERC8004 erc8004 = new MockERC8004();
        MockERC7857 agentNft = new MockERC7857();
        MockEigenLayerAVS avs = new MockEigenLayerAVS();
        MockRWAInstrument rwaToken = new MockRWAInstrument("Fluxa RWA Bond", "FRWA", 18);

        console2.log("MockChronicleOracle:", address(chronicle));
        console2.log("MockERC8004:", address(erc8004));
        console2.log("MockERC7857:", address(agentNft));
        console2.log("MockEigenLayerAVS:", address(avs));
        console2.log("MockRWAInstrument:", address(rwaToken));

        // ── Step 2: Mine CREATE2 salt for FluxaHook ──
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

        // ── Step 3: Deploy FluxaHook via CREATE2 ──
        FluxaHook hook = new FluxaHook{salt: salt}(
            IPoolManager(BASE_SEPOLIA_POOL_MANAGER),
            chronicle,
            erc8004,
            agentNft,
            deployer
        );
        require(address(hook) == expectedAddr, "Hook address mismatch!");
        console2.log("FluxaHook deployed at:", address(hook));

        // ── Step 4: Deploy ERC-8183 Escrow ──
        // Use RWA token (currency0) as payment token for simplicity — or a separate mock USDC.
        // For demo: escrow uses the RWA token address. In production, this would be USDC.
        MockERC8183Escrow escrow = new MockERC8183Escrow(address(hook), address(rwaToken));
        console2.log("MockERC8183Escrow:", address(escrow));

        // ── Step 5: On-chain setup ──
        // 5a. Configure oracle: set price + yield for RWA token
        chronicle.setPrice(address(rwaToken), 1e18); // 1:1 price
        chronicle.setYield(address(rwaToken), 500);   // 5% APY

        // 5b. Register a mock attestation for Mode B (AI agent price)
        bytes memory proof = abi.encode(bytes32("fluxa_agent_attestation_v1"));
        bytes32 proofHash = keccak256(proof);
        chronicle.setAttestation(proofHash, 1.5e18); // AI-inferred price: 1 RWA = 1.5 USDC

        // 5c. Mint agent NFT + set reputation
        uint256 agentId = agentNft.mint(deployer);
        erc8004.setReputation(agentId, 75); // above threshold (50)
        console2.log("Agent NFT minted, agentId:", agentId);

        // 5d. Configure AVS: allow agent
        avs.setAgentAllowed(agentId, true);

        // 5e. Set AVS validator on hook
        hook.setAVSValidator(address(avs));
        console2.log("AVS validator set on hook");

        // Note: Pool registration + initialization + liquidity must be done via
        // a separate script or the FE, because it requires a PoolKey with
        // specific currencies (USDC + RWA token) and manager.initialize().

        vm.stopBroadcast();

        // ── Print attestation proof for off-chain agent service ──
        console2.log("\n=== Agent Service Config ===");
        console2.log("Hook:", address(hook));
        console2.log("AgentNFT:", address(agentNft));
        console2.log("AgentId:", agentId);
        console2.log("ReputationRegistry:", address(erc8004));
        console2.log("AVS:", address(avs));
        console2.log("Escrow:", address(escrow));
        console2.log("RWA Token:", address(rwaToken));
        console2.log("Chronicle:", address(chronicle));
        console2.log("Attestation proof (hex):");
        console2.logBytes(proof);
        console2.log("Attested AI price: 1.5e18 (1 RWA = 1.5 USDC)");

        console2.log("\n=== Deployment Summary ===");
        console2.log("FluxaHook:", address(hook));
        console2.log("MockChronicleOracle:", address(chronicle));
        console2.log("MockERC8004:", address(erc8004));
        console2.log("MockERC7857:", address(agentNft));
        console2.log("MockEigenLayerAVS:", address(avs));
        console2.log("MockERC8183Escrow:", address(escrow));
        console2.log("MockRWAInstrument:", address(rwaToken));
        console2.log("PoolManager:", BASE_SEPOLIA_POOL_MANAGER);
        console2.log("Owner:", deployer);
        console2.log("Salt:", vm.toString(salt));
    }
}
