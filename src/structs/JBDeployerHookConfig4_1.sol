// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJBRulesetDataHook4_1} from "@bananapus/core-v5/src/interfaces/IJBRulesetDataHook4_1.sol";

struct JBDeployerHookConfig4_1 {
    bool useDataHookForPay;
    bool useDataHookForCashOut;
    IJBRulesetDataHook4_1 dataHook;
}
