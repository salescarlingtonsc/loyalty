# Peekaa UI standard — how to change it, and how to undo it

Owner rulings of 2026-08-18, implemented across seven commits on
`claude/peekaa-ui-ux-audit-lhaa4o`. This file is the operating manual for the
decisions those commits encoded: where each one lives, how to change it, and how
to revert it cleanly.

Line numbers are a convenience and drift. The **anchor strings** do not — search
for those.

---

## 1. The control points

Each ruling has exactly one place to edit. Nothing else in the codebase hardcodes
these values.

| What | File | Anchor to search for |
|---|---|---|
| **Brand red** | `app/index.html` | `--brand-red:` |
| **Layout breakpoints** | `app/index.html` | `LAYOUT BREAKPOINTS (owner ruling` |
| **Compact-shell block** | `app/index.html` | `COMPACT LAYOUT SHELL` |
| **Button variants** | `app/index.html` | `.btn.primary{` |
| **Status words** | `app/app.js` | `const STATUS_WORDS=` |
| **Destructive confirm** | `app/app.js` | `function confirmActionV386` |
| **Delete/Remove aria templates** | `app/app.js` | `deleteItem:Object.freeze` |

### Brand red

```css
--brand-red:#C24135;           /* the brand red */
--brand-red-dark:#9D352C;      /* pressed / hover / gradient end */
--brand-red-soft:#F7DCD7;      /* selected chip + active nav background */
--brand-red-faint:#FDEEEB;     /* large tinted surfaces */
--brand-red-on-dark:#E4776B;   /* accent on a dark ground */
--brand-red-on-dark-2:#F0A199; /* hover step on a dark ground */
```

To change the brand red, edit these six values. `--coral`, `--coral-hover`,
`--red`, `--grad` and the whole `--peekaa-red-*` family are aliases and will
follow. **Do not** reintroduce a second red by editing an alias directly — that
is the exact defect this replaced (business app on `#C24135`, customer app on
`#F06A4F`, 79 rules against one and 45 against the other).

### Layout breakpoints

Two thresholds govern the workspace shell, and only two:

- **≤ 768px** — compact layout: mobile padding, stacked page headers,
  responsive tables, single-column dashboard. iPad portrait sits inside this.
- **≤ 960px** — no room for a persistent rail: sidebar hidden, mobile dock
  shown. iPad portrait and 11″ Pro portrait (834) get the dock; iPad landscape
  (1024) keeps the rail.

`app/pwa.css` carries the iOS zoom guard (`font-size:16px` on inputs) and must
stay on the same 768 threshold. Do not add a third shell threshold —
component-local breakpoints (small-phone tweaks, short viewports, individual
carousels) are per-component and are deliberately left alone.

`app/platform-console.css` keeps its own 760/761. The admin console is a
separate lazily-loaded surface that this audit did not cover.

### Status words

```js
const STATUS_WORDS=Object.freeze({
  on:'On',off:'Off',
  draft:'Draft',scheduled:'Scheduled',live:'Live',ended:'Ended'
});
const statusOnOff=isOn=>isOn?STATUS_WORDS.on:STATUS_WORDS.off;
```

Three axes, kept apart on purpose:

1. **Availability** — "can this be sold or used right now?" → `On` / `Off`.
   Every availability pill reads this through `statusOnOff()`.
2. **Publication** — "can customers see it?" → `Draft → Scheduled → Live →
   Ended`. Promotions already implement this correctly
   (`promotionLifecycleV186`); copy that model for anything new.
3. **Record lifecycle** — "what happened to this record?" → domain words in
   sentence case. Memberships, appointments, gift cards, referrals, bookings,
   waitlist. **Never** map these onto On/Off: "cancelled" is not "off".

A promotion can be *published but not live*, which is why axis 2 cannot collapse
into axis 1. That is the test for whether something belongs on axis 2.

### Terminology

| Use | For | Not |
|---|---|---|
| **Delete** | Ending a record | Retire, Archive, Remove |
| **Remove** | Detaching a link, taking a row out of a form | Delete |
| **Turn on / Turn off** | Availability | Enable/Disable, Pause/Resume |
| **Publish / Unpublish** | Customer visibility, where a draft exists | Turn on/off |
| **Add reward** | Adding a reward | Add gift, Add a new reward, Create reward |
| **Reward** | Anything earned | Gift (a *gift card* is a different product) |

Two deliberate exceptions, both documented at their call site:

- **Bottles keeps "Remove."** Its help text contrasts Remove ("should never have
  been on this list") with Retrieved ("went out with the customer"). The word is
  load-bearing in owner-written copy.
- **Memberships keep "Pause / Resume."** A member's subscription being paused is
  record lifecycle, not availability.

### Destructive confirm

`confirmActionV386(message, {confirmLabel, cancelLabel, danger})` returns a
Promise. It takes the same single string the old native `confirm()` took and
splits it: leading question → dialog title, remainder → explanation.

Three patterns exist, and the split is intentional:

| Pattern | Use for |
|---|---|
| `confirmActionV386` | Every ordinary destructive action. The default. |
| `confirmDeliberateV288` | Irreversible money or tenant-data actions. Adds a typed acknowledgement. |
| Inline `.imp-note` expand | List rows, where the confirm should open under the row rather than over it. |

**Never reintroduce `window.confirm()`.** It cannot be branded, Chrome prefixes
it with "peekaa.asia says…", it reads as a browser error inside the installed
PWA, and it cannot be translated — which is why it spoke English to a workforce
`CLAUDE.md` says may not read English.

---

## 2. Reverting

Every ruling is one commit. They are independent except where noted.

```
a4de29c  Retire the native browser confirm            (ruling 2)
c2c5c36  Apply the terminology standard to actions    (ruling 3)
a234051  One status vocabulary on three axes          (ruling 4)
0151e6b  Give every page header a module icon         (ruling 6)
23119f8  Collapse the workspace shell to two breakpoints (ruling 5)
b0eabf9  Unify the brand red on #C24135               (ruling 1)
fb53345  Fix cosmetic UI inconsistencies              (the earlier CSS pass)
```

### Revert one ruling

```sh
git revert <hash>
npm run bundle-stamp          # only if the commit touched app/app.js
sh <scratch>/regen.sh         # regenerate fixtures + Chrome evidence
npm test
```

### Revert everything back to before this work

```sh
git revert --no-commit a4de29c c2c5c36 a234051 0151e6b 23119f8 b0eabf9 fb53345
git commit
```

### Order matters in two places

- **Ruling 2 depends on ruling 3.** The bundle-delete confirm copy says "use
  Turn off instead", which ruling 3 renamed from "Disable". Reverting 3 alone
  leaves that sentence naming a button that no longer exists. Revert 2 first, or
  revert both.
- **Ruling 6 changed `app/app.js`,** so reverting it needs
  `npm run bundle-stamp` to regenerate the surface bundles. Same for rulings 2,
  3 and 4.

### Change one value instead of reverting

Usually better than a revert. Editing `--brand-red`, `STATUS_WORDS` or
`confirmActionV386` changes every consuming site at once, which is the entire
point of routing them through one definition.

---

## 3. Regenerating fixtures after any UI change

Eight browser fixtures embed a copy of the production CSS plus its SHA-256, and
two of them compare against **captured Chrome measurements**. Any change to
`app/index.html` CSS or to `app/app.js` render functions invalidates them.

```sh
for g in tests/browser/generate-*.mjs; do node "$g"; done
# then, with a static server on :4173 serving the repo root:
PLAYWRIGHT_EXECUTABLE_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome \
  node tests/browser/verify-v104-promotions-visual.mjs
PLAYWRIGHT_EXECUTABLE_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome \
  node tests/browser/verify-v142-connect-paynow.mjs
```

Two fixtures — `reward-overview-owner-visual.html` and
`v181-onboarding-board.html` — were **already stale before this work** and are
deliberately excluded. Regenerating them sweeps ~400 unrelated lines into your
diff. They are worth a separate look.

---

## 4. Known state at the time of writing

**Test suite:** 3154 passing, 3 failing. All three fail identically on the base
commit and are unrelated to this work:

- `W6I2 E3 turning Referral OFF disables referral_programs`
- `every discovered writer identity is accounted for in the registry`
- `every value-impacting discovered identity is a curated writer`

One further test (`store association generator fails closed`) is order-dependent
in the full-suite run and passes in isolation on both the base commit and this
branch.

**Follow-up owed:** "Turn on" / "Turn off" have no zh-CN or Malay translation and
fall back to English, exactly as they already did in Grow. Ruling 3 widened that
gap slightly. The strings need a native speaker, not a guess. Everything else the
rulings touched either reuses existing verified translations or was already
English-only.

---

## 5. What is NOT done

These were in the audit and remain open — no decision was taken on them:

- **Money column alignment.** `class="num"` (right-align + tabular numerals)
  exists in the CSS and is used **zero** times. Business Insights right-aligns
  20 cells inline; Sales and Daily report left-align money in bare `<td>`.
- **KPI tiles.** Three implementations (`.card.kpi`, `.card.kpi.v150-kpi`,
  `.dashboard-metric.kpi`) and a loading skeleton that does not match the tile
  that replaces it, so Dashboard and Waitlist visibly jump on load.
- **`CUI.status` and `CUI.field`** are still used zero times against 177
  hand-written pills and ~58 hand-written forms. Ruling 4 fixed the *words*; the
  *component* consolidation is still open.
- **211 hex colours → ~28.** Ruling 1 fixed the brand red. The ~32 near-identical
  warm tints, the five greens and the token-set naming (`--biz-*` / `--cust-*`)
  are untouched.
- **Typography scale.** ~61 distinct font sizes; the proposed 7-size scale is not
  implemented.
- **Spacing.** `--space-1…6` are defined and used zero times.
- **Component duplication.** 10 modal implementations, 4 mobile gutter
  conventions, 6+ tab implementations, 23 icon sizes.
- **Customer home surface.** The `-v343/344/346` series is 333 of the 400
  version-suffixed classes and holds nearly every selector declared 3+ times.
  Biggest single consolidation win; best done last, once the tokens are settled.

Full findings: the audit report artifact, published 2026-08-18.
