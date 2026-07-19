export const SLUG_PATTERN = /^[a-z0-9][a-z0-9-]{0,62}$/;
export const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const PHONE_PATTERN = /^\+[1-9][0-9]{7,14}$/;
export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function normalizeOriginList(value = '') {
  return [...new Set(value.split(',').map((origin) => origin.trim()).filter(Boolean))];
}

export function validJoinPayload(body) {
  return !!body && SLUG_PATTERN.test(String(body.slug || ''))
    && String(body.name || '').trim().length >= 2
    && String(body.name || '').trim().length <= 100
    && /^[3689][0-9]{7}$/.test(String(body.phone || ''))
    && (body.consent === undefined || typeof body.consent === 'boolean')
    && (!body.email || (String(body.email).length <= 254 && EMAIL_PATTERN.test(String(body.email))));
}

export function validBookingPayload(body) {
  const party = Number(body?.party);
  const preferred = Date.parse(String(body?.preferred || ''));
  return !!body && SLUG_PATTERN.test(String(body.slug || ''))
    && String(body.name || '').trim().length >= 2
    && String(body.name || '').trim().length <= 100
    && Number.isInteger(party) && party >= 1 && party <= 50
    && Number.isFinite(preferred)
    && UUID_PATTERN.test(String(body.submission_id || ''))
    && (!body.service || UUID_PATTERN.test(String(body.service)))
    && (!body.table_type || UUID_PATTERN.test(String(body.table_type)))
    && (body.consent === undefined || typeof body.consent === 'boolean')
    && String(body.notes || '').length <= 1000
    && (!!body.email || !!body.phone)
    && (!body.email || (String(body.email).length <= 254 && EMAIL_PATTERN.test(String(body.email))))
    && (!body.phone || PHONE_PATTERN.test(String(body.phone)));
}

export function validManagePayload(body) {
  if (!body || !TOKEN_PATTERN.test(String(body.token || ''))) return false;
  if (body.action === 'lookup') return true;
  if (body.action !== 'change' || !['cancel', 'reschedule'].includes(body.kind)) return false;
  if (!UUID_PATTERN.test(String(body.submission_id || ''))) return false;
  if (String(body.note || '').length > 500) return false;
  if (body.kind === 'cancel') return !body.proposed;
  return Number.isFinite(Date.parse(String(body.proposed || '')));
}
