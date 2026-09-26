# YAK-TAG: where we stopped

Last updated **2026-09-26 (Sat)**. The live site and repo are at commit **c41e05c**.
This file has no passwords or tokens. It is safe to commit, but note that the repo is public.

To continue, open this folder in Claude Code and say:
*"Read NEXT_SESSION.md and continue."*

---

## 1. Rules that always apply

- **The system is live and working. Don't break it.** Use a branch, then `git merge --ff-only` into `main`. SQL must be safe to run twice. Run SQL first, then push.
- **Don't touch the map.** That covers the map tab, map config, and `USE_GOOGLE_TILES_TESTING`. Change it only if the owner asks.
- **Only free options.** No paid APIs, SMS, WhatsApp or Viber business fees. Telegram is used for alerts.
- The owner pushes with **GitHub Desktop**. Claude commits locally only.
- Edit files with **exact-text replacements**, never line-range slicing. A slicing edit once silently deleted all the dashboard row buttons.
- After any dashboard edit, **click-test every row button**.
- If `config.js` or `offline.js` change, bump `?v=` in every page (currently `?v=20260928`).

## 2. Where things are

| What | Where |
|---|---|
| Live site | https://magna-astra.github.io/Yak-Tag/ |
| Repo | `magna-astra/Yak-Tag` (public, GitHub Pages) |
| Database | Supabase project `oxfbxqclqfglpzgzizhq` |
| Dashboard | `admin/index.html` |
| Owner / herder page | `cow.html` |
| Public tap page | `t.html` |
| Shared code | `config.js` (client, dates, Mongolian errors), `offline.js` (offline queue), `sw.js` |
| Database changes | `db/schema_v*.sql`. v21 to v40 are **all run on live**. |
| Weekly backup | `.github/workflows/backup.yml` → `scripts/export_supabase.py` → private repo `Yak-Tag-backups` |

## 3. Done on 2026-09-26 (all live and checked)

| Commit | What |
|---|---|
| 69dc2ad | **v37**: 21 old functions locked for visitors who aren't logged in. The old `audit_scope` rule was removed, so only admins read the audit log. **"Түүх" tab** (audit log). **Lost/found button** on the cow page. |
| baa38ea | **Backup fix**: it now saves 16 tables. Before, it missed milk, pregnancy, calving, breeds and strangers' taps, and pages could repeat or skip rows. |
| c41e05c | **v38 Telegram alerts**, **v39 sell/transfer an animal**, **v40 Excel report**. |

### How the new parts work
- **Telegram (v38)**
  - A tap of a lost animal (public page or app) sends a message to the owner, that farm's admins and super admins who have linked Telegram. It never goes to the person who tapped. At most 1 alert per animal per chat every 10 minutes.
  - The database sends it with `pg_net`. Telegram calls the database directly at `/rest/v1/rpc/telegram_webhook?apikey=…`, which checks a secret key.
  - Each person links by pressing **Telegram** (dashboard or cow page) and then **Start** in the bot.
  - **Status:** the bot is set up and the webhook is set. The super admin is linked and the test message arrived. `/start` works.
- **Transfer (v39)**
  - Use `transfer_cattle(...)`: the **⇄** button next to the owner, or "Эзэмшигч солих / зарах" in the edit window. Owner and farm in the edit window are now locked.
  - A farm admin can transfer within their farm; the super admin also across farms. Across farms, the tag and all history move with the animal.
  - The contact phone becomes the new owner's.
  - History is shown by `cattle_ownership_history`.
- **Excel (v40)**
  - "⬇ Excel тайлан" on the herd tab builds a 4-sheet `.xlsx` in the browser, with no library.
  - Milk is added up per month by `export_milk_monthly`.

## 4. To do next

1. **Sunday 2026-09-27 at about 11:00 Ulaanbaatar time:** the weekly backup runs. Check that GitHub → Actions → "Weekly database backup" shows **`Exported 16/16 tables`**.
2. **Real lost-animal test (optional):**
   - Mark a test cow lost.
   - Tap its tag with a phone that isn't logged in.
   - A Telegram alert with a map link should arrive.
   - Then press "Олдсон".
3. Ask **farm admins and herders to link Telegram**.
4. **Marketing pages** (`how.html`, `faq.html`, `index.html`) don't yet mention the Telegram alerts, selling/transferring, or the Excel report. Claude offered to add short sections.

## 5. Idea list (not started)

- Feeding entries without signal: send them through the offline queue, as milk and pregnancy entries already do.
- Install to the home screen as an app (PWA manifest).
- Weight history and a growth chart. Today only the last weight is kept.
- A permanent one-click test page. Today's tests were temporary files, deleted after use.
- Lock `scan_caller_hash()` for visitors. It's harmless and read-only, but not needed.
- *Map area. Ask first:* the Leaflet script has no integrity check, and the Google test tiles need a licence before real production (see `SWITCH_MAPS_BEFORE_LAUNCH.md`).
- Known small point: after a cross-farm transfer, the old farm's herders can still open old photo files if they know the path. They no longer see the animal.

## 6. Handy commands

**Telegram (Supabase SQL Editor)**
```sql
select telegram_check();                                    -- result of the last setup
select telegram_setup('NEW-TOKEN', 'YourBot_bot');          -- after changing the token in @BotFather
-- if the bot stops replying: ask Telegram for its webhook status
select net.http_get('https://api.telegram.org/bot' || app_secret('telegram_token') || '/getWebhookInfo');
select content from net._http_response order by id desc limit 1;   -- ~5 s later
select * from notify_log order by id desc limit 20;         -- messages sent
```
If the token ever leaks, get a new one in @BotFather: `/mybots` → the bot → API Token → Revoke. Then run `telegram_setup` again.

**Check that the live site matches the repo (Git Bash)**
```bash
for f in admin/index.html cow.html t.html config.js; do L=$(curl -s "https://magna-astra.github.io/Yak-Tag/$f?nc=$RANDOM" | md5sum | cut -c1-32); R=$(git show HEAD:$f | md5sum | cut -c1-32); [ "$L" = "$R" ] && echo "same $f" || echo "DIFF $f"; done
```

**Test SQL safely before running it on live.** Use a throwaway local Postgres 18 on port 55432. The base setup script was in the Claude scratchpad (`v28_setup.sql`) and will need rebuilding:
```bash
PG="/c/Program Files/PostgreSQL/18/bin"; D="$TEMP/yt-pgtest"
"$PG/initdb" -D "$D" -U tester -A trust -E UTF8
"$PG/pg_ctl" -D "$D" -o "-p 55432 -c listen_addresses=localhost" -l "$D/log.txt" start
# ... run tests with PGCLIENTENCODING=UTF8 "$PG/psql" -h localhost -p 55432 -U tester -d postgres -f test.sql
"$PG/pg_ctl" -D "$D" stop -m fast && rm -rf "$D"
```

**Serve locally for click-tests:** `python -m http.server 8765`, then open `http://127.0.0.1:8765/admin/index.html`.
