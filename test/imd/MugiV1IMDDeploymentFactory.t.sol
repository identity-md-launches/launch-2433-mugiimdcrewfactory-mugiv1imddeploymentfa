// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
import {MugiVRFAdapter} from "../../src/game/MugiVRFAdapter.sol";
import {MugiIMDLedger} from "../../src/imd/modules/MugiIMDLedger.sol";

/// @dev Mirrors the launch factory's CREATE2 batch in a separate contract. Forge does
/// not meter CREATE issued by the test contract itself (a `new` there reports a few
/// thousand gas), so the four creations run here where creation costs are charged.
contract FactoryBatchProbe {
    function deploy(bytes[4] memory codes) external returns (uint256 gasUsed, address[4] memory created) {
        uint256 start = gasleft();
        for (uint256 i; i < 4; ++i) {
            bytes memory code = codes[i];
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), i) }
            require(deployed != address(0), "factory creation failed");
            created[i] = deployed;
        }
        gasUsed = start - gasleft();
    }
}

contract MugiV1IMDDeploymentFactoryTest is MugiIMDDeploymentFixture {
    function setUp() public {
        vm.warp(1 days);
        manager = new PoolManager(address(this));
        _newFactories();
    }

    function testCompleteConstructorGraphSeedsAllPoolsAndLaunchesWithoutInitializers() public {
        MugiGameHook game = _deployGraph();
        _seedAndLaunch(game);
    }

    function testFactoriesPinSourceHaveNoChildrenAtConstructionAndFitEvmLimits() public view {
        assertEq(factory.hookCreationCodeHash(), keccak256(type(MugiGameHook).creationCode));
        assertEq(factory.hookCreationCodeLength(), type(MugiGameHook).creationCode.length);
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
        assertLe(address(factory).code.length, 24_576);
        assertLe(address(crewFactory).code.length, 24_576);
        assertLe(address(accountingFactory).code.length, 24_576);
        assertLe(address(engineFactory).code.length, 24_576);
        assertLe(type(MugiV1IMDDeploymentFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDCrewFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDAccountingFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDEngineFactory).creationCode.length + 32, 49_152);
    }

    /// @notice Estimates the single launch transaction that creates the four manifest
    /// factories by CREATE2. The measurement must include EIP-170 code deposit,
    /// CREATE2 base cost and EIP-3860 initcode words; the earlier in-test `new`
    /// measurement (about 27k gas) omitted all of them. The launch service still
    /// simulates the exact ProjectFactory call against its own gas ceiling.
    function testFactoryCreationBatchHasConservativeGasHeadroom() public {
        bytes[4] memory codes = [
            abi.encodePacked(type(MugiIMDCrewFactory).creationCode, abi.encode(OWNER)),
            abi.encodePacked(type(MugiV1IMDDeploymentFactory).creationCode, abi.encode(OWNER)),
            abi.encodePacked(type(MugiIMDAccountingFactory).creationCode, abi.encode(OWNER)),
            abi.encodePacked(type(MugiIMDEngineFactory).creationCode, abi.encode(OWNER))
        ];
        uint256 initcodeBytes;
        for (uint256 i; i < 4; ++i) {
            initcodeBytes += codes[i].length;
        }
        FactoryBatchProbe probe = new FactoryBatchProbe();
        (uint256 execution, address[4] memory created) = probe.deploy(codes);
        uint256 runtimeBytes;
        for (uint256 i; i < 4; ++i) {
            assertGt(created[i].code.length, 0);
            runtimeBytes += created[i].code.length;
        }
        // Floor the EVM charges regardless of execution: 200 gas per deposited runtime
        // byte, 32,000 per CREATE2, and 2 + 6 gas per initcode word (EIP-3860 plus hashing).
        uint256 creationFloor = 200 * runtimeBytes + 4 * 32_000 + 8 * ((initcodeBytes + 31) / 32);
        assertGe(execution, creationFloor, "measurement must include creation costs");
        // Every calldata byte priced as nonzero: four initcodes, four owner words, selector and ABI heads.
        uint256 calldataUpperBound = 16 * (initcodeBytes + 4 * 32 + 4 + 16 * 32);
        // The real ProjectFactory adds registry writes and events whose exact cost is
        // not reproducible here; reserve a full million gas for that bookkeeping.
        uint256 estimate = 21_000 + execution + calldataUpperBound + 1_000_000;
        emit log_named_uint("Four factory runtime bytes", runtimeBytes);
        emit log_named_uint("Four factory initcode bytes", initcodeBytes);
        emit log_named_uint("Four factory CREATE2 execution gas", execution);
        emit log_named_uint("Estimated launch transaction gas", estimate);
        assertLt(estimate, 16_777_216);
    }

    function testEveryDescendantCreationCallFitsSeparateTransactionGasCap() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        vm.startPrank(OWNER);
        uint256 start = gasleft();
        factory.deployModules(salt, keccak256(code), moduleConfig);
        _assertTransactionGas("Four service module creations", start - gasleft(), 4 + 16 * 32);
        start = gasleft();
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        _assertTransactionGas("Ten crew token creations", start - gasleft(), 4 + 2 * 32);
        start = gasleft();
        engineFactory.deployForHook(futureHook, manager);
        _assertTransactionGas("Engine creation", start - gasleft(), 4 + 2 * 32);
        start = gasleft();
        accountingFactory.deployForHook(ledgerConfig);
        _assertTransactionGas("Three accounting module creations", start - gasleft(), 4 + 16 * 32);
        start = gasleft();
        factory.deployHook(code);
        _assertTransactionGas("Hook creation", start - gasleft(), 4 + 2 * 32 + code.length + 32);
        vm.stopPrank();
    }

    function _assertTransactionGas(string memory label, uint256 execution, uint256 calldataBytes) private {
        emit log_named_uint(label, execution);
        // Treat every calldata byte as nonzero and leave additional overhead.
        assertLt(execution + 21_000 + 16 * calldataBytes + 100_000, 16_777_216);
    }

    function testUnauthorizedCallersCannotConsumeAnyPredictedAddress() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        vm.startPrank(address(0xBAD));
        vm.expectRevert(MugiIMDCrewFactory.Unauthorized.selector);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.Unauthorized.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.Unauthorized.selector);
        engineFactory.deployForHook(futureHook, manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployHook(code);
        vm.stopPrank();
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
    }

    function testConstructorFailureRollsBackModuleCommitmentAndCreateNonces() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _moduleConfiguration();
        c.vrfCallbackGasLimit = 1;
        vm.prank(OWNER);
        vm.expectRevert(MugiVRFAdapter.InvalidConfiguration.selector);
        factory.deployModules(salt, keccak256(code), c);
        assertFalse(factory.modulesDeployed());
        assertEq(factory.plannedHook(), address(0));
        assertEq(factory.hookInitCodeHash(), bytes32(0));
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(factory.predictModules().router.code.length, 0);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        assertEq(vm.getNonce(address(factory)), 5);
    }

    function testHookRequiresAllFourOwnModulesAndCrewCreationAndExactCommittedCode() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployHook(code);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        bytes memory wrong = bytes.concat(code, hex"00");
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(address(factory.hook()), address(0));
    }

    function testEvenCommittedArbitraryCreationCodeCannotReplacePinnedImplementation() public {
        bytes memory wrong = new bytes(type(MugiGameHook).creationCode.length + 14 * 32);
        bytes32 salt = _mine(keccak256(wrong));
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(wrong), _moduleConfiguration());
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(factory.plannedHook().code.length, 0);
    }

    function testHookConfigurationCannotSubstituteFactoryModuleOrOwner() public {
        MugiGameHook.Configuration memory c = _hookConfiguration();
        c.randomnessProvider = address(0xBAD);
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        _deployBeforeHook(code, salt);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
    }

    function testMismatchedLedgerTokenBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(true);
    }

    function testMismatchedLedgerExclusionBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(false);
    }

    function _assertMismatchedLedgerRejected(bool changeToken) private {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        if (changeToken) ledgerConfig.token0 = address(0xBAD);
        else ledgerConfig.manager = address(0xBAD);
        vm.deal(OWNER, 2 ether);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(ledgerConfig);
        MugiGameHook game = factory.deployHook(code);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
        assertEq(game.seededMask(), 0);
        assertEq(address(game).balance, 0);
    }

    function testSingleSeasonCommitmentsCannotBeReplacedAfterSuccess() public {
        MugiGameHook game = _deployGraph();
        bytes memory code = _hookCode(_hookConfiguration());
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(address(game));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        bytes32 salt = factory.hookSalt();
        vm.startPrank(OWNER);
        vm.expectRevert(MugiIMDCrewFactory.AlreadyDeployed.selector);
        crewFactory.deployCrewSet(address(game), SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.AlreadyDeployed.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.AlreadyDeployed.selector);
        engineFactory.deployForHook(address(game), manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.HookAlreadyDeployed.selector);
        factory.deployHook(code);
        vm.stopPrank();
    }
}
