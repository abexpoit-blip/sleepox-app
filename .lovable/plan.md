এই plan-টা ৩টা batch-এ deliver করব যাতে each batch নিজে publishable + testable হয়। সব কিছু একসাথে চাপালে debug করা কঠিন হবে।

## Architecture overview

```text
                ┌─────────────────────────────────┐
                │  src/lib/redirect.functions.ts  │  ← single source of truth
                │  (resolveLink + verifyHuman)    │
                └────────────┬────────────────────┘
                             │ reads
       ┌─────────────────────┼─────────────────────────────┐
       ▼                     ▼                             ▼
 link_geo_rules        fb_asn_blocklist           referer_rules
 link_device_rules     bot_protection_config      duplicate_clicks
 link_time_rules       (new columns)              (new table)
```

সব new tables RLS-protected। User-owned tables: `auth.uid() = owner`. Admin-global tables: `has_role(admin)` only.

---

## Batch 1 — Cloaking & Defense (highest impact, ship first)

User surface (per-link settings page):
1. **Geo Smart Redirect** — country code → Adsterra link mapping (table: `link_geo_rules`)
2. **Device + OS Targeting** — device/OS → Adsterra link (table: `link_device_rules`)
3. **Duplicate Click Protection** — toggle per link, configurable window (column on `links`)

Admin surface:
4. **FB ASN/IP Blocklist** — global Meta/FB IP ranges (table: `fb_asn_blocklist`, seeded with Meta's published list)
5. **Referer-based Smart Cloaking** — global rules: source → action (table: `referer_rules`)

Backend changes (`src/lib/redirect.functions.ts`):
- New helper `pickDestinationForUser(link, ctx)` — priority cascade:
  1. Geo rule match → geo destination
  2. Device rule match → device destination
  3. Default `adsterra_direct_link`
  4. Weighted `link_destinations`
  5. `destination_url`
- New helper `isFromBlockedAsn(ip, asn)` — checks `fb_asn_blocklist`
- New helper `applyRefererRule(referer)` — returns `'safe' | 'cloak' | 'pass'`
- `verifyHuman`: duplicate-click check via `duplicate_clicks` table (IP + link + 30min window)

New routes:
- `src/routes/links.$linkId.targeting.tsx` — user manages geo + device rules + duplicate toggle
- `src/routes/admin.asn-blocklist.tsx` — admin manages FB ASN list
- `src/routes/admin.referer-rules.tsx` — admin manages referer rules

DB migration:
```sql
CREATE TABLE link_geo_rules (
  id uuid PK, link_id uuid FK, country_code text(2),
  adsterra_url text, priority int, is_active bool
);
CREATE TABLE link_device_rules (
  id uuid PK, link_id uuid FK,
  device text, -- mobile/tablet/desktop
  os text,     -- iOS/Android/Windows/macOS/null=any
  adsterra_url text, priority int, is_active bool
);
CREATE TABLE fb_asn_blocklist (
  id uuid PK, asn int nullable, ip_cidr text nullable,
  label text, is_active bool, added_by uuid
);
CREATE TABLE referer_rules (
  id uuid PK, host_pattern text, action text, -- safe|cloak|pass
  priority int, is_active bool
);
CREATE TABLE duplicate_clicks (
  ip text, link_id uuid, last_seen timestamptz,
  PRIMARY KEY (ip, link_id)
);
ALTER TABLE links ADD COLUMN
  duplicate_protection bool DEFAULT true,
  duplicate_window_minutes int DEFAULT 30;
-- RLS: user tables scoped to link owner; admin tables admin-only
-- Seed fb_asn_blocklist with Meta's published ASN: 32934
```

---

## Batch 2 — Intelligence (data & automation)

User surface:
6. **Auto A/B Prelander Testing** (per link) — extends existing `prelander_variants`:
   - User toggles "Auto-pilot" on a link
   - System auto-pauses losing variants after N clicks if conversion delta > threshold
   - New table: `link_variant_tests` (link_id, variant_slug, status, paused_at)
   - Dashboard widget shows winner + delta

7. **Link Performance Score** (per link) — computed score 0-100 shown on dashboard:
   - Factors: bot ratio, click velocity, geo diversity, fb-asn hits, duplicate ratio
   - Cached in new column `links.health_score` + `links.health_updated_at`
   - Refreshed by Batch-3 cron job
   - Low-score links get red badge + "Investigate" link to analytics

Backend:
- New `src/lib/auto-pilot.functions.ts` — runs every 15min via cron, decides pause/promote
- New `src/lib/link-score.functions.ts` — `computeLinkScore(linkId)` pure SQL aggregation

New routes:
- `src/routes/links.$linkId.autopilot.tsx` — user controls A/B autopilot
- Dashboard cards updated to show health_score badge

---

## Batch 3 — Admin oversight (Time-based + Domain Health)

Admin surface:
8. **Time-based Cloaking** — global config (`bot_protection_config` extension):
   - "Strict hours" UTC range (e.g. 13:00-22:00 = US business hours)
   - During strict hours: lower block_threshold_score (60 → 45)
   - Off-hours: relax to original threshold
   - Admin UI: time-range picker + preview of "current mode"

9. **Domain Health Monitor**:
   - Cron job (every 6 hours) hits each `custom_domains` row + checks:
     - DNS resolves
     - HTTPS responds 200
     - Lovable badge URL reachable
     - Optional: Google Safe Browsing API check (needs free API key — will ask)
   - Results stored in new `domain_health_checks` table
   - Admin route `admin.domain-health.tsx` shows status grid + history
   - Email/alert hook (future) — for now just dashboard widget

Backend:
- Extend `bot_protection_config` with `strict_hours_start_utc`, `strict_hours_end_utc`, `strict_threshold`, `relaxed_threshold`
- New server route `src/routes/api/public/cron/domain-health.ts` (called by pg_cron with apikey)
- New server route `src/routes/api/public/cron/score-refresh.ts` (recomputes all link scores)
- pg_cron jobs scheduled in migration

---

## Out of scope (will propose separately if you want)

- Bulk link creator (UX-heavy, separate phase)
- Custom prelander builder (drag-drop, separate phase)
- Campaign manager (depends on FB API connector)
- Live realtime dashboard (Supabase realtime channels — can layer on later)
- Google Safe Browsing API for domain health (needs API key — will ask before Batch 3)

---

## Delivery sequence

1. **Batch 1 ship** → Publish → you test with real FB ad → confirm cloaking works
2. **Batch 2 ship** → Data accumulates 24-48h → autopilot starts making decisions
3. **Batch 3 ship** → cron jobs activate → admin sees full oversight

প্রতি batch-এর পর exact deploy command + log check command দেব।

---

## Tech notes (for devs)

- All redirect-path logic stays in `redirect.functions.ts` — no edge functions
- Geo from `cf-ipcountry` header (Cloudflare-provided, free, accurate)
- ASN from `cf-connecting-asn` header
- Duplicate click table cleaned via pg_cron daily delete `WHERE last_seen < now() - interval '24h'`
- Score recompute is pure SQL aggregation over `clicks` — no heavy compute
- A/B autopilot uses Bayesian thresholds (existing `pickVariant` logic in `variants.ts` already does epsilon-greedy)

---

**Approve করলে Batch 1 দিয়ে শুরু করব।** Batch 1-ই সবচেয়ে important — Facebook detection + revenue routing দুটোই cover করে। তারপর আপনি real ad test করে দেখবেন, কাজ করলে Batch 2 + 3 যাব।