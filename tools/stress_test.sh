#!/usr/bin/env bash
# ============================================================
# YAK-TAG — load and abuse test
#
# Tests YOUR OWN system. Do not point it at anything else.
#
# Requires: curl, jq
# Usage:
#   1. paste your publishable key below
#   2. chmod +x stress_test.sh && ./stress_test.sh
# ============================================================

URL="https://oxfbxqclqfglpzgzizhq.supabase.co"
KEY="PASTE_YOUR_PUBLISHABLE_KEY"

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
echo "6. Scan flood — 30 rapid scans against one tag…"
ok=0; null=0
for i in $(seq 1 30); do
  r=$(curl -s -X POST "$URL/rest/v1/rpc/record_public_scan" \
    -H "apikey: $KEY" -H "Content-Type: application/json" \
    -d '{"p_tag_code":"YT-008000","p_lat":47.9,"p_lng":103.5}')
  if [ "$r" == "null" ]; then null=$((null+1)); else ok=$((ok+1)); fi
done
echo "  accepted: $ok   throttled: $null"
if [ "$null" -gt 0 ]; then pass "rate limit is working"
else fail "no throttling — run schema_v20_security_hardening.sql"; fi

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
    -d '{"p_tag_code":"YT-008000"}'
done
end=$(date +%s%N)
avg=$(( (end-start)/20000000 ))
echo "  average ${avg}ms per call"
[ "$avg" -lt 800 ] && pass "acceptable" || fail "slow — check indexes"

echo
echo "============================================================"
echo "Then run security_audit.sql in Supabase for the database side."
echo "============================================================"
