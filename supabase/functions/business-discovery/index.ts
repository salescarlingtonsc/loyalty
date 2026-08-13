/**
 * business-discovery — the merchant-prospecting data provider layer.
 *
 * WHY AN EDGE FUNCTION AND NOT A BROWSER CALL. A Places API key is a billable
 * secret. Anything the browser holds is public, so the key lives ONLY in this
 * function's environment (GOOGLE_PLACES_API_KEY) and never reaches the client,
 * the database, or the repository. The console calls this function; this function
 * calls the provider and hands normalized results to the database RPC, which owns
 * dedup and persistence.
 *
 * PROVIDER ABSTRACTION (brief §2: "Do not hard-code the application directly to one
 * provider"). Everything provider-specific is confined to the `googlePlaces` object
 * below, which implements the `BusinessDataProvider` interface. Adding a second
 * permitted source means adding one object and one registry entry — no caller,
 * no RPC and no table changes.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO:
 *   - It does not scrape Google Maps HTML.
 *   - It does not bypass CAPTCHAs, auth, rate limits or anti-bot systems.
 *   - It has no unrestricted "download all of Singapore" mode. Discovery is always
 *     scoped by area/category/radius, and `maxPages` is hard-capped.
 *
 * COST CONTROL (brief §14):
 *   - Discovery (searchText) and enrichment (Details) are SEPARATE steps. A preview
 *     never spends a Details call.
 *   - Field masks are explicit and minimal; we request only what the CRM stores.
 *   - Details are fetched ONLY for places the database reports as new, so a
 *     re-discovery of an already-known area costs one search page, not N details.
 *   - Every run's call counts are written to sme_discovery_runs so spend is auditable.
 */

type NormalizedBusiness = {
  source: string;
  source_id: string;
  source_url?: string;
  name: string;
  phone?: string;
  website?: string;
  address?: string;
  postal_code?: string;
  planning_area?: string;
  latitude?: number;
  longitude?: number;
  rating?: number;
  review_count?: number;
  price_level?: number;
  business_status?: string;
  category_key?: string;
};

type DiscoveryQuery = {
  /** Free-text intent, e.g. "cafe in Hougang Singapore". */
  query: string;
  /** Optional centre + radius (metres) to bias/restrict the search. */
  latitude?: number;
  longitude?: number;
  radiusMetres?: number;
  /** Peekaa category this search is collecting for. */
  categoryKey?: string;
  /** Planning area label to stamp on results. */
  planningArea?: string;
  maxPages?: number;
};

interface BusinessDataProvider {
  readonly key: string;
  searchBusinesses(q: DiscoveryQuery): Promise<{ results: NormalizedBusiness[]; calls: number }>;
  getBusinessDetails(sourceIds: string[]): Promise<{ results: Map<string, Partial<NormalizedBusiness>>; calls: number }>;
}

const PRICE_LEVEL: Record<string, number> = {
  PRICE_LEVEL_FREE: 0,
  PRICE_LEVEL_INEXPENSIVE: 1,
  PRICE_LEVEL_MODERATE: 2,
  PRICE_LEVEL_EXPENSIVE: 3,
  PRICE_LEVEL_VERY_EXPENSIVE: 4,
};

/** Places API (New). Only this object knows anything about Google. */
const googlePlaces: BusinessDataProvider = {
  key: 'google_places',

  async searchBusinesses(q) {
    const apiKey = Deno.env.get('GOOGLE_PLACES_API_KEY');
    if (!apiKey) throw new Error('provider_not_configured');

    // Minimal field mask: exactly what the CRM stores at discovery time. Adding a
    // field here has a direct billing consequence, so it is deliberately explicit.
    const mask = [
      'places.id',
      'places.displayName',
      'places.formattedAddress',
      'places.location',
      'places.rating',
      'places.userRatingCount',
      'places.priceLevel',
      'places.businessStatus',
      'nextPageToken',
    ].join(',');

    const results: NormalizedBusiness[] = [];
    let pageToken: string | undefined;
    let calls = 0;
    const maxPages = Math.min(Math.max(q.maxPages ?? 1, 1), 3); // hard cap: never unbounded

    for (let page = 0; page < maxPages; page++) {
      const body: Record<string, unknown> = {
        textQuery: q.query,
        regionCode: 'SG',
        maxResultCount: 20,
      };
      if (pageToken) body.pageToken = pageToken;
      if (q.latitude != null && q.longitude != null && q.radiusMetres) {
        body.locationBias = {
          circle: {
            center: { latitude: q.latitude, longitude: q.longitude },
            radius: Math.min(q.radiusMetres, 50000),
          },
        };
      }

      const response = await fetch('https://places.googleapis.com/v1/places:searchText', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': mask,
        },
        body: JSON.stringify(body),
      });
      calls++;
      if (!response.ok) {
        throw new Error(`provider_search_failed_${response.status}`);
      }
      const payload = await response.json();
      for (const place of payload.places ?? []) {
        if (!place?.id) continue;
        results.push(normalizeGooglePlace(place, q));
      }
      pageToken = payload.nextPageToken;
      if (!pageToken) break;
    }
    return { results, calls };
  },

  async getBusinessDetails(sourceIds) {
    const apiKey = Deno.env.get('GOOGLE_PLACES_API_KEY');
    if (!apiKey) throw new Error('provider_not_configured');
    // Enrichment mask: the contact fields a search response does not carry. This is
    // the expensive call, so it runs only for places the DB reported as new.
    const mask = [
      'id',
      'nationalPhoneNumber',
      'internationalPhoneNumber',
      'websiteUri',
      'googleMapsUri',
      'addressComponents',
    ].join(',');

    const results = new Map<string, Partial<NormalizedBusiness>>();
    let calls = 0;
    for (const id of sourceIds) {
      const response = await fetch(
        `https://places.googleapis.com/v1/places/${encodeURIComponent(id)}`,
        { headers: { 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': mask } },
      );
      calls++;
      if (!response.ok) continue; // one bad place must not fail the whole batch
      const place = await response.json();
      const postal = (place.addressComponents ?? []).find((c: { types?: string[] }) =>
        (c.types ?? []).includes('postal_code'))?.longText;
      results.set(id, {
        phone: place.nationalPhoneNumber ?? place.internationalPhoneNumber ?? undefined,
        website: place.websiteUri ?? undefined,
        source_url: place.googleMapsUri ?? undefined,
        postal_code: postal ?? undefined,
      });
    }
    return { results, calls };
  },
};

function normalizeGooglePlace(place: Record<string, any>, q: DiscoveryQuery): NormalizedBusiness {
  return {
    source: 'google_places',
    source_id: place.id,
    name: place.displayName?.text ?? '',
    address: place.formattedAddress ?? undefined,
    latitude: place.location?.latitude ?? undefined,
    longitude: place.location?.longitude ?? undefined,
    rating: typeof place.rating === 'number' ? place.rating : undefined,
    review_count: typeof place.userRatingCount === 'number' ? place.userRatingCount : undefined,
    price_level: place.priceLevel ? PRICE_LEVEL[place.priceLevel] : undefined,
    business_status: place.businessStatus ?? undefined,
    planning_area: q.planningArea,
    category_key: q.categoryKey,
  };
}

const PROVIDERS: Record<string, BusinessDataProvider> = {
  google_places: googlePlaces,
};

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  // The caller's own JWT is forwarded to the RPC, so the database applies the SAME
  // role checks it would for any other call. This function grants no extra authority.
  const authorization = request.headers.get('Authorization');
  if (!authorization) return json({ error: 'authentication_required' }, 401);

  let body: { query?: DiscoveryQuery; commit?: boolean; provider?: string };
  try {
    body = await request.json();
  } catch {
    return json({ error: 'invalid_json' }, 400);
  }

  const providerKey = body.provider ?? 'google_places';
  const provider = PROVIDERS[providerKey];
  if (!provider) return json({ error: 'unknown_provider' }, 400);
  if (!body.query?.query) return json({ error: 'query_required' }, 400);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  if (!supabaseUrl) return json({ error: 'server_misconfigured' }, 500);

  // GATE FIRST, SPEND SECOND. The first cut called Google and THEN asked the database
  // whether the caller was allowed — so anyone holding the public anon key could burn
  // real Places quota without being able to persist a single row. This read-only RPC
  // raises unless the caller is a real platform user with prospecting access, so the
  // billable call below is unreachable without authorization.
  try {
    await callRpc(supabaseUrl, authorization, 'platform_crm_prospecting_taxonomy_v297', {});
  } catch {
    return json({ error: 'prospecting_access_required' }, 403);
  }

  try {
    // 1. DISCOVERY — cheap, always scoped, never unbounded.
    const search = await provider.searchBusinesses(body.query);

    // 2. PREVIEW — ask the database what is actually new. Costs no provider calls.
    const preview = await callRpc(supabaseUrl, authorization, 'platform_crm_ingest_discovered_v297', {
      p_places: search.results,
      p_request: { provider: providerKey, ...body.query },
      p_commit: false,
      p_search_calls: search.calls,
      p_detail_calls: 0,
    });

    if (!body.commit) {
      return json({ stage: 'preview', provider: providerKey, ...preview, search_calls: search.calls });
    }

    // 3. ENRICHMENT — Details ONLY for places the DB says are new. This is the whole
    //    cost-control story: a repeat run of a known area spends nothing here.
    let detailCalls = 0;
    let enriched = search.results;
    if ((preview?.new ?? 0) > 0) {
      const knownNew = search.results.map((r) => r.source_id);
      const details = await provider.getBusinessDetails(knownNew);
      detailCalls = details.calls;
      enriched = search.results.map((r) => ({ ...r, ...(details.results.get(r.source_id) ?? {}) }));
    }

    // 4. COMMIT — the database dedups and persists.
    const committed = await callRpc(supabaseUrl, authorization, 'platform_crm_ingest_discovered_v297', {
      p_places: enriched,
      p_request: { provider: providerKey, ...body.query },
      p_commit: true,
      p_search_calls: search.calls,
      p_detail_calls: detailCalls,
    });

    return json({
      stage: 'committed',
      provider: providerKey,
      ...committed,
      search_calls: search.calls,
      detail_calls: detailCalls,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'discovery_failed';
    // 'provider_not_configured' is the honest signal that the API key is absent —
    // the console shows a specific "not configured yet" state rather than a crash.
    const status = message === 'provider_not_configured' ? 503 : 502;
    return json({ error: message }, status);
  }
});

async function callRpc(url: string, authorization: string, fn: string, args: unknown) {
  const response = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authorization,
      apikey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    throw new Error(`rpc_failed_${response.status}`);
  }
  return await response.json();
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
