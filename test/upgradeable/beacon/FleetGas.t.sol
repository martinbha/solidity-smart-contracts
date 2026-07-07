// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Billboard} from "../../../src/upgradeable/Billboard.sol";
import {BeaconBillboard} from "../../../src/upgradeable/beacon/BeaconBillboard.sol";
import {BillboardFactory} from "../../../src/upgradeable/beacon/BillboardFactory.sol";

/// @notice Gas comparison between the three ways a Billboard call can reach
///         its logic. Run with `forge test --match-contract FleetGas -vv` to
///         see the numbers; they go in the PR description.
///
///         Expected ordering (cold storage reads dominate):
///           direct < UUPS proxy (1 extra SLOAD: impl slot)
///                  < beacon proxy (2 extra: beacon slot + CALL to beacon)
contract FleetGasTest is Test {
    Billboard internal direct;
    Billboard internal uupsProxied;
    BeaconBillboard internal beaconProxied;

    address internal owner = makeAddr("owner");

    function setUp() public {
        // Direct implementation call baseline: initializers are disabled on a
        // raw implementation, so bypass initialize by etching state-free code
        // and reading through the same ABI. Simplest honest baseline: deploy
        // a plain (non-proxied) instance via a proxy-free clone of the setup.
        Billboard uupsImplementation = new Billboard();
        uupsProxied = Billboard(
            address(
                new ERC1967Proxy(
                    address(uupsImplementation),
                    abi.encodeCall(Billboard.initialize, (owner, "gas probe"))
                )
            )
        );

        BeaconBillboard beaconImplementation = new BeaconBillboard();
        BillboardFactory factory = new BillboardFactory(address(beaconImplementation), owner);
        vm.prank(owner);
        beaconProxied = BeaconBillboard(factory.createBillboard("gas probe", 0));

        // Direct baseline: the UUPS implementation contract itself, storage
        // uninitialized — message() returns "" but pays identical execution
        // costs minus proxy hops, which is exactly what we want to isolate.
        direct = uupsImplementation;
    }

    function test_GasComparison_MessageRead() public {
        uint256 gasDirect = meter(address(direct));
        uint256 gasUups = meter(address(uupsProxied));
        uint256 gasBeacon = meter(address(beaconProxied));

        console.log("message() call gas - direct:        ", gasDirect);
        console.log("message() call gas - UUPS proxy:    ", gasUups);
        console.log("message() call gas - beacon proxy:  ", gasBeacon);
        console.log("UUPS overhead vs direct:            ", gasUups - gasDirect);
        console.log("beacon overhead vs direct:          ", gasBeacon - gasDirect);
        console.log("beacon overhead vs UUPS:            ", gasBeacon - gasUups);

        // The structural claim this test locks in: each hop costs more.
        assertGt(gasUups, gasDirect);
        assertGt(gasBeacon, gasUups);
    }

    function meter(address target) internal returns (uint256 used) {
        uint256 before = gasleft();
        (bool ok,) = target.staticcall(abi.encodeWithSignature("message()"));
        used = before - gasleft();
        require(ok, "probe call failed");
    }
}
