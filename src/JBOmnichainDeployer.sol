// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IJB721TiersHook} from "@bananapus/721-hook/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookProjectDeployer} from "@bananapus/721-hook/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBLaunchProjectConfig} from "@bananapus/721-hook/src/structs/JBLaunchProjectConfig.sol";
import {JBPermissioned} from "@bananapus/core/src/abstract/JBPermissioned.sol";
import {IJBCashOutHook} from "@bananapus/core/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core/src/interfaces/IJBPermissioned.sol";
import {IJBProjects} from "@bananapus/core/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core/src/interfaces/IJBRulesetDataHook.sol";
import {JBRulesetConfig} from "@bananapus/core/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core/src/structs/JBTerminalConfig.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers/src/interfaces/IJBSuckerRegistry.sol";
import {JBPermissionIds} from "@bananapus/permission-ids/src/JBPermissionIds.sol";
import {REVSuckerDeploymentConfig} from "@rev-net/core/src/structs/REVSuckerDeploymentConfig.sol";

/// @notice `JBDeployer` deploys, manages, and operates Juicebox projects with suckers.
contract JBOmnichainDeployer is ERC2771Context, JBPermissioned, IJBRulesetDataHook, IJBCashOutHook, IERC721Receiver {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error BlockedFunctionCall(bytes4 functionSelector);
    error CallFailed();
    error Unauthorized();

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller used to create and manage Juicebox projects.
    IJBController public immutable CONTROLLER;

    /// @notice Mints ERC-721s that represent Juicebox project ownership and transfers.
    IJBProjects public immutable PROJECTS;

    /// @notice Deploys tiered ERC-721 hooks for projects.
    IJB721TiersHookProjectDeployer public immutable HOOK_PROJECT_DEPLOYER;

    /// @notice Deploys and tracks suckers for projects.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Each project's data hook provided on deployment.
    /// @custom:param projectId The ID of the project to get the data hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the data hook for.
    mapping(uint256 projectId => mapping(uint256 rulesetId => IJBRulesetDataHook dataHook)) public override dataHookOf;

    /// @notice Each project's owner.
    /// @custom:param projectId The ID of the project to get the owner for.
    mapping(uint256 projectId => address owner) public override ownerOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller to use for launching and operating the Juicebox projects.
    /// @param suckerRegistry The registry to use for deploying and tracking each project's suckers.
    /// @param hookProjectDeployer The deployer to use for project's tiered ERC-721 hooks.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBController controller,
        IJBSuckerRegistry suckerRegistry,
        IJB721TiersHookProjectDeployer hookProjectDeployer,
        address trustedForwarder
    )
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
        ERC2771Context(trustedForwarder)
    {
        CONTROLLER = controller;
        PROJECTS = controller.PROJECTS();
        SUCKER_REGISTRY = suckerRegistry;
        HOOK_PROJECT_DEPLOYER = hookProjectDeployer;

        // Give the sucker registry permission to map tokens for all revnets.
        uint8[] memory permissionsIds = new uint8[](1);
        permissionsIds[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        // Give the operator the permission.
        // Set up the permission data.
        JBPermissionsData memory permissionData =
            JBPermissionsData({operator: SUCKER_REGISTRY, projectId: 0, permissionIds: permissionIds});

        // Set the permissions.
        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Forward the call to the original data hook.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a payment.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which project tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of what's being paid in) to be sent to pay hooks instead of being paid
    /// into the project. Useful for automatically routing funds from a treasury as payments come in.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return dataHookOf[context.projectId][context.rulesetId].beforePayRecordedWith(context);
    }

    /// @notice Allow cash outs from suckers without a tax.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a cash out.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of project tokens that are cashed out.
    /// @return totalSupply The total project token supply.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
        if (_isSuckerOf({revnetId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, hookSpecifications);
        }

        // Forward the call to the original data hook.
        (cashOutTaxRate, cashOutCount, totalSupply, hookSpecifications) =
            dataHookOf[context.projectId][context.rulesetId].beforePayRecordedWith(context);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Call a function on a target contract.
    /// @dev Only the owner of the project can call this function.
    /// @param target The target contract to call.
    /// @param data The data to call the target contract with.
    function call(address target, bytes calldata data) external payable returns (bytes memory result) {
        // Only the owner of the project can call this function.
        if (_msgSender() != ownerOf[0]) revert Unauthorized();

        // Extract the function selector from the calldata.
        bytes4 functionSelector;
        assembly {
            functionSelector := calldataload(data.offset) // Extract function selector
        }

        // Check against hardcoded blocked function selectors that must be called directly from this contract.
        if (
            functionSelector
                == bytes4(keccak256("launchProjectFor(address,string,JBRulesetConfig[],JBTerminalConfig[],string)"))
                || functionSelector
                    == bytes4(
                        keccak256(
                            "launchProjectFor(address,JBDeploy721TiersHookConfig,JBLaunchProjectConfig,IJBController,bytes32)"
                        )
                    )
                || functionSelector
                    == bytes4(
                        keccak256(
                            "launchRulesetsFor(uint256,JBDeploy721TiersHookConfig,JBLaunchRulesetsConfig,IJBController,bytes32)"
                        )
                    )
                || functionSelector
                    == bytes4(keccak256("launchRulesetsFor(uint256,JBRulesetConfig[],JBTerminalConfig[],string)"))
                || functionSelector
                    == bytes4(
                        keccak256(
                            "queueRulesetsOf(uint256,JBDeploy721TiersHookConfig,JBQueueRulesetsConfig,IJBController,bytes32)"
                        )
                    ) || functionSelector == bytes4(keccak256("queueRulesetsOf(uint256,JBRulesetConfig[],string)"))
        ) {
            revert BlockedFunctionCall(functionSelector);
        }

        bool success;

        (success, result) = target.call{value: msg.value}(data);

        if (!success) revert CallFailed();
    }
    /// @notice Change the owner of a project.
    /// @dev Only the current owner can change the owner of a project.
    /// @param projectId The ID of the project to change the owner of.
    /// @param newOwner The new owner of the project.

    function changeOwnerOf(uint256 projectId, address newOwner) external {
        if (_msgSender() != ownerOf[projectId]) revert Unauthorized();
        ownerOf[projectId] = newOwner;
    }

    /// @notice Deploy new suckers for an existing project.
    /// @dev Only the juicebox's owner can deploy new suckers.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    function deploySuckersFor(
        uint256 projectId,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.DEPLOY_SUCKERS
        });

        // Deploy the suckers.
        // slither-disable-next-line unused-return
        suckers = SUCKER_REGISTRY.deploySuckersFor({
            projectId: projectId,
            salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
            configurations: suckerDeploymentConfiguration.deployerConfigurations
        });
    }

    /// @notice Creates a project with suckers.
    /// @dev This will mint the project's ERC-721 to the `owner`'s address, queue the specified rulesets, and set up the
    /// specified splits and terminals. Each operation within this transaction can be done in sequence separately.
    /// @dev Anyone can deploy a project to any `owner`'s address.
    /// @param owner The project's owner. The project ERC-721 will be minted to this address.
    /// @param projectUri The project's metadata URI. This is typically an IPFS hash, optionally with the `ipfs://`
    /// prefix. This can be updated by the project's owner.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @return projectId The project's ID.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (uint256 projectId, address[] memory suckers)
    {
        // Get the next project ID.
        projectId = PROJECTS.count() + 1;

        rulesetConfigurations =
            _setup({projectId: projectId, owner: owner, rulesetConfigurations: rulesetConfigurations});

        // Launch the project.
        assert(
            projectId
                == CONTROLLER.launchProjectFor({
                    owner: address(this),
                    projectUri: projectUri,
                    rulesetConfigurations: rulesetConfigurations,
                    terminalConfigurations: terminalConfigurations,
                    memo: memo
                })
        );

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // Deploy the suckers.
            // slither-disable-next-line unused-return
            suckers = SUCKER_REGISTRY.deploySuckersFor({
                projectId: projectId,
                salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
                configurations: suckerDeploymentConfiguration.deployerConfigurations
            });
        }
    }

    /// @notice Launches a new project with a 721 tiers hook attached, and with suckers.
    /// @param owner The address to set as the owner of the project. The ERC-721 which confers this project's ownership
    /// will be sent to this address.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param launchProjectConfig Configuration which dictates the behavior of the project which is being launched.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launch721ProjectFor(
        address owner,
        JBDeploy721TiersHookConfig calldata deployTiersHookConfig,
        JBLaunchProjectConfig calldata launchProjectConfig,
        bytes32 salt,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        // Get the next project ID.
        projectId = PROJECTS.count() + 1;

        launchProjectConfig.rulesetConfigurations = _setup({
            projectId: projectId,
            owner: owner,
            rulesetConfigurations: launchProjectConfig.rulesetConfigurations
        });

        // Keep a reference to the new project ID.
        uint256 newProjectId;

        // Launch the project.
        (newProjectId, hook) = HOOK_PROJECT_DEPLOYER.launchProjectFor({
            owner: address(this),
            deployTiersHookConfig: deployTiersHookConfig,
            launchProjectConfig: launchProjectConfig,
            controller: CONTROLLER,
            salt: keccak256(abi.encode(_msgSender(), salt))
        });

        assert(newProjectId == projectId);

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // Deploy the suckers.
            // slither-disable-next-line unused-return
            suckers = SUCKER_REGISTRY.deploySuckersFor({
                projectId: projectId,
                salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
                configurations: suckerDeploymentConfiguration.deployerConfigurations
            });
        }
    }

    /// @notice Launches new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the newly launched rulesets.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] memory terminalConfigurations,
        string calldata memo
    )
        external
        returns (uint256)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.SET_TERMINALS
        });

        rulesetConfigurations =
            _setup({projectId: projectId, owner: address(0), rulesetConfigurations: rulesetConfigurations});

        return CONTROLLER.launchRulesetsFor({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });
    }

    /// @notice Launches new rulesets for a project with a 721 tiers hook attached, using this contract as the data
    /// hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param launchRulesetsConfig Configuration which dictates the behavior of the rulesets which are being launched.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launch721RulesetsFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBLaunchRulesetsConfig memory launchRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.SET_TERMINALS
        });

        launchRulesetsConfig.rulesetConfigurations = _setup({
            projectId: projectId,
            owner: address(0),
            rulesetConfigurations: launchRulesetsConfig.rulesetConfigurations
        });

        // Launch the project.
        (projectId, hook) = HOOK_PROJECT_DEPLOYER.launchRulesetsFor({
            projectId: projectId,
            deployTiersHookConfig: deployTiersHookConfig,
            launchRulesetsConfig: launchRulesetsConfig,
            controller: CONTROLLER,
            salt: keccak256(abi.encode(_msgSender(), salt))
        });
    }

    /// @notice Queues new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the newly queued rulesets.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo
    )
        external
        returns (uint256)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        rulesetConfigurations =
            _setup({projectId: projectId, owner: address(0), rulesetConfigurations: rulesetConfigurations});

        return
            CONTROLLER.queueRulesetsOf({projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: memo});
    }

    /// @notice Queues new rulesets for a project with a 721 tiers hook attached, using this contract as the data hook.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param queueRulesetsConfig Configuration which dictates the behavior of the rulesets which are being queued.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function queue721RulesetsOf(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBQueueRulesetsConfig memory queueRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: ownerOf[projectId],
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        queueRulesetsConfig.rulesetConfigurations = _setup({
            projectId: projectId,
            owner: address(0),
            rulesetConfigurations: queueRulesetsConfig.rulesetConfigurations
        });

        // Launch the project.
        (projectId, hook) = HOOK_PROJECT_DEPLOYER.queueRulesetsOf({
            projectId: projectId,
            deployTiersHookConfig: deployTiersHookConfig,
            queueRulesetsConfig: queueRulesetsConfig,
            controller: CONTROLLER,
            salt: keccak256(abi.encode(_msgSender(), salt))
        });
    }

    /// @dev Make sure this contract can only receive project NFTs from `JBProjects`.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        // Make sure the 721 received is from the `JBProjects` contract.
        if (msg.sender != address(PROJECTS)) revert();

        return IERC721Receiver.onERC721Received.selector;
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Sets up a project's rulesets and stores the project's owner.
    /// @param projectId The ID of the project to set up.
    /// @param owner The owner of the project.
    /// @param rulesetConfigurations The rulesets to set up.
    /// @return rulesetConfigurations The rulesets that were set up.
    function _setup(
        uint256 projectId,
        address owner,
        JBRulesetConfig[] calldata rulesetConfigurations
    )
        internal
        returns (JBRulesetConfig[] memory)
    {
        // Store the project's owner.
        if (owner != address(0)) ownerOf[projectId] = owner;

        for (uint256 i; i < rulesetConfigurations.length; i++) {
            // Store the data hook.
            dataHookOf[projectId][block.timestamp + i] = IJBRulesetDataHook(rulesetConfigurations[i].metadata.dataHook);

            // Set this contract as the data hook.
            rulesetConfigurations[i].metadata.dataHook = IJBRulesetDataHook(address(this));
            rulesetConfigurations[i].metadata.useDataHookForCashOut = true;
        }

        return rulesetConfigurations;
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
