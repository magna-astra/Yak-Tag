#!/usr/bin/env bash
# ============================================================
# YAK-TAG — load and abuse test
#
# Tests YOUR OWN system. Do not point it at anything else.
#
# Requires: curl, jq
# Usage (from the repo root):
#   ./tools/stress_test.sh                      # safe: read-only checks
#   TEST_TAG=YT-TEST-01 ./tools/stress_test.sh  # also runs the scan flood
#
# SAFE BY DEFAULT. This runs against the LIVE database. Test 6 (scan
# flood) writes real rows into public_scans, moves that animal's map
# pin, and uses up its 20-scans/hour limit — so real finders' scans of
# it are ignored for an hour. It only runs when TEST_TAG names a
# dedicated test animal. Never point it at a real animal.
#
# Lookups (tests 4, 5, 9) are logged in lookup_attempts. Latency tests
# use a fake code; clean up afterwards with:
#   delete from lookup_attempts where tag_code like 'ZZ-STRESS%';
# ============================================================

# URL and publishable key are read from config.js — nothing to paste.
CONFIG="$(dirname "$0")/../config.js"
URL=$(grep -o "SUPABASE_URL = '[^']*'" "$CONFIG" | cut -d"'" -f2)
KEY=$(grep -o "SUPABASE_KEY = '[^']*'" "$CONFIG" | cut -d"'" -f2)
if [ -z "$URL" ] || [ -z "$KEY" ]; then
  echo "Could not read SUPABASE_URL / SUPABASE_KEY from $CONFIG"; exit 1
fi
# Without jq every "length" check comes back empty, and tests 1–3
# then report PASS while having checked nothing.
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (Windows: winget install jqlang.jq). Stopping —"
  echo "without it the security checks would falsely PASS."; exit 1
fi
TEST_TAG="${TEST_TAG:-}"
FAKE_TAG="ZZ-STRESS-TEST"

pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; }

echo "============================================================"
echo "YAK-TAG load + abuse test"
echo "============================================================"

# ---------- 1. anonymous read of the cattle table ----------
echo
echo "1. Can an anonymous caller read the cattle table directly?"
n=$(curl -s "$URL/rest/v1/cattle?select=tag_code" -H "apikey: $KEY" | jq 'length' 2>/dev/null)
if [ "$n" == "0" ] || [ -z "$n" ]; then pass "blocked (returned $n rows)"
else fail "returned $n rows — RLS is not protecting cattle"; fi

# ---------- 2. anonymous read of milk data ----------
echo
echo "2. Can an anonymous caller read milk_yield?"
n=$(curl -s "$URL/rest/v1/milk_yield?select=liters" -H "apikey: $KEY" | jq 'length' 2>/dev/null)
if [ "$n" == "0" ] || [ -z "$n" ]; then pass "blocked"
else fail "returned $n rows — milk data is public"; fi

# ---------- 3. anonymous read of scan positions ----------
echo
echo "3. Can an anonymous caller read public_scans (GPS history)?"
n=$(curl -s "$URL/rest/v1/public_scans?select=lat,lng" -H "apikey: $KEY" | jq 'length' 2>/dev/null)
if [ "$n" == "0" ] || [ -z "$n" ]; then pass "blocked"
else fail "returned $n rows — location history is public"; fi

# ---------- 4. what the public lookup actually returns ----------
echo
echo "4. What does public_tag_lookup expose?"
curl -s -X POST "$URL/rest/v1/rpc/public_tag_lookup" \
  -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"p_tag_code":"YT-008000"}' | jq '.[0] | keys' 2>/dev/null
echo "  (should be only: has_phone, is_lost, phone, photo_path, tag_code)"

# ---------- 5. tag enumeration ----------
echo
echo "5. Tag enumeration — trying 30 sequential codes…"
found=0
for i in $(seq 7990 8019); do
  r=$(curl -s -X POST "$URL/rest/v1/rpc/public_tag_lookup" \
    -H "apikey: $KEY" -H "Content-Type: application/json" \
    -d "{\"p_tag_code\":\"YT-00$i\"}" | jq 'length' 2>/dev/null)
  [ "$r" != "0" ] && [ -n "$r" ] && found=$((found+1))
done
echo "  $found of 30 codes resolved"
echo "  NOTE: enumeration is possible by design — a finder must be able"
echo "  to look up any tag. v20 logs attempts so a sweep is visible."
echo "  Check afterwards:  select * from lookup_abuse;"

# ---------- 6. scan flood ----------
echo
if [ -z "$TEST_TAG" ]; then
  echo "6. Scan flood — SKIPPED (writes real scans; set TEST_TAG to a"
  echo "   dedicated test animal to run it, never a real one)"
else
  echo "6. Scan flood — 30 rapid scans against TEST animal $TEST_TAG…"
  echo "   (no GPS sent, so the animal's map position is not changed)"
  ok=0; null=0
  for i in $(seq 1 30); do
    r=$(curl -s -X POST "$URL/rest/v1/rpc/record_public_scan" \
      -H "apikey: $KEY" -H "Content-Type: application/json" \
      -d "{\"p_tag_code\":\"$TEST_TAG\",\"p_user_agent\":\"stress_test.sh\"}")
    if [ "$r" == "null" ]; then null=$((null+1)); else ok=$((ok+1)); fi
  done
  echo "  accepted: $ok   throttled: $null"
  if [ "$ok" -eq 0 ]; then fail "nothing accepted — does $TEST_TAG exist?"
  elif [ "$null" -gt 0 ]; then pass "rate limit is working"
  else fail "no throttling — run schema_v20_security_hardening.sql"; fi
  echo "  Clean up: delete from public_scans where user_agent = 'stress_test.sh';"
fi

# ---------- 7. anonymous write attempts ----------
echo
echo "7. Can an anonymous caller insert into cattle?"
r=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/rest/v1/cattle" \
  -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"tag_code":"HACK-0001"}')
if [ "$r" == "401" ] || [ "$r" == "403" ] || [ "$r" == "400" ]; then pass "blocked (HTTP $r)"
else fail "HTTP $r — anonymous writes may be possible"; fi

# ---------- 8. private bucket ----------
echo
echo "8. Is the private photo bucket reachable anonymously?"
r=$(curl -s -o /dev/null -w "%{http_code}" \
  "$URL/storage/v1/object/public/cattle-photos/test.jpg")
if [ "$r" == "400" ] || [ "$r" == "404" ]; then pass "not publicly served (HTTP $r)"
else fail "HTTP $r — check the bucket is private"; fi

# ---------- 9. response time under load ----------
echo
echo "9. Response time, 20 sequential lookups…"
start=$(date +%s%N)
for i in $(seq 1 20); do
  curl -s -o /dev/null -X POST "$URL/rest/v1/rpc/public_tag_lookup" \
    -H "apikey: $KEY" -H "Content-Type: application/json" \
    -d "{\"p_tag_code\":\"$FAKE_TAG\"}"
done
end=$(date +%s%N)
avg=$(( (end-start)/20000000 ))
echo "  average ${avg}ms per call"
[ "$avg" -lt 800 ] && pass "acceptable" || fail "slow — check indexes"

echo
echo "============================================================"
echo "Then run security_audit.sql in Supabase for the database side."
echo "============================================================"
