// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
import {MugiReserveMath} from "../../src/game/MugiReserveMath.sol";

/// @dev Failure paths of the exact four manifest factories and their later
/// owner creation transactions, beyond the happy-path graph fixture.
contract MugiIMDManifestFactoriesTest is MugiIMDDeploymentFixture {
    /// The owner argument written for all four entries of the requested manifest.
    address internal constant MANIFEST_OWNER = 0x20714d50F4675c366De30b603728a90DDddb240f;

    function setUp() public {
        vm.warp(1 days);
        manager = new PoolManager(address(this));
        _newFactories();
    }

    function testManifestOrderFactoriesBindOnlyTheStaticOwnerAndCreateNoChildren() public {
        MugiIMDCrewFactory crews = new MugiIMDCrewFactory(MANIFEST_OWNER);
        MugiV1IMDDeploymentFactory main = new MugiV1IMDDeploymentFactory(MANIFEST_OWNER);
        MugiIMDAccountingFactory accounting = new MugiIMDAccountingFactory(MANIFEST_OWNER);
        MugiIMDEngineFactory engines = new MugiIMDEngineFactory(MANIFEST_OWNER);
        assertEq(crews.owner(), MANIFEST_OWNER);
        assertEq(main.owner(), MANIFEST_OWNER);
        assertEq(accounting.owner(), MANIFEST_OWNER);
        assertEq(engines.owner(), MANIFEST_OWNER);
        // A fresh contract has nonce 1; any child created in a constructor would raise it.
        assertEq(vm.getNonce(address(crews)), 1);
        assertEq(vm.getNonce(address(main)), 1);
        assertEq(vm.getNonce(address(accounting)), 1);
        assertEq(vm.getNonce(address(engines)), 1);
        // No descendant exists yet at any predicted address.
        address[10] memory predicted = crews.predictCrewSet();
        for (uint256 i; i < 10; ++i) {
            assertEq(predicted[i].code.length, 0);
        }
        assertEq(main.predictModules().router.code.length, 0);
        assertEq(address(accounting.predictModules().ledger).code.length, 0);
        assertEq(engines.predictEngine().code.length, 0);
        assertEq(crews.hook(), address(0));
        assertFalse(main.modulesDeployed());
        assertEq(address(main.hook()), address(0));
        // Raw creation code pin is exactly this source's hook, without constructor arguments.
        assertEq(main.hookCreationCodeHash(), keccak256(type(MugiGameHook).creationCode));
        assertEq(main.hookCreationCodeLength(), type(MugiGameHook).creationCode.length);
    }

    function testEveryManifestFactoryRejectsZeroOwner() public {
        vm.expectRevert(MugiIMDCrewFactory.InvalidConfiguration.selector);
        new MugiIMDCrewFactory(address(0));
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        new MugiV1IMDDeploymentFactory(address(0));
        vm.expectRevert(MugiIMDAccountingFactory.InvalidConfiguration.selector);
        new MugiIMDAccountingFactory(address(0));
        vm.expectRevert(MugiIMDEngineFactory.InvalidConfiguration.selector);
        new MugiIMDEngineFactory(address(0));
    }

    function testCrewFactoryRejectsZeroHookAndOutOfRangeSupplyAtomically() public {
        vm.startPrank(OWNER);
        vm.expectRevert(MugiIMDCrewFactory.InvalidConfiguration.selector);
        crewFactory.deployCrewSet(address(0), SUPPLY);
        vm.expectRevert(MugiReserveMath.InvalidInitialSupply.selector);
        crewFactory.deployCrewSet(address(0x2aec), 999);
        vm.expectRevert(MugiReserveMath.InvalidInitialSupply.selector);
        crewFactory.deployCrewSet(address(0x2aec), 1e36 + 1);
        vm.stopPrank();
        assertEq(crewFactory.hook(), address(0), "failed creation left a hook binding");
        assertEq(vm.getNonce(address(crewFactory)), 1, "failed creation consumed nonces");
        // Boundaries are accepted.
        vm.prank(OWNER);
        address[10] memory created = crewFactory.deployCrewSet(address(0x2aec), 1000);
        assertEq(created[9], crewFactory.predictCrewSet()[9]);
        assertEq(vm.getNonce(address(crewFactory)), 11);
    }

    function testDeployModulesRejectsEveryInvalidStaticInput() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 hash = keccak256(code);
        bytes32 salt = _mine(hash);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _moduleConfiguration();
        vm.startPrank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployModules(salt, bytes32(0), c);
        c.manager = address(0);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployModules(salt, hash, c);
        c = _moduleConfiguration();
        c.crewFactory = address(0);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployModules(salt, hash, c);
        c = _moduleConfiguration();
        c.initialSupply = 999;
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployModules(salt, hash, c);
        c.initialSupply = 1e36 + 1;
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployModules(salt, hash, c);
        vm.stopPrank();
        assertFalse(factory.modulesDeployed());
        assertEq(vm.getNonce(address(factory)), 1);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzDeployModulesRejectsSaltWithoutHookPermissionBits(bytes32 salt) public {
        bytes32 hash = keccak256(_hookCode(_hookConfiguration()));
        address predicted = factory.predictHook(salt, hash);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _moduleConfiguration();
        vm.prank(OWNER);
        if ((uint160(predicted) & 0x3fff) != 0x2aec) {
            vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
            factory.deployModules(salt, hash, c);
            assertFalse(factory.modulesDeployed());
        } else {
            factory.deployModules(salt, hash, c);
            assertEq(factory.plannedHook(), predicted);
        }
    }

    function testCrewSetBoundToAnotherHookBlocksHookCreation() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(address(uint160(futureHook) ^ 1), SUPPLY);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(_ledgerConfiguration(futureHook));
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        vm.stopPrank();
        assertEq(futureHook.code.length, 0);
    }

    function testHookRequiresAccountingAndEngineModulesToExist() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        engineFactory.deployForHook(futureHook, manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        accountingFactory.deployForHook(_ledgerConfiguration(futureHook));
        MugiGameHook game = factory.deployHook(code);
        vm.stopPrank();
        assertEq(address(game), futureHook);
    }

    function testHookConfigurationCannotChangeOwnerManagerOrSupply() public {
        _assertHookRejected(0);
        setUp();
        _assertHookRejected(1);
        setUp();
        _assertHookRejected(2);
        setUp();
        _assertHookRejected(3);
    }

    function _assertHookRejected(uint256 field) private {
        MugiGameHook.Configuration memory c = _hookConfiguration();
        if (field == 0) c.owner = address(0xBAD);
        else if (field == 1) c.manager = address(0xBAD);
        else if (field == 2) c.initialSupply = SUPPLY + 1;
        else c.airdrop = address(0xBAD);
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        _deployBeforeHook(code, salt);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
    }

    function testCrewSupplyMismatchIsCaughtAtFirstEconomicUse() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        vm.deal(OWNER, 1 ether);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY / 2);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(_ledgerConfiguration(futureHook));
        MugiGameHook game = factory.deployHook(code);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
        assertEq(game.seededMask(), 0);
    }

    function testEngineBoundToAnotherManagerIsCaughtAtFirstEconomicUse() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        PoolManager other = new PoolManager(address(this));
        vm.deal(OWNER, 1 ether);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        engineFactory.deployForHook(futureHook, other);
        accountingFactory.deployForHook(_ledgerConfiguration(futureHook));
        MugiGameHook game = factory.deployHook(code);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
    }

    function testHookOwnershipIsTwoStepAndOwnerOnly() public {
        MugiGameHook game = _deployGraph();
        address next = address(0x0E0E);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.transferOwnership(next);
        vm.startPrank(OWNER);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.transferOwnership(address(0));
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.transferOwnership(OWNER);
        game.transferOwnership(next);
        vm.stopPrank();
        assertEq(game.owner(), OWNER, "ownership moved before acceptance");
        vm.prank(address(0xBAD));
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.acceptOwnership();
        vm.prank(OWNER);
        game.cancelOwnershipTransfer();
        vm.prank(next);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.acceptOwnership();
        vm.prank(OWNER);
        game.transferOwnership(next);
        vm.prank(next);
        game.acceptOwnership();
        assertEq(game.owner(), next);
        assertEq(game.pendingOwner(), address(0));
        // The factory's immutable owner is unaffected and cannot recreate the graph.
        assertEq(factory.owner(), OWNER);
    }

    function testPrelaunchGatesRejectEveryEconomicEntryPoint() public {
        MugiGameHook game = _deployGraph();
        vm.deal(OWNER, 2 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.seedPool{value: 0}(0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.seedPool{value: 1 ether}(10);
        game.seedPool{value: 1 ether}(0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.seedPool{value: 0}(1);
        // Launch needs all ten pools.
        vm.warp(uint256(game.configuredAt()) + 7 days);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.launch();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.requestElimination();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.finalize();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimEth(payable(address(this)));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimTokens();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.retireAirdrop();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.sweepExpiredFinalClaims();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.migrateToV2(address(this));
        vm.prank(OWNER);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.migrateToV2(address(this));
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.abortPrelaunch();
    }
}
