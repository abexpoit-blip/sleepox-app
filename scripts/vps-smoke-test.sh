#!/usr/bin/env bash
# VPS smoke test: redirect curl + DB verification in one shot.
#
# Usage (run from your local machine):
#   ./scripts/vps-smoke-test.sh <short_code>
#   ./scripts/vps-smoke-test.sh esrs7j
#
# Optional env overrides:
#   VPS_HOST   (default: 75.119.144.171)
#   VPS_USER   (default: root)
#   APP_URL    (default: http://localhost:3000)   # URL *inside* the VPS
#   DB_CONT    (default: supabase-db)
#   DB_USER    (default: postgres)
#   DB_NAME    (default: postgres)

set -euo pipefail

SHORT="${1:-esrs7j}"
VPS_HOST="${VPS_HOST:-75.119.144.171}"
VPS_USER="${VPS_USER:-root}"
APP_URL="${APP_URL:-http://localhost:3000}"
DB_CONT="${DB_CONT:-supabase-db}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

UA_DESKTOP='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
UA_FB='Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/96.0.4664.45 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/400.0.0.0.0;]'
UA_BOT='Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'

echo "=== VPS smoke test: /r/${SHORT} on ${VPS_HOST} ==="

ssh "${VPS_USER}@${VPS_HOST}" bash -s -- \
  "$SHORT" "$APP_URL" "$DB_CONT" "$DB_USER" "$DB_NAME" \
  "$UA_DESKTOP" "$UA_FB" "$UA_BOT" <<'REMOTE'
set -euo pipefail
SHORT="$1"; APP_URL="$2"; DB_CONT="$3"; DB_USER="$4"; DB_NAME="$5"
UA_DESKTOP="$6"; UA_FB="$7"; UA_BOT="$8"

echo "--- health: HEAD /r/${SHORT} ---"
curl -sI "${APP_URL}/r/${SHORT}" | head -3 || true

hit() {
  local label="$1" ua="$2"
  echo "--- hit [${label}] ---"
  curl -s -o /dev/null -w "  status=%{http_code} redirect=%{redirect_url}\n" \
    -A "$ua" -H "Accept-Language: en-US,en;q=0.9" "${APP_URL}/r/${SHORT}"
}

hit "desktop"  "$UA_DESKTOP"
hit "facebook" "$UA_FB"
hit "bot"      "$UA_BOT"

sleep 1

echo "--- db: last 5 clicks ---"
docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -At -F '|' -c "
  SELECT to_char(created_at,'HH24:MI:SS') AS t,
         COALESCE(bot_score::text,'-')     AS score,
         challenge_passed                  AS passed,
         COALESCE(LEFT(fingerprint_hash,10),'-') AS fp,
         (signals IS NOT NULL)             AS has_sig,
         COALESCE(signals->>'source','-')  AS source,
         COALESCE(signals->>'reasons','-') AS reasons
  FROM clicks
  ORDER BY created_at DESC
  LIMIT 5;" | column -t -s '|' \
  -N 'time,score,passed,fp,has_sig,source,reasons'

echo "--- db: phase-3 coverage (last 20) ---"
docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "
  SELECT
    COUNT(*) FILTER (WHERE fingerprint_hash IS NOT NULL) AS with_fp,
    COUNT(*) FILTER (WHERE signals          IS NOT NULL) AS with_signals,
    COUNT(*) FILTER (WHERE bot_score        IS NOT NULL) AS with_score,
    COUNT(*)                                             AS total
  FROM (SELECT * FROM clicks ORDER BY created_at DESC LIMIT 20) s;"

echo "--- pm2 status ---"
pm2 jlist 2>/dev/null | grep -oE '"name":"[^"]+","[^}]*"status":"[^"]+"' | head -5 || pm2 status | tail -5

echo "=== done ==="
REMOTE

echo ""
echo "PASS criteria:"
echo "  - HEAD returns 200/302"
echo "  - newest rows have score≠'-', fp≠'-', has_sig=t"
echo "  - source values match: direct / silent / blocked / verify-silent"
REMOTE_EOF
