//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import "forge-std/console.sol";
import {IOracle} from "../src/IOracle.sol";

contract HookMiningSample is Script {
    // Address of PoolManager deployed on Sepolia
    PoolManager manager = PoolManager(0xCa6DBBe730e31fDaACaA096821199EEED5AD84aE);

    function setUp() public {
        // Set up the hook flags you wish to enable
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        // Find an address + salt using HookMiner that meets our flags criteria
        address CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(DynamicFeeHook).creationCode, abi.encode(manager, IOracle(address(0)))
        );

        // Deploy our hook contract with the given `salt` value
        vm.startBroadcast();
        DynamicFeeHook hook = new DynamicFeeHook{salt: salt}(manager, IOracle(address(0)));
        // Ensure it got deployed to our pre-computed address
        require(address(hook) == hookAddress, "hook address mismatch");
        vm.stopBroadcast();
    }

    function run() public {
        console.log("Hello");
    }
}
