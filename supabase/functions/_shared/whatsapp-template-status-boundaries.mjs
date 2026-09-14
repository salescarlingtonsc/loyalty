/* nestly_v899 — what Meta's answer means for our gate, with no I/O in sight.
 *
 * Same split as v517's whatsapp-send-boundaries.mjs and v894's otp boundaries: the edge
 * function that imports this is plumbing, and the mapping below is the part worth testing.
 *
 * THE ONE RULE THIS FILE EXISTS TO ENFORCE: a template may read 'approved' in
 * whatsapp_template_registry_v551 only when Meta says APPROVED. Every other answer —
 * including answers Meta invents after this was written — must land on a status the
 * sender refuses. v898 was the cost of getting that wrong in the lenient direction
 * (fail-closed, two reminders silently never sent); getting it wrong in the other
 * direction would mean sending on a template Meta has paused, which is an account
 * risk, not an inconvenience.
 */

// Meta's documented template statuses, mapped onto the five this registry allows
// (draft | submitted | approved | rejected | paused).
//
// PENDING/IN_APPEAL are genuinely "submitted": we are waiting on a human at Meta.
// REJECTED is its own thing and worth keeping distinct, because it needs an edit, not a wait.
// Everything else collapses to 'paused', which is this vocabulary's only "the row exists and
// must not be sent" state — including DELETED, where 'paused' is an imperfect but SAFE fit and
// is reported separately by reconcileTemplateStatuses so nobody has to infer it from the status.
const META_STATUS_MAP = new Map([
  ['APPROVED', 'approved'],
  ['PENDING', 'submitted'],
  ['IN_APPEAL', 'submitted'],
  ['PENDING_REVIEW', 'submitted'],
  ['REJECTED', 'rejected'],
  ['PAUSED', 'paused'],
  ['DISABLED', 'paused'],
  ['LIMIT_EXCEEDED', 'paused'],
  ['DELETED', 'paused'],
  ['PENDING_DELETION', 'paused'],
]);

export function registryStatusForMeta(metaStatus) {
  const key = String(metaStatus ?? '').trim().toUpperCase();
  if (!key) return { status: 'paused', recognised: false };
  const mapped = META_STATUS_MAP.get(key);
  // An unrecognised status is NOT left alone and is NOT guessed at. It becomes 'paused' — the
  // conservative end of the vocabulary — and is named in the result so a new Meta state shows up
  // as a line in the response rather than as a template that quietly stopped or started sending.
  return mapped ? { status: mapped, recognised: true } : { status: 'paused', recognised: false };
}

/* Turn Meta's template list into the observation set the reconciling RPC takes, judged against
 * the registry rows we actually hold.
 *
 * `metaRows`  - [{ name, status, id }] straight from the Graph API.
 * `registry`  - [{ template_key, meta_name, status }] as the database currently reads.
 *
 * Returns { observations, absentAtMeta, unrecognised, ignored } where `observations` is what the
 * RPC is given. Nothing here writes, and nothing here invents a row: a template Meta knows about
 * that this registry does not is IGNORED, because the definition authority is the TEMPLATES array
 * in whatsapp-admin-templates and the migrations, never whatever happens to exist in the WABA.
 */
export function reconcileTemplateStatuses(metaRows, registry) {
  const rows = Array.isArray(metaRows) ? metaRows : [];
  const known = new Map(
    (Array.isArray(registry) ? registry : [])
      .filter((row) => row && typeof row.meta_name === 'string')
      .map((row) => [row.meta_name, row]),
  );

  const observations = [];
  const unrecognised = [];
  const ignored = [];
  const seen = new Set();

  for (const row of rows) {
    const name = typeof row?.name === 'string' ? row.name : '';
    if (!name) continue;
    if (!known.has(name)) { ignored.push(name); continue; }
    // Meta lists one row per language. Peekaa registers one language per template today, so a
    // second row for the same name is a language we do not hold: skip it rather than let an
    // unregistered language decide the gate for the one we do hold.
    if (seen.has(name)) continue;
    seen.add(name);

    const mapped = registryStatusForMeta(row?.status);
    if (!mapped.recognised) unrecognised.push({ meta_name: name, meta_status: String(row?.status ?? '') });
    observations.push({
      meta_name: name,
      status: mapped.status,
      meta_template_id: typeof row?.id === 'string' && row.id ? row.id : null,
    });
  }

  /* A row we hold that Meta did not list no longer exists there, so it must not stay sendable —
     EXCEPT when it is still 'draft', which is the ordinary state of a template written but not yet
     submitted (v894's signup_otp is exactly this). Forcing that to 'paused' would turn "not sent
     yet" into "something went wrong". */
  const absentAtMeta = [];
  for (const [name, row] of known) {
    if (seen.has(name)) continue;
    if (row.status === 'draft') continue;
    absentAtMeta.push(name);
    observations.push({ meta_name: name, status: 'paused', meta_template_id: null });
  }

  return { observations, absentAtMeta, unrecognised, ignored };
}
