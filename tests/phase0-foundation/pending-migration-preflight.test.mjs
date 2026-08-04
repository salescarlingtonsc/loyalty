import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planPath = path.join(repoRoot, 'supabase/canonical-migration-order.plan.json');

const sqlTestBySemanticVersion = new Map([
  ['v24a', 'db/tests/v24a_redemption_idempotency.sql'],
  ['v24b', 'db/tests/v24b_module_dependencies.sql'],
  ['v24c', 'db/tests/v24c_import_foundation.sql'],
  ['v25', 'db/tests/v25_draft_onboarding.sql'],
  ['v26', 'db/tests/v26_config_versions.sql'],
  ['v27', 'db/tests/v27_rich_rewards.sql'],
  ['v28', 'db/tests/v28_reward_taxonomy.sql'],
  ['v29', 'db/tests/v29_branch_overrides_custom_fields.sql'],
  ['v30', 'db/tests/v30_customer_identity.sql'],
  ['v31', 'db/tests/v31_customer_links_claims.sql'],
  ['v32', 'db/tests/v32_customer_wallet.sql'],
  ['v33', 'db/tests/v33_customer_actions_notifications.sql'],
  ['v34', 'db/tests/v34_reversal_provenance.sql'],
  ['v35', 'db/tests/v35_retention_recommendation.sql'],
  ['v36', 'db/tests/v36_safe_draft_reward_editor.sql'],
  ['v37', 'db/tests/v37_branch_override_editor_rpc.sql'],
  ['v37b', 'db/tests/v37b_versioned_retention_taxonomy.sql'],
  ['v38', 'db/tests/v38_customer_personas_and_gates.sql'],
  ['v39', 'db/tests/v39_detailed_customer_wallet.sql'],
  ['v40', 'db/tests/v40_staff_reversal_workflows.sql'],
  ['v41', 'db/tests/v41_customer_module_hardening.sql'],
  ['c42', 'db/tests/v42_consumer_registration_contracts.sql'],
  ['c44', 'db/tests/v44_actionable_customer_wallet.sql'],
  ['c45', 'db/tests/v45_birthday_benefits.sql'],
  ['v46', 'db/tests/v46_customer_in_app_inbox.sql'],
  ['v46a', 'db/tests/v46a_birthday_draft_runtime_fix.sql'],
  ['v47', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47a', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47b', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v48', 'db/tests/v48_calendar_details_reschedule.sql'],
  ['v49', 'db/tests/v49_billing_projection.sql'],
  ['v49a', 'db/tests/v49a_lint_and_rehearsal_repairs.sql'],
  ['v49b', 'db/tests/v49b_reports_read_authorization.sql'],
  ['v50', 'db/tests/v50_retention_measurement.sql'],
  ['v50a', 'db/tests/v50a_sgt_birthdate_guard.sql'],
  ['v50b', 'db/tests/v50b_contact_proof_constraint_repair.sql'],
  ['v51', 'db/tests/v51_sale_line_items.sql'],
  ['v51a', 'db/tests/v51a_idempotent_sell_overloads.sql'],
  ['v51b', 'db/tests/v51b_client_credit_history.sql'],
  ['v52', 'db/tests/v52_sgt_date_normalization.sql'],
  ['v53', 'db/tests/v53_visit_feedback.sql'],
  ['v53a', 'db/tests/v53a_wallet_review_url.sql'],
  ['v54', 'db/tests/v54_f2_write_hardening.sql'],
  ['v55', 'db/tests/v55_ps1a_authoring.sql'],
  ['v56', 'db/tests/v56_ps1b_events_execution.sql'],
  ['v57', 'db/tests/v57_ps1b1_price_fail_closed.sql'],
  ['v58', 'db/tests/v58_ps1c_checkout_kernel.sql'],
  ['v59', 'db/tests/v59_ps1c1_cart_hardening.sql'],
  ['v60', 'db/tests/v60_ps1c2_execution_state.sql'],
  ['v61', 'db/tests/v61_ps2a_stored_value_foundation.sql'],
  ['v62', 'db/tests/v62_ps2b_shadow_reconciliation.sql'],
  ['v63', 'db/tests/v63_ps2c_redemption_mechanics.sql'],
  ['v64', 'db/tests/v64_ps2d_pause_controls.sql'],
  ['v65', 'db/tests/v65_ps2live_plan_config.sql'],
  ['v65a', 'db/tests/v65a_ps2live_plan_config_hardening.sql'],
  ['v65b', 'db/tests/v65b_ps2live_numeric_range_guard.sql'],
  ['v66', 'db/tests/v66_ps2live_topup_sale.sql'],
  ['v66a', 'db/tests/v66a_ps2live_billing_view_secinvoker.sql'],
  ['v66b', 'db/tests/v66b_program_rules_secinvoker.sql'],
  ['v67', 'db/tests/v67_ps2live_checkout_tender.sql'],
  ['v68a', 'db/tests/v68a_chargeback_correction.sql'],
  ['v68b', 'db/tests/v68b_sv_reversal_netting.sql'],
  ['v68c', 'db/tests/v68c_customer_gift_cards.sql'],
  ['v69', 'db/tests/v69_controlled_cutover.sql'],
  ['v70', 'db/tests/v70_legacy_non_overlap.sql'],
  ['v71', 'db/tests/v71_customer_legal_manifest.sql'],
  ['v72', 'db/tests/v72_booking_identity_sync.sql'],
  ['v73', 'db/tests/v73_booking_lifecycle.sql'],
  ['v74', 'db/tests/v74_staff_module_permissions.sql'],
  ['v75', 'db/tests/v75_sector_entitlements.sql'],
  ['v76', 'db/tests/v76_sme_crm.sql'],
  ['v77', 'db/tests/v77_stripe_billing.sql'],
  ['v78', 'db/tests/v78_consultant_commissions.sql'],
  ['v79', 'db/tests/v79_conversion_onboarding.sql'],
  ['v80', 'db/tests/v80_customer_legal_manifest.sql'],
  ['v81', 'db/tests/v81_customer_relationship_sync.sql'],
  ['v82', 'db/tests/v82_enterprise_intelligence.sql'],
  ['v83', 'db/tests/v83_customer_intelligence.sql'],
  ['v84', 'db/tests/v84_fast_sale_corrections.sql'],
  ['v85', 'db/tests/v85_conversion_guard_repair.sql'],
  ['v86', 'db/tests/v86_enterprise_sme_crm.sql'],
  ['v87', 'db/tests/v87_overdue_appointment_amendments.sql'],
  ['v88', 'db/tests/v88_platform_firm_onboarding.sql'],
  ['v89', 'db/tests/v89_customer_platform_contracts.sql'],
  ['v90', 'db/tests/v90_production_readiness.sql'],
  ['v91', 'db/tests/v91_customer_game_notifications.sql'],
  ['v96', 'db/tests/v96_customer_programme_selector_media.sql'],
  ['v97', 'db/tests/v97_workspace_interface_localization.sql'],
  ['v99', 'db/tests/v99_v100_campaign_truth_adoption.sql'],
  ['v100', 'db/tests/v99_v100_campaign_truth_adoption.sql'],
  ['v102', 'db/tests/v102_package_checkout_entitlements.sql'],
  ['v103', 'db/tests/v103_customer_summary_business_identity.sql'],
  ['v104', 'db/tests/v104_marketing_offers.sql'],
  ['v105', 'db/tests/v105_admin_task_closure.sql'],
  ['v106', 'db/tests/v106_revenue_truth_foundation.sql'],
  ['v107', 'db/tests/v107_customer_lifecycle_contract.sql'],
  ['v108', 'db/tests/v108_measured_bringback_loop.sql'],
  ['v109', 'db/tests/v109_economics_driver_sector_policy.sql'],
  ['v110', 'db/tests/v110_growth_delivery_lifecycle.sql'],
  ['v111', 'db/tests/v111_customer_identity_governance.sql'],
  ['v112', 'db/tests/v112_concurrent_replay_delivery_backoff.sql'],
  ['v113', 'db/tests/v113_effective_identity_consumers.sql'],
  ['v114', 'db/tests/v114_traceable_growth_costs.sql'],
  ['v115', 'db/tests/v115_effective_module_projection.sql'],
  ['v116', 'db/tests/v116_classic_reward_projection.sql'],
  ['v117', 'db/tests/v117_effective_loyalty_boundaries.sql'],
  ['v120', 'db/tests/v120_staff_blocked_times.sql'],
  ['v121', 'db/tests/v121_appointment_completion_customer_projection.sql'],
  ['v122', 'db/tests/v122_owner_seven_workflows.sql'],
  ['v123', 'db/tests/v123_module_button_readiness.sql'],
  ['v124', 'db/tests/v124_stripe_launch_pricing.sql'],
  ['v125', 'db/tests/v125_no_gst_and_overdue.sql'],
  ['v127', 'db/tests/v127_rewards_overview_birthday_reader.sql'],
  ['v128', 'db/tests/v128_simple_rewards_recommender.sql'],
  ['v129', 'db/tests/v129_trial_test_ux.sql'],
  ['v130', 'db/tests/v130_self_serve_business_onboarding.sql'],
  ['v131', 'db/tests/v131_store_publication_readiness.sql'],
  ['v132', 'db/tests/v130_self_serve_business_onboarding.sql'],
  ['v133', 'db/tests/v133_operational_closure.sql'],
  ['v134', 'db/tests/v134_peekaa_brand_legal.sql'],
  ['v138', 'db/tests/v138_auth_grow_closure.sql'],
  ['v143', 'db/tests/v143_effective_reward_tier_boundaries.sql']
]);

const sqlTestByMigrationName = new Map([
  ['nestly_v92_synthetic_reporting_isolation', 'db/tests/v92_synthetic_reporting_isolation.sql'],
  ['nestly_v92_customer_privacy_marketing_manifest', 'db/tests/v92_customer_privacy_marketing_manifest.sql'],
  ['nestly_v93_branch_scoped_merchant_redemption', 'db/tests/v93_synthetic_e2e_campaign.sql'],
  ['nestly_v93_customer_notification_constraints', 'db/tests/v93_customer_notification_constraints.sql'],
  ['nestly_v94_platform_control_intelligence', 'db/tests/v94_platform_control_intelligence.sql'],
  ['nestly_v94_platform_firm_snapshot_null_guard', 'db/tests/v94_platform_firm_snapshot_null_guard.sql'],
  ['nestly_v95_bilingual_programmes', 'db/tests/v95_bilingual_programmes.sql'],
  ['nestly_v95_customer_web_push', 'db/tests/v95_customer_web_push.sql']
]);

const migrationIdentity = (migration) => `${migration.version}_${migration.name}`;
const semanticVersionFor = (migration) =>
  migration.name.match(/^(?:frenly|nestly)_(v\d+[a-z]?|c\d+)(?:_|$)/)?.[1];
const rollbackSuiteFor = (migration) =>
  sqlTestByMigrationName.get(migration.name)
  ?? sqlTestBySemanticVersion.get(semanticVersionFor(migration));

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const statementCount = (sql, statement) =>
  [...sql.matchAll(new RegExp(`^\\s*${statement}\\s*;\\s*$`, 'gim'))].length;

function isEscapeStringPrefix(source, quoteIndex) {
  return source[quoteIndex] === "'"
    && /e/i.test(source[quoteIndex - 1] ?? '')
    && !/[a-z0-9_$]/i.test(source[quoteIndex - 2] ?? '');
}

function parenthesizedBody(source, openIndex) {
  assert.equal(source[openIndex], '(', 'parenthesizedBody must start at an opening parenthesis');
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
    } else if (character === '(') {
      depth += 1;
    } else if (character === ')') {
      depth -= 1;
      if (depth === 0) {
        return { body: source.slice(openIndex + 1, index), closeIndex: index };
      }
    }
  }

  throw new Error('Unbalanced SQL function argument list');
}

function splitTopLevel(source) {
  const parts = [];
  let start = 0;
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
    } else if (character === '(' || character === '[') {
      depth += 1;
    } else if (character === ')' || character === ']') {
      depth -= 1;
    } else if (character === ',' && depth === 0) {
      parts.push(source.slice(start, index));
      start = index + 1;
    }
  }

  parts.push(source.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

function stripSqlComments(source) {
  let result = '';
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      result += character;
      if (backslashEscapes && character === '\\' && index + 1 < source.length) {
        result += source[index + 1];
        index += 1;
      } else if (character === quote) {
        if (source[index + 1] === quote) {
          result += source[index + 1];
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(source, index);
      result += character;
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        index += 1;
      }
      result += '\n';
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          index += 2;
        } else {
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment');
      index -= 1;
      result += ' ';
    } else {
      result += character;
    }
  }

  return result;
}

function sqlOutsideCommentsAndLiterals(source) {
  let result = '';

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const dollarTag = character === '$'
      ? source.slice(index).match(/^\$[a-z_][a-z0-9_]*\$|^\$\$/i)?.[0]
      : null;

    if (dollarTag) {
      const bodyEnd = source.indexOf(dollarTag, index + dollarTag.length);
      assert.notEqual(bodyEnd, -1, `Unclosed SQL dollar quote ${dollarTag}`);
      const consumed = source.slice(index, bodyEnd + dollarTag.length);
      result += consumed.replace(/[^\n]/g, ' ');
      index = bodyEnd + dollarTag.length - 1;
    } else if (character === "'" || character === '"') {
      const quote = character;
      const backslashEscapes = isEscapeStringPrefix(source, index);
      result += ' ';
      for (index += 1; index < source.length; index += 1) {
        if (source[index] === '\n') {
          result += '\n';
        } else {
          result += ' ';
        }
        if (backslashEscapes && source[index] === '\\' && index + 1 < source.length) {
          result += ' ';
          index += 1;
        } else if (source[index] === quote) {
          if (source[index + 1] === quote) {
            result += ' ';
            index += 1;
          } else {
            break;
          }
        }
      }
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        result += ' ';
        index += 1;
      }
      result += '\n';
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      result += '  ';
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          result += '  ';
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          result += '  ';
          index += 2;
        } else {
          result += source[index] === '\n' ? '\n' : ' ';
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment');
      index -= 1;
    } else {
      result += character;
    }
  }

  return result;
}

function dollarBodyHeaderEnd(source, startIndex) {
  for (let index = startIndex; index < source.length; index += 1) {
    const character = source[index];
    const dollarTag = character === '$'
      ? source.slice(index).match(/^\$[a-z_][a-z0-9_]*\$|^\$\$/i)?.[0]
      : null;

    if (dollarTag) {
      const headerPrefix = sqlOutsideCommentsAndLiterals(source.slice(startIndex, index));
      assert.match(headerPrefix, /\bas\s*$/i, 'Dollar-quoted function body must follow AS');
      return index + dollarTag.length;
    }

    if (character === "'" || character === '"') {
      const quote = character;
      const backslashEscapes = isEscapeStringPrefix(source, index);
      for (index += 1; index < source.length; index += 1) {
        if (backslashEscapes && source[index] === '\\' && index + 1 < source.length) {
          index += 1;
        } else if (source[index] === quote) {
          if (source[index + 1] === quote) {
            index += 1;
          } else {
            break;
          }
        }
      }
    } else if (character === '-' && source[index + 1] === '-') {
      while (index < source.length && source[index] !== '\n') {
        index += 1;
      }
    } else if (character === '/' && source[index + 1] === '*') {
      let depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source[index] === '/' && source[index + 1] === '*') {
          depth += 1;
          index += 2;
        } else if (source[index] === '*' && source[index + 1] === '/') {
          depth -= 1;
          index += 2;
        } else {
          index += 1;
        }
      }
      assert.equal(depth, 0, 'Unclosed SQL block comment before function body');
      index -= 1;
    }
  }

  throw new Error('Public function must have a bounded dollar-quoted body');
}

function stripTopLevelDefault(argument) {
  let depth = 0;
  let quote = null;
  let backslashEscapes = false;

  for (let index = 0; index < argument.length; index += 1) {
    const character = argument[index];

    if (quote) {
      if (backslashEscapes && character === '\\' && index + 1 < argument.length) {
        index += 1;
      } else if (character === quote) {
        if (argument[index + 1] === quote) {
          index += 1;
        } else {
          quote = null;
          backslashEscapes = false;
        }
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      backslashEscapes = isEscapeStringPrefix(argument, index);
    } else if (character === '(' || character === '[') {
      depth += 1;
    } else if (character === ')' || character === ']') {
      depth -= 1;
    } else if (depth === 0 && character === '=') {
      return argument.slice(0, index).trim();
    } else if (
      depth === 0
      && argument.slice(index).match(/^default(?:\s|$)/i)
      && (index === 0 || /\s/.test(argument[index - 1]))
    ) {
      return argument.slice(0, index).trim();
    }
  }

  return argument.trim();
}

const unnamedTypeLeads = new Set([
  'bigint',
  'bigserial',
  'bit',
  'boolean',
  'bool',
  'box',
  'bytea',
  'character',
  'cidr',
  'date',
  'decimal',
  'double',
  'inet',
  'int',
  'int2',
  'int4',
  'int8',
  'integer',
  'interval',
  'json',
  'jsonb',
  'money',
  'numeric',
  'real',
  'record',
  'serial',
  'smallint',
  'smallserial',
  'text',
  'time',
  'timestamp',
  'timestamptz',
  'timetz',
  'uuid',
  'varchar',
  'xml'
]);

function normalizeIdentityType(type) {
  return type
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/\s*([()[\],])\s*/g, '$1')
    .replace(/^int2$/, 'smallint')
    .replace(/^int4$/, 'integer')
    .replace(/^int8$/, 'bigint')
    .replace(/^int$/, 'integer')
    .replace(/^smallserial$/, 'smallint')
    .replace(/^serial$/, 'integer')
    .replace(/^bigserial$/, 'bigint')
    .replace(/^bool$/, 'boolean')
    .replace(/^float4$/, 'real')
    .replace(/^float8$/, 'double precision')
    .replace(/^decimal(?=$|\()/, 'numeric')
    .replace(/^timestamp with time zone$/, 'timestamptz')
    .replace(/^timestamp without time zone$/, 'timestamp')
    .replace(/^time with time zone$/, 'timetz')
    .replace(/^time without time zone$/, 'time')
    .replace(/^character varying(?=$|\()/, 'varchar');
}

function identityArgumentTypes(argumentList, declaration = false) {
  return splitTopLevel(stripSqlComments(argumentList)).flatMap((rawArgument) => {
    let argument = stripTopLevelDefault(rawArgument);
    const mode = argument.match(/^(inout|in|out|variadic)\s+/i)?.[1]?.toLowerCase();
    argument = argument.replace(/^(?:inout|in|out|variadic)\s+/i, '').trim();

    if (mode === 'out') {
      return [];
    }

    if (declaration) {
      const firstToken = argument.match(/^("[^"]+"|[a-z_][a-z0-9_$]*)/i)?.[1];
      const unquotedFirstToken = firstToken?.replace(/^"|"$/g, '').toLowerCase();
      const remainder = firstToken ? argument.slice(firstToken.length).trim() : '';
      const isUnnamedType = unquotedFirstToken
        && (unnamedTypeLeads.has(unquotedFirstToken) || firstToken.includes('.'));

      if (remainder && !isUnnamedType) {
        argument = remainder;
      }
    }

    return [normalizeIdentityType(argument)];
  });
}

function publicFunctionDefinitions(sql) {
  const inspectableSql = sqlOutsideCommentsAndLiterals(sql);
  const pattern = /create\s+(?:or\s+replace\s+)?function\s+(public\.[a-z0-9_]+)\s*\(/gi;
  return [...inspectableSql.matchAll(pattern)].map((match) => {
    const openIndex = match.index + match[0].lastIndexOf('(');
    const argumentsList = parenthesizedBody(sql, openIndex);
    const headerEnd = dollarBodyHeaderEnd(sql, argumentsList.closeIndex + 1);
    return {
      index: match.index,
      name: match[1].toLowerCase(),
      identityTypes: identityArgumentTypes(argumentsList.body, true),
      header: inspectableSql.slice(match.index, headerEnd)
    };
  });
}

const isSecurityDefiner = (definition) => /\bsecurity\s+definer\b/i.test(definition.header);
const hasPinnedSearchPath = (definition) => /\bset\s+search_path\s+(?:to|=)/i.test(definition.header);

function hasExactPublicExecuteRevoke(sql, definition) {
  const inspectableSql = sqlOutsideCommentsAndLiterals(sql);
  const pattern = /revoke\s+all(?:\s+privileges)?\s+on\s+function\s+(public\.[a-z0-9_]+)\s*\(/gi;

  for (const match of inspectableSql.matchAll(pattern)) {
    const openIndex = match.index + match[0].lastIndexOf('(');
    const argumentsList = parenthesizedBody(inspectableSql, openIndex);
    const tail = inspectableSql.slice(argumentsList.closeIndex + 1);
    const roles = tail.match(/^\s+from\s+([^;]+)\s*;/i)?.[1]
      ?.split(',')
      .map((role) => role.trim().replace(/^"|"$/g, '').toLowerCase());
    const identityTypes = identityArgumentTypes(argumentsList.body, true);

    if (
      match.index > definition.index
      &&
      match[1].toLowerCase() === definition.name
      && identityTypes.length === definition.identityTypes.length
      && identityTypes.every((type, index) => type === definition.identityTypes[index])
      && roles?.includes('public')
    ) {
      return true;
    }
  }

  return false;
}

async function pendingMigrations() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  return plan.items.filter(({ kind }) => kind === 'pending');
}

test('all pending migrations and SQL acceptance suites have atomic boundaries', async () => {
  const pending = await pendingMigrations();
  assert.equal(pending.length, 130);
  const mappedSuites = new Map(pending.map((migration) => [
    migrationIdentity(migration),
    rollbackSuiteFor(migration)
  ]));
  assert.equal(mappedSuites.size, pending.length, 'every pending migration identity must be unique');
  assert.deepEqual(
    [...mappedSuites].filter(([, testPath]) => !testPath),
    [],
    'every unique pending migration identity must map to a rollback suite'
  );

  for (const migration of pending) {
    const migrationSql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    assert.equal(statementCount(migrationSql, 'begin'), 1, `${migration.name} must begin one transaction`);
    assert.equal(statementCount(migrationSql, 'commit'), 1, `${migration.name} must commit one transaction`);

    const testPath = mappedSuites.get(migrationIdentity(migration));
    assert.ok(testPath, `${migrationIdentity(migration)} must have a mapped rollback suite`);
    const testSql = await readFile(path.join(repoRoot, testPath), 'utf8');
    assert.doesNotMatch(
      testSql,
      /^\\\\ir\s/m,
      `${testPath} must use one literal backslash for psql include commands`
    );
    assert.equal(statementCount(testSql, 'begin'), 1, `${testPath} must begin one transaction`);
    assert.equal(statementCount(testSql, 'rollback'), 1, `${testPath} must roll back its fixture changes`);
  }
});

test('every newly created public table has RLS and an explicit browser-role ACL', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const tables = [...sql.matchAll(/create table(?: if not exists)?\s+(public\.[a-z0-9_]+)/gi)]
      .map((match) => match[1]);

    for (const table of tables) {
      const escaped = escapeRegExp(table);
      assert.match(
        sql,
        new RegExp(`alter\\s+table\\s+${escaped}\\s+enable\\s+row\\s+level\\s+security`, 'i'),
        `${migration.name}: ${table} must enable RLS`
      );
      assert.match(
        sql,
        new RegExp(`(?:grant|revoke)[\\s\\S]{0,240}?on(?:\\s+table)?[\\s\\S]{0,240}?${escaped}`, 'i'),
        `${migration.name}: ${table} must declare its browser-role ACL explicitly`
      );
    }
  }
});

test('pending public SECURITY DEFINER RPCs pin search_path and revoke default execution', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const definitions = publicFunctionDefinitions(sql).filter(isSecurityDefiner);

    for (const definition of definitions) {
      const signature = `${definition.name}(${definition.identityTypes.join(',')})`;
      assert.ok(
        hasPinnedSearchPath(definition),
        `${migration.name}: ${signature} must pin search_path`
      );
      assert.ok(
        hasExactPublicExecuteRevoke(sql, definition),
        `${migration.name}: ${signature} must revoke PostgreSQL's default execute grant from PUBLIC on the exact overload`
      );
    }
  }
});

test('SECURITY DEFINER preflight rejects wrong-role and wrong-overload revocations', () => {
  const declarationSql = `
    create or replace function public.example_rpc(
      p_business uuid,
      p_amount numeric(12, 2) default 0
    )
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const declaration = publicFunctionDefinitions(declarationSql)[0];
  const withDeclaration = (aclSql) => `${declarationSql}\n${aclSql}`;

  assert.ok(
    hasExactPublicExecuteRevoke(
      withDeclaration(
        'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, public, anon;'
      ),
      declaration
    ),
    'an exact overload revocation that includes PUBLIC must pass'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(
        'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;'
      ),
      declaration
    ),
    false,
    'a revocation that omits PUBLIC must fail'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration('revoke all on function public.example_rpc(uuid) from public;'),
      declaration
    ),
    false,
    'a PUBLIC revocation on the wrong overload must fail'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        revoke all on function public.example_rpc(uuid) from public;
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'separate wrong-overload and wrong-role statements must not combine into a false pass'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        -- revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;
        select 'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;';
        do $acl$
        begin
          perform 'revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;';
        end
        $acl$;
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'comments, string literals, and dollar-quoted bodies cannot spoof a PUBLIC revocation'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(`
        /*
          outer comment
          /* inner comment */
          revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public;
        */
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'a fake exact revoke inside nested PostgreSQL block comments cannot satisfy the guard'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(
      withDeclaration(String.raw`
        select E'kept open by \' revoke all on function public.example_rpc(uuid, numeric(12, 2)) from public; still literal';
        revoke all on function public.example_rpc(uuid, numeric(12, 2)) from authenticated, anon;
      `),
      declaration
    ),
    false,
    'a fake exact revoke after an escaped quote inside a PostgreSQL E-string cannot satisfy the guard'
  );

  const plainCreateSql = `
    create function public.plain_create_rpc(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const plainCreate = publicFunctionDefinitions(plainCreateSql)[0];
  assert.equal(plainCreate?.name, 'public.plain_create_rpc', 'plain CREATE FUNCTION must be inspected');
  assert.equal(
    hasExactPublicExecuteRevoke(
      `${plainCreateSql}
       revoke all on function public.plain_create_rpc(uuid) from authenticated, anon;`,
      plainCreate
    ),
    false,
    'a plain CREATE FUNCTION cannot bypass the PUBLIC revocation requirement'
  );

  const contaminationDefinitions = publicFunctionDefinitions(`
    create function public.safe_invoker(p_business uuid)
    returns void
    language plpgsql
    security invoker
    as $$ begin null; end; $$;

    create function app.internal_definer(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;

    create function public.missing_path_definer(p_business uuid)
    returns void
    language plpgsql
    security definer
    as $$ begin null; end; $$;

    create function public.later_safe_invoker(p_business uuid)
    returns void
    language plpgsql
    security invoker
    set search_path = ''
    as $$ begin null; end; $$;
  `);
  assert.equal(
    contaminationDefinitions.filter(isSecurityDefiner).map(({ name }) => name).join(','),
    'public.missing_path_definer',
    'an intervening app definer must not reclassify a public invoker'
  );
  assert.equal(
    hasPinnedSearchPath(contaminationDefinitions.find(({ name }) => name === 'public.missing_path_definer')),
    false,
    'a public definer cannot borrow search_path from a later function header'
  );

  const commentedTokenSql = `
    create /* discovery gap */ function public.commented_tokens_rpc(p_business uuid)
    returns void
    language plpgsql
    security /* classification gap */ definer
    set /* header gap */ search_path = ''
    as $$ begin null; end; $$;
    revoke all on function public.commented_tokens_rpc(uuid) from public;
  `;
  const commentedTokenDefinition = publicFunctionDefinitions(commentedTokenSql)[0];
  assert.equal(
    commentedTokenDefinition?.name,
    'public.commented_tokens_rpc',
    'comments between CREATE FUNCTION tokens cannot hide a public function'
  );
  assert.equal(
    isSecurityDefiner(commentedTokenDefinition),
    true,
    'comments between SECURITY DEFINER tokens cannot hide the authority mode'
  );
  assert.equal(
    hasPinnedSearchPath(commentedTokenDefinition),
    true,
    'comments in a pinned search_path header must not prevent exact inspection'
  );
  assert.equal(
    hasExactPublicExecuteRevoke(commentedTokenSql, commentedTokenDefinition),
    true,
    'the exact active post-definition PUBLIC revocation remains provable'
  );

  const recreatedSql = `
    revoke all on function public.recreated_rpc(uuid) from public;
    drop function public.recreated_rpc(uuid);
    create function public.recreated_rpc(p_business uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
    as $$ begin null; end; $$;
  `;
  const recreatedDefinition = publicFunctionDefinitions(recreatedSql)[0];
  assert.equal(
    hasExactPublicExecuteRevoke(recreatedSql, recreatedDefinition),
    false,
    'a revoke before DROP and plain CREATE cannot secure the newly created function ACL'
  );
});

test('v27 establishes the tenant-safe products parent key before its composite FK', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/migrations/20260720_frenly_v27_rich_rewards.sql'),
    'utf8'
  );
  const parentKey = sql.search(/products_id_business_uk\s+unique\s*\(\s*id\s*,\s*business_id\s*\)/i);
  const childReference = sql.search(/references\s+public\.products\s*\(\s*id\s*,\s*business_id\s*\)/i);

  assert.notEqual(parentKey, -1, 'v27 must add products(id,business_id) as a unique parent key');
  assert.notEqual(childReference, -1, 'v27 must keep the tenant-safe product eligibility FK');
  assert.ok(parentKey < childReference, 'the products parent key must exist before the FK is created');
});

test('v40 adversarial fixtures never bypass every database trigger', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/tests/v40_staff_reversal_workflows.sql'),
    'utf8'
  );

  assert.doesNotMatch(sql, /session_replication_role/i);
  assert.match(
    sql,
    /disable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 may disable only the named provenance immutability trigger'
  );
  assert.match(
    sql,
    /enable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 must restore the named provenance immutability trigger'
  );
  assert.doesNotMatch(sql, /disable trigger all/i);
});
