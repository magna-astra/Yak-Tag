# YAK-TAG: where we stopped

Last updated **2026-10-07** (full system check, section 3k). Branch `fix/system-check-2026-10-07` waits for the owner: run `db/schema_v46_write_permissions.sql` in Supabase first, then merge and push.
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
- If `config.js` or `offline.js` change, bump `?v=` in `t.html`, `cow.html` and `admin/index.html` (currently `?v=20261007`).
- If `assets/style-a.css` changes, bump its `?v=` in the 4 public pages (currently `?v=2026100701`); same for `assets/contacts.js` (currently `?v=2`). Without it, browsers mix the new pages with the old file. (`assets/site.css` is no longer used.)
- **Testing without the live database:** the Claude browser preview of a local server was blocked on 2026-10-07, so the app logic was tested in Node with stubs (fake IndexedDB, fake server, fake caches). The test scripts were temporary. For screenshots, headless Edge's `--window-size=375,…` renders wider and crops; use DevTools phone emulation (`Emulation.setDeviceMetricsOverride`) for real phone widths.

## 2. Where things are

| What | Where |
|---|---|
| Live site | https://yaktag.org/ (old https://magna-astra.github.io/Yak-Tag/ forwards here) |
| Repo | `magna-astra/Yak-Tag` (public, GitHub Pages) |
| Database | Supabase project `oxfbxqclqfglpzgzizhq` |
| Dashboard | `admin/index.html` |
| Owner / herder page | `cow.html` |
| Public tap page | `t.html` |
| Shared code | `config.js` (client, dates, Mongolian errors), `offline.js` (offline queue), `sw.js` |
| Database changes | `db/schema_v*.sql`. v21 to v45 are **run on live** (v45's e-mail part stays dormant). **v46 must still be run** (section 3k). |
| Daily backup | `.github/workflows/backup.yml` → `scripts/export_supabase.py` → private repo `Yak-Tag-backups` (+ `database.dump` once `SUPABASE_DB_URL` is set) |
| Not on the website | `_config.yml` keeps `*.md`, `db/`, `tools/`, `scripts/`, `supabase/` off yaktag.org (they stay in the public repo) |

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

## 3g. Website contacts editable + "back to website" links (2026-10-01)
- **v43** `db/schema_v43_site_contacts.sql` (**must be run in Supabase**) adds:
  - `site_settings`: one row with phone, email and address. Visitors may read it, since it's public;
  - `update_site_contacts()`: super admin only, with checked fields and every change in the "Түүх" audit tab;
  - `submit_order` messages that show the current phone.
- **Dashboard:** a "Холбоо барих" button (super admin only) opens the form.
- **Website:** `assets/contacts.js` puts the current details into every spot marked `data-c-text` / `data-c-href` / `data-c-show`. The numbers written in the HTML stay as the fallback. It also updates the search-engine details and is cached in localStorage. The share image still has the phone printed in it, so it must be regenerated if the number changes.
- **Back to the website:**
  - **Dashboard:** a "← Вэб сайт" button and a clickable logo in the header, plus a link on the login card.
  - **Cow page:** a clickable logo, a bottom link and a login link.

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

## 3h. Own domain yaktag.org (2026-10-05)

- **Domain:** `yaktag.org`, bought at **Cloudflare** (registrar + DNS). Paid until **2027-10-05**; keep **auto-renew ON**.
- **DNS (Cloudflare):** 4 × A `@` → `185.199.108–111.153`, CNAME `www` → `magna-astra.github.io`, TXT `_github-pages-challenge-magna-astra` (GitHub verified domain). **All "DNS only" (grey cloud). Never turn the orange proxy on** — GitHub's HTTPS certificate depends on it.
- **GitHub Pages:** custom domain `yaktag.org`, Enforce HTTPS on (Let's Encrypt). The `CNAME` file in the repo holds the domain — **never delete it**.
- **Old address:** `magna-astra.github.io/Yak-Tag/…` forwards with 301 to `yaktag.org/…`, keeping `?tag=`. Tags printed before keep working **as long as the GitHub repo and Pages exist**. New tags are written with `https://yaktag.org/t.html?tag=` (`tools/nfc_write.py`, `tools/nfc_tag.py`).
- **v44** (`db/schema_v44_site_url.sql`): Telegram alert links use `https://yaktag.org`.
- Search/share links, `sitemap.xml` and the new `robots.txt` use the new address.
- `admin/index.html` and `cow.html` refuse to show inside another site's frame (click-jacking guard).
- Logins are kept per address: everyone logged in once more after the move.
- Live check after the move (2026-10-05): forwards, HTTPS, tag lookup and bad input, visitor access to 24 tables, 14 admin functions, sign-up off, storage, spam trap, load test (240 page loads 30 at once; 25 simultaneous tag lookups) — all passed.

## 3i. Orders arrive by Telegram; e-mail only as a contact link (2026-10-06)

**Decision:** website orders are received in **Telegram only**. Visitors who prefer e-mail press the address on the site (`mailto:` links filled in by `assets/contacts.js` from the dashboard setting), which opens their own e-mail app to `contact@yaktag.org`. **`email_setup()` is NOT run**, so v45's e-mail part stays switched off; keep it that way unless the owner asks for order e-mails.


- **Zoho Mail** (Forever Free, web + app only) hosts `admin@` (super admin), `contact@`, `test@yaktag.org`. Zoho set its DNS itself through Cloudflare: MX `mx/mx2/mx3.zoho.com`, SPF `v=spf1 include:zohomail.com ~all`, DKIM `zmail._domainkey`. DMARC `p=reject` unchanged.
- The website shows `contact@yaktag.org` (dashboard → "Холбоо барих").
- **v45** (`db/schema_v45_order_email.sql`, optional, dormant): if ever switched on, every website order is ALSO e-mailed (Telegram unchanged) through **Resend** (free: 3 000/month, 100/day), to `app_secrets.order_email` or else the e-mail shown on the website. Capped at 90 e-mails a day. Its last statement lists the latest 5 orders with `telegram_chats` (0 = no super admin has linked Telegram).
- Setup once in the SQL Editor: `select public.email_setup('re_…');` (key from Resend → API Keys; never paste it in chat). It sends a test e-mail. Problems: `select * from public.email_check();` shows Resend's answers.
- Resend DNS lives on `send.yaktag.org` + `resend._domainkey` only; it must not touch the root MX/SPF (Zoho).

## 3j. Business kit + tag password out of the repo (2026-10-07)

- **Business kit:** `python dist/build_kit.py` builds `dist/YAK-TAG_Business_Kit_<date>.zip` — 8 step-by-step guides (tag production, farm setup, herder guide + Mongolian card, orders, sell/replace, website/domain/e-mail, database/backup/security, launch checklist), the files each step uses, and the full committed project. The guide sources are in `dist/kit_src/`. `dist/` is git-ignored (not public). The build refuses to zip if it finds anything secret-looking.
- **`tools/nfc_tag.py`:** the tag password is no longer in the (public) code. `setpass` saves the owner's 4-character password in `tools/tag_password.txt` (git-ignored) or use `YT_TAG_PASSWORD`. `protect` refuses the old public `YKTG`. Old YKTG test tags: `set YT_TAG_PASSWORD=YKTG` → `unprotect` → new window → `protect`.
- **`protect` now writes CFG1 before CFG0 (AUTH0)** — the old order could fail half-way once AUTH0 took effect. Tested on a simulated NTAG215 (22/22); **a real ACR1552U test is still needed** (guide 01, "First time only").
- **Backup** now also saves `order_requests` and `site_settings`. `app_secrets` stays out on purpose.
- Re-using a tag from a sold/dead animal is **not** in the dashboard (`recycle_tag` exists in SQL but the old animal keeps the tag_code, so the tag would not show as "Шинэ таг"). The guides say: retire it, use a new tag.

## 3k. Full system check, 2026-10-07 (branch `fix/system-check-2026-10-07`)

Four parallel checks: website, app pages, database security, operations (backups, workflows, DNS). Map code untouched.

**Database — `db/schema_v46_write_permissions.sql` (run in Supabase; tested twice on a local Postgres):**
- **Critical, fixed:** the old `profiles_admin` rule (schema.sql) let a **farm admin make themselves super admin** with one hand-made request. Dropped; browsers can no longer write `profiles` directly.
- **Fixed:** anyone could write `public_scans` directly with `was_lost = true` → **fake lost-animal Telegram alerts**. Direct writes revoked (only `record_public_scan()` writes), and the alert trigger now checks the animal itself.
- **Fixed:** herders could PATCH `cattle` (phone past the lock, another animal's tag code, another farm), `tags`, `health_events` directly. Revoked — every app path already goes through security-definer functions (checked one by one).
- **Fixed:** the milk 3-edit lock could be reset by sending `edit_count = 0`; the server now ignores those fields.
- Photo buckets: images only, 10 MB.
- Its CHECK section lists super admins (anyone unexpected = abused loophole) and the write rules that remain.

**App pages (Node tests with stubs: 32/32 pass):**
- `t.html`: a stranger who never answers the location prompt left **no scan and no lost alert** — now saved without position after 25 s (40 s offline).
- `cow.html`: bars-but-no-data + expired login showed the login screen; now opens the saved copy. Login says "Сүлжээ муу" instead of "wrong password" on network errors. Logout warns about unsent entries and clears that user's cached animals. Pregnancy/calving form keeps one id per opened form (no doubles on re-save).
- `config.js`: every database request gives up after 20 s (uploads excepted), so the offline paths take over instead of hanging. `daysUntil` was one day off before 08:00 (UTC parsing); admin's copy removed.
- `offline.js`: no hang when phone storage is full; an entry the server refuses at once is shown and not retried behind the user's back (scans still retry); an entry sent by a parallel flush is no longer reported as failed.
- `sw.js`: scripts cached under their `?v=` (no old config.js with a new page on slow networks); supabase-js cached on first load if install missed it.
- Fonts no longer block `t.html` / `cow.html`.
- Dashboard: a network error during delete no longer offers "delete everything"; vaccine save can't double-click; milk window no longer fails silently. Row buttons verified wired (unchanged).

**Website:** `hero3d.html` noindex; `_config.yml` stops publishing notes/SQL/tools; old gmail fallback → `contact@yaktag.org` (7 places); grey text contrast 3.3–3.7 → 5.0+; order-form field borders visible; number cards and the how.html sample table no longer overflow on phones (CSS only — **not visually checked**, look on a phone after deploy); tag image 227 KB → 34 KB WebP; sitemap dates.

**Operations:** backup is now **daily**, turns red if ANY table fails or a row count doesn't match, backs up `telegram_links`, and has an optional full `pg_dump` job (needs `SUPABASE_DB_URL`). Keep-alive re-enables both scheduled workflows every run (GitHub's 60-day switch-off). `nfc_write.py lock` no longer erases the URL if the lock fails; `nfc_tag.py` refuses malformed tag codes. README rewritten.

**Found, not changed (decide later):**
- `public_tag_lookup` visitor limit trusts the first `X-Forwarded-For` entry if `cf-connecting-ip` is missing; changing `scan_caller_hash()` blind could lock out all visitors at once — measure first.
- `submit_order` allows 30/hour (≈720/day) of attacker text through the Telegram bot; a daily cap (~100) would help.
- Photos (`cattle-photos`, `cattle-public`) are not in any backup.
- Old password `YKTG` is in public git history: any tag still protected with it can be rewritten.
- ~2.2 MB of unused images in `assets/` (herd-*, yak-*, logo-yak.png, tag-raw.png …).
- Leaflet on how.html loads from unpkg without integrity, on every visit (MAP — hands off).

## 3l. Full-copy backup failed on its first day (2026-10-08)

- Run 37722620558: `export` ✅ (the day's tables are saved), `full-copy` ❌ at "Dump the database" — GitHub showed only "exit code 1" (step logs need a login; annotations are public).
- `scripts/check_db_url.py` now runs before pg_dump: it explains the usual SUPABASE_DB_URL mistakes as a red annotation (direct IPv6 host, transaction pooler 6543, `[YOUR-PASSWORD]` left in, `@ / ? # %` in the password, pooler user without `.project-ref`, wrong password, unreachable host) and never prints the password. It also reads the server version; a server newer than 17 gets a matching `postgresql-client-NN`. pg_dump's own error is shown as an annotation too.
- Read the reason without a login: `https://api.github.com/repos/magna-astra/Yak-Tag/check-runs/<job id>/annotations`.

## 3m. Launch check + screenshot walkthrough (2026-10-10)

- **Live check, all green:** forwards + HTTPS (cert to 2027-01-03); 59 published files = repo, notes/SQL/tools 404 (`_config.yml`); tag lookup + attack inputs; visitors read/write nothing; **v46 confirmed active live** (direct `public_scans` insert → permission denied); admin functions refuse visitors; sign-up off; spam trap; daily backup + keep-awake green; 150 page loads / 20 simultaneous taps OK. `nfc_tag.py` 22/22 on the simulated chip.
- **Full-copy backup:** `SUPABASE_DB_URL` secret removed by the owner → the job skips (green). The check script reported "must start with postgresql://".
- **Walkthrough:** `dist/make_shots.py` (sample-data copies of the real pages → `dist/walkthrough/img/`, phones in a 390-px frame, **headless Chrome** — Edge 155 was stuck mid-update) and `dist/build_walkthrough.py` → `dist/walkthrough/YAK-TAG_Walkthrough.html` (single file, ~0.7 MB). `dist/build_kit.py` puts it in the kit as `00_WALKTHROUGH.html`. All in git-ignored `dist/`.
- Seen in the screenshots, not changed: on a 390-px phone the cow-page header wraps ("YAK-/TAG", "Нууц/үг"). Cosmetic.

## 4. To do next

1. **Run `db/schema_v46_write_permissions.sql`** in Supabase → SQL Editor, read its CHECK output, then merge `fix/system-check-2026-10-07` and push.
2. **BACKUP_TOKEN expiry:** GitHub → Settings → Developer settings → Fine-grained tokens → open the backup token → read "Expires". If it's near, Regenerate (longest expiry) and update the repo secret.
3. Optional **full backup:** add secret `SUPABASE_DB_URL` (Supabase → Connect → Session pooler URI with the database password), then Actions → Daily database backup → Run workflow → both jobs green.
4. **Re-protect field tags** that still use the old `YKTG` password (`tools/nfc_tag.py`, section 3j).
5. **Real lost-animal test (optional):** mark a test cow lost, tap its tag with a phone that isn't logged in, a Telegram alert with a map link should arrive, then press "Олдсон".
6. Ask **farm admins and herders to link Telegram**.
7. Google Search Console: submit `https://yaktag.org/sitemap.xml` if it isn't listed. "Page with redirect" (http://, www.) is expected — don't validate it.
8. Done earlier: Sunday backup check (2026-09-28), marketing pages (2026-10-01), order form → Telegram (v41), DNSSEC + SPF/DMARC (verified on 2026-10-07).

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
for f in admin/index.html cow.html t.html config.js; do L=$(curl -s "https://yaktag.org/$f?nc=$RANDOM" | md5sum | cut -c1-32); R=$(git show HEAD:$f | md5sum | cut -c1-32); [ "$L" = "$R" ] && echo "same $f" || echo "DIFF $f"; done
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
