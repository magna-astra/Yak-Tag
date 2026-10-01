# YAK-TAG: where we stopped

Last updated **2026-10-01**. Website improvements are on local `main` (see section 3b), waiting for a push.
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
- If `assets/site.css` changes, bump its `?v=` in the 4 public pages (currently `?v=2026100103`). Without it, browsers mix the new pages with the old stylesheet.

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

## 3b. Website improvements, 2026-10-01 (public pages only: `index`, `how`, `faq`, `order`, `assets/site.css`)

- **Phone menu (☰):** before, phones showed only "Захиалах". An old `.burger{display:none !important}` rule hid any menu, so the new button uses the class `navburger`.
- **Phone intro text** now uses the full width. A later `.herogrid` rule had kept it at 48%, about 159 px.
- **Homepage:** new 6-card features section (milk, vaccine, pregnancy/calving, lost → Telegram, offline, Excel/history) with call-to-action buttons. It's kept compact on purpose, since the Sep 11 rebuild made the homepage short.
- **Homepage tag demo** now uses built-in sample animals. Before, it read real tags from the database and linked to the real `t.html`, so a visitor's click could record a scan, or even send a lost alert, for a real animal. The page no longer loads supabase-js.
- **how.html:** "Долоон алхмаар" with new section 06 (lost-animal Telegram alert) and 07 (Excel report and history).
- **faq.html:** 4 new questions (Telegram cost, selling/transfer, reports, data safety). The lost-animal answer now mentions Telegram.
- **order.html:** a "call to order" button next to the email button (many phones have no email app).
- **Sharing and search:**
  - `assets/share-1200x630.jpg` is the new preview image for Facebook and Telegram (built by a Pillow script);
  - each page has its own canonical address, `og:url` and twitter card tags;
  - `index.html` has organisation details for search engines;
  - `sitemap.xml` is new;
  - `noindex` was added to `cow.html` and `admin/index.html` (`t.html` already had it).
- Removed the unused Noto Sans Mongolian font from the Google Fonts link.

## 3c. Order form + new website design, 2026-10-01

- **v41 order form → Telegram** (commit c824995): `db/schema_v41_order_requests.sql` stores website orders in `order_requests`. It has spam limits (a hidden field, 3 per visitor per hour, 30 per hour in total) and messages every linked super admin. **It must be run in Supabase before the order page goes live.** To see orders: `select * from order_requests order by id desc;`
- **Style A "Тал нутаг"** (light, warm, steppe green), branch `feature/style-a`:
  - **Pages and styles:** the 4 public pages are rebuilt on the new `assets/style-a.css`. `assets/site.css` is no longer used by them; it's kept only in case an old cached page asks for it.
  - **Photos:** AI photos the owner generated are in `assets/photos/*.webp`, at 640/960/1200/1536 px (30–160 KB each); the source PNGs are on the owner's Desktop in `YAKTAG-PHOTOS`. In photo 6 (`tagscan`), the AI had drawn the **Soyombo state emblem** on the tag; it was replaced with the real `assets/tag-1024.png`. The footer says "Зургууд нь жишээ дүрслэл".
  - **Animations:**
    - the page tops use a CSS-only entrance (`.ani`), so they show even if scripts fail;
    - lower content fades in on scroll (`.rv`), with a fallback for browsers without scroll detection;
    - numbers count up, and tap rings pulse on the herder's phone;
    - everything switches off under "reduce motion".
  - **Unchanged on purpose:** the "how it works" demo map script is byte-for-byte the same, and the order form's script and element ids are unchanged.
  - **Testing note:** the Claude browser pane freezes animations when its window is behind, so use headless Edge for screenshots (`msedge --headless=new --screenshot`; add `--force-prefers-reduced-motion` to see the final state).

## 3d. Hero: full-background photo + drifting clouds (2026-10-01)
- The homepage hero photo fills the whole section. Text sits on a cream fade on the left; on phones the sky continues above the photo and the herder stands below.
- **Clouds** (`assets/clouds/cloud-*.webp`) are the photo's **own clouds**, cut out by a script. They drift forever (CSS `drift`, 95–170 s per cloud) and appear only inside `assets/clouds/sky-mask.png`, a soft sky-only mask drawn on the photo and fitted exactly like it. So they pass behind the herder, the yak and the mountains, never over them.
- The **tap rings and cards are pinned to the herder's phone** by JS (`PHONE={x:.685,y:.479}`, cover-fit maths). Cards avoid the intro text; on phones the alert card is hidden.
- To add more cloud variety later: photos of clouds on a **pure black** background can be turned into transparent sprites the same way.

## 3e. Clouds high, new calving photo, step animations, app pages restyled (2026-10-01)
- **Clouds** stay in a high band of the sky (`sky-mask.png`: full above 15% of the photo, gone by 22%; the hat is at about 29%). They're smaller and slower, so they read as far away.
- **Calving photo:** the owner's real photo of a yak mother and calf (`assets/photos/calving-*.webp`). The links carry `?v=2` because the file name didn't change.
- **how.html: an animated scene per step** (`.scene[data-scene]`; the JS runs a scene only while it's on screen, and "reduce motion" shows the end state):
  - **tag:** the NFC read and tag code;
  - **milk:** the cow-page milk entry;
  - **dash:** the dashboard counts, rows and a live milk entry;
  - **trail:** the map-overlay pins (the map script is untouched);
  - **preg:** the gestation bar, 258 → 190 days;
  - **tg:** typing, then the Telegram alert;
  - **xl:** the download, rows and sheet tabs.

  The homepage's 3 steps have small animated icons.
- **App pages in website style A:** a theme block is appended at the end of the `<style>` in `admin/index.html`, `cow.html` and `t.html`. These are additions only, with no scripts changed.
  - **Dashboard:** `--khukh` (blue) is left unchanged on purpose, because the **map pins and legend use it**; the new green is `--pri`.
  - **Cow page and tap page:** `--khukh` is re-pointed to green, with a green header.
- **Fixed older phone bugs:**
  - the cow page's milk and phone inputs couldn't shrink, which pushed "Хадгалах" off the card on every phone;
  - the dashboard top bar ran off the screen on phones (it now wraps);
  - the cow header overflowed at 320 px.

## 3f. Check, security test and stress test (2026-10-01)
- **Live files:** 57/57 identical to the repo.
- **Security (outside, no login):** 123/123 pass.
  - **Tables:** visitors read nothing, and writes are refused.
  - **Functions:** every admin and herder function is locked.
  - **Telegram webhook:** refuses wrong or missing secrets and junk.
  - **Order form:** refuses bad input before saving.
  - **Storage:** visitors can't list or upload.
  - **Login:** sign-up is off.
  - **Secrets:** no keys or tokens in the repo or its history.
- **Stress (read-only):** 800 requests, 100% OK. API p95 under 0.7 s with 20 at once; tag lookup p95 0.36 s.
- **Finding, fixed by v42:** `public_tag_lookup` had no per-visitor limit and returns the owner's phone, with sequential tag codes. That meant phone numbers could be harvested in minutes. `db/schema_v42_lookup_limit.sql` allows 120 lookups per visitor per hour, counted in its own `lookup_rate` table, and removes the ZZ- test rows from `lookup_attempts`. **It must be run in Supabase.**

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

1. ~~Check the Sunday backup~~ **Done 2026-09-28:** the run of 2026-09-27 succeeded with no warnings, so all 16 tables were saved.
2. **Real lost-animal test (optional):**
   - Mark a test cow lost.
   - Tap its tag with a phone that isn't logged in.
   - A Telegram alert with a map link should arrive.
   - Then press "Олдсон".
3. Ask **farm admins and herders to link Telegram**.
4. ~~Marketing pages~~ **Done 2026-10-01** (section 3b). **Push it**, then open the live site on a phone and press ☰.
5. Optional: add the site to **Google Search Console** (free) and submit `https://magna-astra.github.io/Yak-Tag/sitemap.xml`.
6. Idea: an **order form → Telegram** (free). Website orders would arrive in the owner's Telegram through the existing bot, instead of relying on email. It needs a small SQL function with a spam limit.

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
