# YAK-TAG: where we stopped

Last updated **2026-10-23** (phone-only login + herder app at yaktag.org/app — 3u; strict phone-only + Telegram password reset — 3v; v49–v51 live since 10-12).
This file has no passwords or tokens. It is safe to commit, but note that the repo is public.

To continue, open this folder in Claude Code and say:
*"Read NEXT_SESSION.md and continue."*

---

## 1. Rules that always apply

- **First check everything, then propose; build only after the owner picks** (owner, 2026-10-23: "next time first check all"; new features: "need idea and suggestions before actions"). Check = live site vs repo, visitor probes, workflows/backups, and what other sessions changed since (this file + `git log`).
- **The system is live and working. Don't break it.** Use a branch, then `git merge --ff-only` into `main`. SQL must be safe to run twice. Run SQL first, then push.
- **Never open the LIVE `t.html` for a REGISTERED tag when testing** — every visit records a real stranger tap (and sends Telegram alerts if the animal is lost). Use `public_tag_lookup` for reads, a produced tag without an animal (e.g. YT-008005), or the sample-data copies in `dist/`. (On 2026-10-11 one such visit to YT-008000 added one tap without GPS; the owner got SQL to delete it — rows with `user_agent like '%SM-A546B%'`.)
- **Don't touch the map.** That covers the map tab, map config, and `USE_GOOGLE_TILES_TESTING`. Change it only if the owner asks.
- **Only free options.** No paid APIs, SMS, WhatsApp or Viber business fees. Telegram is used for alerts.
- The owner pushes with **GitHub Desktop**. Claude commits locally only.
- Edit files with **exact-text replacements**, never line-range slicing. A slicing edit once silently deleted all the dashboard row buttons.
- After any dashboard edit, **click-test every row button**.
- If `config.js` or `offline.js` change, bump their `?v=` in `t.html`, `cow.html`, `admin/index.html` **and `app/index.html`** (currently `config.js?v=20261023`, `offline.js?v=20261023`).
- **Logins are phone numbers only — strict** (2026-10-23, owner's choice): every login box is "Утасны дугаар" with the number keypad; `loginEmail()` always builds `<digits>@yaktag.invalid`, and `loginPhoneError()` (config.js) refuses anything else. The Edge Function creates users with a phone only.
- **Who resets a forgotten password:** the person himself with a Telegram code (`password-reset`, app/?reset=1); the last resort is the super admin (anyone) or the Админ (only herders / farm admins of farms he created) — dashboard → Хэрэглэгчид → "Нууц үг". **Farm admins never** (owner: "farm admin for password no need").
- **Test pages must never run the real `sw.js` with a real tag code:** since v51 the service worker sends queued strangers' taps to the LIVE server in the background. `dist/offline_test.py` blocks the service worker and uses `ZZ-…` codes; `dist/sync_test.py` uses `ZZ-SYNC-TEST` (unknown tag = the server answers, saves nothing).
- **Test SQL on a full local rebuild first:** `python db/test/replay.py --keep` replays `schema.sql` + `seed.sql` + every patch on a throwaway Postgres 18 (port 55440, Supabase stand-ins in `db/test/stub.sql`, hand-made live objects in `db/test/prelude.sql`), then run role tests like `db/test/test_v49.sql` (one transaction, rolled back). Stop it afterwards: `pg_ctl -D "$TEMP/yt-replay" stop`.
- If `assets/style-a.css` changes, bump its `?v=` in the 4 public pages (currently `?v=2026102301`); same for `assets/contacts.js` (currently `?v=2`). Without it, browsers mix the new pages with the old file. (`assets/site.css` is no longer used.)
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
| Herder app (installable) | `app/index.html` + `app/manifest.json` → **https://yaktag.org/app/** (section 3u) |
| Shared code | `config.js` (client, dates, Mongolian errors), `offline.js` (offline queue), `sw.js` |
| Database changes | `db/schema_v*.sql`. v21 to v52 are **run on live** (v45's e-mail part stays dormant; v52 run 2026-10-23: "Success. No rows returned"). |
| Accounts Edge Function | `supabase/functions/admin-users/index.ts` (create user, set password, move login to a phone, list logins) — deployed by pasting it in Supabase → Edge Functions |
| Password reset Edge Function | `supabase/functions/password-reset/index.ts` (Telegram code) — public: **"Verify JWT" must be OFF** |
| Backups | **Weekly** (Mondays 11:07 UB): `.github/workflows/backup.yml` → `scripts/export_supabase.py` → private repo `Yak-Tag-backups/backups/<date>` (+ `database.dump` once `SUPABASE_DB_URL` is set). **Monthly** photos (1st, 11:37 UB): `photos-backup.yml` → `scripts/backup_photos.py` → `Yak-Tag-backups/photos/<bucket>/<path>` (mirror; deleted photos stay in its git history). Both share concurrency group `backup-repo`; keepalive re-enables all three schedules. |
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
- ~~Photos not in any backup~~ — monthly photo backup since 2026-10-12.
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
- **Fixed:** the cow-page header wrapped on 375–390-px phones ("YAK-/TAG", "Нууц/үг") — now one line (buttons nowrap, tighter gaps, logo only below 370 px); checked 360–430 px.
- **Fixed:** `t.html` footer said "Энэ мал YAK-TAG системд бүртгэлтэй" even for a new/unknown tag; now neutral ("YAK-TAG · Мал бүрт цахим үнэмлэх") until an animal is rendered (5/5 states checked).
- **Live first-tap screenshots:** `dist/first_tap.py [TAG]` (Chrome DevTools via `dist/cdp_shot.py`, true 390-px phone) shoots the LIVE tap page + login for a produced tag with no animal (70 such tags live, YT-008005…; opening them records nothing) and the after-login pages from sample copies → `dist/walkthrough/first_tap_storyboard.png`. Run it after `make_shots.py` (it overwrites h1–h4).

## 3n. Tag production: YKTG standard, batch, no number twice, reset (2026-10-11)

- **Owner's decision: every YAK-TAG tag uses the password `YKTG`** ("as before, no change"). `nfc_tag.py` uses it by default (no `setpass` needed; `setpass`/`YT_TAG_PASSWORD` still override). Risk told to the owner once: YKTG is public in this repo.
- **`python nfc_tag.py batch YT-009001 YT-009100`**: checks every number online (`public_tag_state` = 'new': exists, farm active, no animal; read-only), then tag after tag: write → read back → protect → check AUTH0 → log; skips chips already logged, locked, already YAK-TAG, not blank, or locked with another password; Ctrl+C stops, rerun continues. Ends with `uid_import_<date>.sql` (chip IDs into `tags.nfc_uid` + audit rows; only where `nfc_uid is null`; safe twice; tested on Postgres).
- **No number twice:** `tools/written_tags.csv` (git-ignored) logs code,uid,time; `write` refuses a code already on another chip or a chip that already carries a code; `rewrite` may move a chip to a new code but never reuses a code. Use a FRESH range per production run (older 8005… numbers may already be on old chips; that can't be seen from outside).
- **`python nfc_tag.py reset`**: used tag → like new (memory zero, CFG0 04 00 00 FF = no mirror/no protection, PWD FFFFFFFF). OneTag tags (onetagmn.com, CFG0 54 00 12 04 = UID mirror at page 18) first need OneTag's own `node remove-password.js` (its tag-writer folder, Desktop\<nbsp><nbsp>\MY\ONE-YAK-TAG\OneTag App & Host	ag-writer).
- `tools/open_tag_tool.bat` opens a window in tools/. On the owner's PC use **`python`** (has pyscard), not `py`.
- Tests (simulated NTAG215, scratchpad `nfc_test/`): production 19/19, reset 12/12. Not yet run on the real reader.

## 3o. History super-admin only; farm admins see their tags (2026-10-11)

- **v47** `db/schema_v47_history_super_only.sql`: `audit_log` select policy = `coalesce(is_super(), false)` (before: farm admins read their farm's history). Tested locally: farm admin 35 → 0 rows, super 35, run twice OK. **Must be run in Supabase.**
- Dashboard: "Түүх" tab `super-only`; "Тагууд" tab `admin-only` = farm admins see a READ-ONLY list of their farm's tags (no create / farm filter / bulk actions / checkboxes / UID editing). RLS already limited tags to their farm.
- The Админ role / pause / full farm delete agreed here was built in v49 (section 3q).

## 3p. "+ Таг үүсгэх": any range, says what already exists (2026-10-11)

- **v48** `db/schema_v48_create_tags_any_range.sql`: `admin_create_tags` (same signature, super only) now accepts any range: existing numbers are skipped and reported (count + first…last); missing numbers inside an existing batch of the SAME prefix join it; every gap gets its own new batch (no_range_overlap is per prefix). Returns created/created_first/created_last/skipped/existing_first/existing_last/new_batches. Tested locally with the real constraints (crossing a batch edge, all-existing, new range next to another prefix, batch+gap+batch, farm admin refused). **Must be run in Supabase.**
- Dashboard: the window pre-fills the next 100 free numbers (highest existing + 1), previews "N нь аль хэдийн байна (first … last) · M шинээр үүснэ", disables Үүсгэх when nothing is new or > 2000, and the result toast names both ranges.
- Later the owner chose the full local rebuild ("Full local rebuild (Recommended)"); it now lives in `db/test/` (rule in section 1).

## 3q. Админ role, pause, any new tag, full farm delete (2026-10-12)

What the owner asked: an "Админ" who creates farms and herders without super-admin powers and sees only what he created; the super admin alone deletes and pauses ("stop all tags"), and can finally delete fake farms (old delete_farm hit `tag_batches_farm_id_fkey`).

- **v49** `db/schema_v49_admin_role_pause.sql` (one transaction, safe to run twice; built from the live function texts by targeted edits; 96 role checks in `db/test/test_v49.sql` pass on a full rebuild v1→v49):
  - Role `admin` (no farm). `farms.created_by` = who created the farm. Helpers `is_admin()`, `admin_farm_ids()`, `admin_owns_farm()`, `admin_farm_folders()`. Extra **read-only** policies `admin_read` (ORed with the old ones, nobody else's access changes) on farms, profiles, cattle, photos, milk, health, repro, scans, public scans, transfers, tags, batches + photo files. `audit_log` stays super-only.
  - Админ **can**: `create_farm`, `admin_update_farm` (own farms), `admin_update_profile` (herder/farm admin of own farms; roles herder/farm_admin only; cannot switch a login off). **Cannot**: delete, pause, create tag numbers, register animals, add milk/vaccines, transfer, read Түүх.
  - Super admin: `admin_set_farm_owner(farm, admin)` hands an older farm to an Админ (farm edit window → "Хариуцсан Админ").
  - **Any new tag**: `register_cattle` / `tag_registration_info` no longer refuse "other farm"; the animal joins the herder's farm and the tag moves there. New reasons `paused`, `no_farm`.
  - **Pause**: `tags.paused_at / paused_by / pause_note`; `admin_pause_tags(codes, pause, note)` (super only, Telegram to owner + farm admins + the farm's Админ). `public_tag_state` → `'paused'` for a paused tag or a non-active farm; `public_tag_lookup` hides it; `record_public_scan` saves nothing; trigger `paused_guard` (`refuse_when_paused`) blocks new milk/health/repro/photos/scans/transfers and animal updates for everyone but the super admin. History is kept.
  - Farm pause ("Түр хаах" = `archive_farm`) now sends Telegram and remembers who was active; "Сэргээх" switches exactly those back on (farms paused before v49: all of them).
  - **`delete_farm`** (super, returns jsonb) removes the farm's animals + records, tags, batches, users; keeps and moves what belongs elsewhere (tag on another farm's animal, that animal's older records, a batch holding other farms' tags); users with history are switched off (`status disabled`, farm null) instead of deleted; history rows keep their text, lose the farm link. `farm_required` allows a disabled user without a farm.
  - **`delete_profile`** returns `'deleted'` or `'disabled'` (a user with history is switched off).
  - Lost-animal alert also goes to the farm's Админ.
- **Edge Function** `admin-users`: an active Админ may create herder/farm admin users and reset their passwords, only in farms he created; the super admin may also create "Админ" users. **Must be re-deployed** (paste the file).
- **Dashboard**: `body.role-admin` hides `.super-only` unless it also has `.mgr` (Хэрэглэгчид, Фермүүд, farm filters, farm code); `.no-admin` hides the transfer button and the user on/off switch. Админ's herd view is read-only (milk buttons off, vaccine view only). Role lists come from `roleOptions()`. Тагууд: "⏸ Түр зогсоох" / "▶ Идэвхжүүлэх" (super), "⏸ Түр зогсоосон" filter, badge and stat. Farm delete toast says what was removed / switched off.
- **t.html / cow.html**: a paused tag shows "⏸ Түр зогсоогдсон — Энэ таг түр зогсоогдсон. Админд хандана уу" + the site phone (`site_settings`), no scan is logged; the super admin still sees the animal with a banner. Registration says "Мал таны ферм рүү бүртгэгдэнэ."
- Checked with sample-data copies (`python dist/v49_ui.py`, then serve the repo root): Админ, super admin and farm admin dashboards, paused tap page, paused animal and registration pages — no console errors.
- ~~Deleting a farm deletes its tag numbers too~~ — changed in v50: they go to the stock (3r).

- 2026-10-12: commit "123" had overwritten the v49 file with v48's text, so v49 was not run at first; restored, then run on live (checked: `admin_pause_tags` answers anon with 42501 = exists). Also: deleting / pausing a farm never switches off a super admin or Админ linked to it.

## 3r. Tag stock "Фермгүй (агуулах)" (2026-10-12)

The owner: all tags sat in a test farm — pausing it would freeze them, deleting it would delete the numbers. He asked for a way to change the farm and a "no farm" option.
- **v50** `db/schema_v50_tag_stock.sql` (needs v49; one transaction; 29 checks in `db/test/test_v50.sql` + the 98 of v49 pass on a full rebuild v1→v50): `tags.farm_id` and `tag_batches.farm_id` may be null = the stock. `admin_assign_tags(codes, null)` moves unused tags to the stock; `admin_create_tags(..., null)` creates into it; a stock tag is "Шинэ таг" for everyone and joins the farm of the herder / farm admin who registers it (the super admin cannot register on it: reason `no_farm`); `admin_replace_tag` accepts a stock tag; `admin_tag_list` shows stock tags (left join). **`delete_farm` no longer deletes tag numbers**: they go to the stock (a tag of a deleted animal becomes `recycled`, usable again); a farm with only tags deletes without the force question; returns `tags_to_stock`.
- RLS unchanged: only the super admin sees stock tags.
- Dashboard (Тагууд, super admin): button "Ферм солих" (was "Фермд оноох") with "Фермгүй (агуулах)" first; "+ Таг үүсгэх" defaults to the stock; farm filter has "Фермгүй (агуулах)"; stat "Агуулахад (фермгүй)"; stock rows show the badge "Агуулах".

## 3s. Security, stress and no-signal tap check + v51 (2026-10-12)

v50 confirmed live (site = repo). Scripts are in the session scratchpad (not kept); method:
- **Live, as an anonymous visitor (public key): 180/183 pass.** Every table and view reads empty; empty inserts into all 24 tables refused; update/delete (filter matching no row) refused; all 63 non-public functions incl. every v49/v50 one → `permission denied`; webhook refuses missing/wrong secret; order form validates before saving; SQL-injection text harmless; storage not listable; sign-up OFF, no social logins; Edge Function refuses no-login and public-key calls; `db/`, `tools/`, `supabase/`, `dist/`, `.git`, notes → 404. The 3 "fails" are expected: `site_settings` is public on purpose (website contacts; also shows `updated_by` uuid — harmless), no HSTS header (GitHub Pages can't send it; http→https redirect works), and a false alarm on a comment in config.js.
- **Live stress (read-only): 870/870 OK** — pages p95 0.45 s; tap-page state p95 0.87 s at 20 parallel; 50 at the same instant p95 0.69 s.
- **Local race tests:** 10 herders registering the same tag at once → exactly 1; 60 strangers tapping one animal at once → 20 saved (limit); the same offline tap resent 20× at once → 1 row; one person tapping 30× → 3 saved.
- **No unescaped user text** found in the pages' HTML templates (heuristic scan).
- **No-signal tap (real t.html + offline.js in a browser, network simulated):** the tap time and GPS are stored on the phone at the tap; when signal returns (page open) or the page is opened again later, they are sent with the ORIGINAL time; the server keeps it (up to 7 days back) and marks the tap `was_offline`; the lost-animal Telegram shows the tap time and exact map link.
- **Limit (web, cannot be fixed):** a phone that has NEVER opened a YAK-TAG page cannot open the tap page at all with no signal — nothing is saved. Every phone that opened one before (herders, returning visitors) works offline.
- **Finding, fixed in v51:** any herder login could claim every blank tag in seconds by script (sequential codes, no limit; tested: 50 in one go).

**v51** `db/schema_v51_scan_time_limits.sql` (needs v50; 14 checks in `db/test/test_v51.sql`; full rebuild v1→v51 with v49+v50+v51 tests = 141 pass):
- `record_public_scan(..., p_age_ms bigint)`: the phone sends how long ago the tap was on its own clock → right time even with a wrong phone clock. The old 7-argument version is dropped (one function only — no PostgREST overload clash); pages already on phones keep working (parameter optional); `offline.js` retries without `p_age_ms` on an older database.
- Lost alert: a tap that arrives >5 min late adds "⏱ Сүлжээгүй үед уншуулсан — HH:MI-д ирсэн. Байршил нь уншуулсан үеийнх."
- `register_cattle`: at most 60 per login per hour (super admin exempt); the 50th sends ONE Telegram warning to super admins. Index `cattle_registered_by_idx`.
- `submit_order`: also 100 per day.
- **Background sending (`sw.js`, Android Chrome/Edge/Samsung):** a queued stranger's tap asks for a `sync`; the browser wakes the service worker when online, even with the page closed, and it sends the tap (same request, public key; `API`/`PUBLIC_KEY` in sw.js must match config.js). Tested in real headless Chrome via DevTools `ServiceWorker.dispatchSyncEvent` with the page closed → queue emptied, server answered OK (also through the pre-v51 fallback). iPhone/Firefox: no background sync → sent on the next page open, as before.
- Note: during the browser test the real service worker sent two test taps for YT-008100 / YT-008222 to live — both have no animal on live (checked), so nothing was saved. Test pages now block the service worker (rule in section 1).

**Still open (owner's decisions):** tag password YKTG is public in the repo → anyone with an NFC app can rewrite a tag's link (owner chose YKTG for all); `scan_caller_hash` trusts `X-Forwarded-For` when `cf-connecting-ip` is missing (measure before changing); photos not in the backup.

## 3t. Backups: database weekly, photos monthly (2026-10-12)

The owner's choice: photos once a month, everything else once a week.
- `backup.yml`: cron `7 3 * * 1` (was daily). 30 folders kept = 30 weeks; older ones in the backup repo's history.
- New `photos-backup.yml` (cron `37 3 1 * *`, also Run workflow): `scripts/backup_photos.py` lists both buckets with the service key (folders = entries with `id: null`, paged by 1000), downloads only files whose size differs or that are missing, removes files deleted in Supabase (git history keeps them), refuses paths leaving the folder, turns the run red on any failure but still commits what it copied, never deletes anything when a listing fails. Tested against a fake Storage API: 1,207 photos incl. >1000 in one folder and odd names, re-run downloads nothing, delete/new/changed mirrored, listing error deletes nothing, `../` refused, missing key = clear error.
- First real run: the owner presses Actions → Monthly photo backup → Run workflow once and checks `Yak-Tag-backups/photos/`.

## 3u. Phone-only login + herder app (2026-10-23, branch `feature/phone-login-herder-app`)

System check first (all green): 59/59 published files = repo; notes/SQL/tools 404; as a visitor all 24 tables read empty, nothing writable, storage not listable, sign-up off, Edge Function 401 without login; 22 scripts parse; keep-alive 10-21, weekly backup 10-19, photo backup 10-12 all green; HTTPS to 2027-01-03.

**Phone-only login** (the owner: "only telephone number and password" — the cow page's box opened the number keypad, so an e-mail login couldn't be typed on a phone):
- `cow.html`, `admin/index.html`, `app/`: label "Утасны дугаар", `type="tel"`, messages "Утасны дугаар …". A too-short number is refused before sending.
- Edge Function `admin-users` (**must be re-deployed**): `create` needs a phone (e-mail ignored); new `set_login_phone` (super admin: anyone incl. himself; Админ: herders/farm admins of his own farms) moves a login to `<phone>@yaktag.invalid`, keeps the password, sets `profiles.phone`, history `set_login_phone {from, to}`; new `list_logins`. The password check now applies only to `create` / `set_password`.
- Dashboard → Хэрэглэгчид: a red "✉ И-мэйлээр нэвтэрдэг — утас болгоно уу" under each e-mail login; Засах shows "Нэвтрэх нэр" and "📱 Дээрх утсаар нэвтэрдэг болгох" (uses the Утас field above). New-user form: phone only. Түүх labels: create_user / set_password / set_login_phone.
- Tests (Node, fake Supabase): Edge Function 18/18, dashboard 11/11.

**Herder app** https://yaktag.org/app/ (free, no app store — Apple $99/yr, Google $25 aren't):
- Installable web app: `app/manifest.json` (scope `/`, start `/app/`, standalone, icons `assets/app-icon-*.png` made from the tag artwork), Android "Суулгах" button (beforeinstallprompt), iPhone Safari steps (Share → Add to Home Screen).
- Login (phone + password) → "Миний мал": herder = own animals, farm admin = whole farm (RLS, `cattle_dashboard`); badges lost / sold… / milk today / vaccine overdue or ≤7 days; search; open by number ("8000" → YT-008000, also new tags → registration); Android "📶 Таг уншуулах" (Web NFC reads the tag's link inside the app). Super admin / Админ get "use the dashboard".
- No signal: the list is kept on the phone (`yt-applist`), the page is in `sw.js` SHELL (`app/`, paths ending `/` count as pages); `offline.js` now registers `/sw.js` by its own address (from `app/` a relative `sw.js` would be `app/sw.js`).
- Homepage intro: a "Малчны апп" button → `app/` (owner chose only this spot, 2026-10-23); its own style `.btn-app` = the tag's soft blue (`--sky-l` / `--sky`, solid blue on hover), no emoji. style-a.css `?v=2026102301`.
- `cow.html` opened from the app (standalone, or `sessionStorage yt-from-app`): "‹" before the logo and the bottom link → `app/` ("Миний мал") — an installed iPhone app has no back button. Its login card links "📲 Малчны апп суулгах". Logout also clears `yt-applist`.
- Tests: app 26/26, cow app-mode + sw 11/11. **Not seen in a real browser yet** (local preview was blocked once by a safety rule on 2026-10-07) — check on an Android and an iPhone after pushing.

## 3v. Strict phone-only + password reset by Telegram (2026-10-23, branch `feature/telegram-reset-phone-only`)

Live check of 3u first: pushed, Pages built, app/ + manifest + icons + changed pages = repo; `tools/python` (empty, the owner's) is in the repo — harmless, `tools/` isn't published.
- **Strict:** `loginEmail()` no longer passes e-mails through; `loginPhoneError()` gives one message set for all login / reset boxes ("Зөвхөн утасны дугаараа оруулна уу" for letters or @).
- **`password-reset` Edge Function (new, public, Verify JWT OFF):** `request {phone}` → if the login exists, is active and has `telegram_links`, a 6-digit code goes to that Telegram (token from `app_secrets`); the answer is the same in every case. Limits: 1 code/minute, 3/hour per login; code 15 min, 5 wrong tries; only a SHA-256 of `id:code` is kept, in the login's `app_metadata.pw_reset` (not readable/writable by browsers). `confirm {phone, code, password}` → new password, `pw_reset` removed, history `password_reset_telegram`, Telegram "✅ … солигдлоо".
- **App:** "Нууц үгээ мартсан уу?" → reset screen (phone → code + new password twice → logged straight in); `app/?reset=1` opens it (linked from the cow page and dashboard login cards, `a.backsite.forgot` is left alone by cow's app mode); shows the site phone as the last resort. Home: "🔔 Telegram холбох" card (telegram_status / telegram_link_code, then polls) or "✓ Telegram холбогдсон".
- `admin-users` unchanged in rights (an attempt to let farm admins reset passwords was undone at the owner's word).
- Tests (Node, fakes): password-reset 19, admin-users 18, app 41, dashboard 11, cow + sw 13 — 102 pass.

## 3w. "Устгах" removes the login too (2026-10-23, branch `feature/delete-removes-login`)

The owner found old test logins (ganzo@yaktag.test, admin07@yaktag.test …) still in `auth.users`: `delete_profile` only ever removed (or switched off) the PROFILE. Now:
- `admin-users` → `delete_login` (super admin only, never himself): no profile left → `auth.admin.deleteUser`; profile kept as `disabled` (history) → login renamed `removed-<id>@yaktag.invalid` + banned (`ban_duration 876000h`), so the phone number is free; profile still in use → refused. History `login_delete {login, result}`. `set_login_phone` lifts the ban when the profile is active again.
- Dashboard: `delUser` calls `delete_login` after `delete_profile` (and says plainly if that step failed); Хэрэглэгчид shows "Профайлгүй нэвтрэх эрх" (logins with no profile — e.g. from deleted farms or old deletions) with Устгах / "Бүгдийг устгах" (super admin). A blocked login shows as "хаагдсан" in the edit window.
- `db/cleanup_email_logins.sql` (list e-mail logins; delete named ones safely) stays for a one-off cleanup.
- Tests: admin-users 27, dashboard delete 9, dashboard 11 (+ app 41, cow/sw 13, reset 19) — 120 pass. Row-button wiring unchanged.

## 3x. Load test + v52 access-rule speed-up (2026-10-23)

**Live, read-only** (no data written; logins only with a number that has no account): database reads 25 → 50 at once = 61 → 125/s, p50 ~350 ms flat, 0 errors; `public_tag_state` 50 at once 120/s; app page (GitHub Pages) 43/s; one login ~0.43 s. Server time per request **1 ms** (`x-envoy-upstream-service-time`) — the ~350 ms is distance: the project is in **AWS ap-southeast-2 (Sydney)** (db host IPv6 2406:da1c… matched against AWS ip-ranges.json). Seoul/Tokyo would be ~3× closer (owner chose not to move for now).
**Local writes** (full rebuild + 200 herders, 4,000 animals, 120k milk rows; pgbench with real roles/RLS): milk insert 11.6k–21.7k/s, app scan / stranger tap / lookup 16k–58k/s (repeat limits working). **Bottleneck: a herder's herd list (`cattle_dashboard`) — 37 of 53 RLS rules called `is_super()/my_role()/my_farm()/auth.uid()` once PER ROW.**
- **v52** `db/schema_v52_rls_speed.sql` (no data touched; safe twice; a rule it may not change is skipped and named): wraps those calls as `(select …)` in every public/storage policy (regex with look-behind, so already wrapped calls stay). Measured: herd list 95 → 5.6 ms (10 at once), 353 → 14 ms (40 at once); 105 → 1,782 and 113 → 2,809 lists/s. Fresh rebuild v1→v52: 0 rules left per-row, role tests 141/141. Run 2 changes nothing (policy texts identical).
- Note: `db/test/replay.py` replays EVERY `db/schema_v*.sql` — set a new patch aside to measure "before".
- Logins: Supabase limits sign-ins per internet address (default roughly 30 per 5 min) — a training day with many herders on one Wi-Fi / mobile NAT could hit it; Supabase → Authentication → Rate Limits (free) if that happens.

## 3y. PLAN (not started): move the database closer to Mongolia (2026-10-23)

**Measured from the owner's connection** (TCP connect to AWS regional endpoints, best of 4): Hong Kong 57 ms (not a Supabase region), **Tokyo ap-northeast-1 74 ms**, Seoul ap-northeast-2 98 ms, Singapore 166 ms, **Sydney (now) 249 ms**. Today a database request takes ~350 ms (server 1 ms); in Tokyo expect roughly half. Recommended: **Tokyo**, Seoul second. (Mobile networks may route differently — re-measure in the rehearsal.)
**A region can't be changed** (Supabase docs "Change Project Region"): new project in Tokyo + copy everything. Free plan = $0. Free allows **2 active free projects per organization** (counted over all Owners/Admins; paused ones don't count) — check a slot is free (pause another project for the move if needed).
**Sizes measured** (local rebuild): milk entry 252 B, app scan 324 B, stranger tap 381 B, animal ~395 B + tag ~350 B (with indexes). ≈ 85 KB per cow per year (≈120 milk entries + ≈150 page scans). Photos live: 32–67 KB (phone shrinks to 1200 px); ~3 per animal (profile, public copy, muzzle).
**Free plan capacity:** DB 500 MB ≈ 5,000 cow-years; photos 1 GB ≈ 5,000+ animals; **egress 5 GB/month is the tightest**: each animal-page open downloads up to 6 photos through fresh signed URLs (never cached) ≈ 150–300 KB → ~1,000 animals opened daily fills it. Fix (free, small): reuse signed URLs ~50 min / load photos on demand / thumbnails → ~10× less. Pro ($25/month/org incl. Micro compute 1 GB RAM): 8 GB DB, 100 GB files, 250 GB egress, daily backups, no pausing → ~50,000 animals.
**Steps (owner + Claude):** 1) owner creates the Tokyo project (free), same org; 2) settings: sign-ups OFF, rate limits, site URL, extensions pgcrypto / btree_gist / pg_net, buckets cattle-photos (private) + cattle-public (public) with v46 limits; 3) rehearsal: copy DB (pg_dump of public schema + auth.users/identities data — keeps user ids and password hashes), copy photos (Supabase's storage script or a restore twin of scripts/backup_photos.py), deploy admin-users + password-reset (Verify JWT OFF), run telegram_setup, test with a local copy of the site; 4) move night (~1–2 h, e.g. 22:00 UB): copy again from the old project, switch the address + publishable key in config.js, sw.js, assets/contacts.js, order.html, tools/nfc_tag.py (+ bump ?v=), GitHub secrets SUPABASE_URL / SUPABASE_SERVICE_KEY / SUPABASE_ANON_KEY, push; 5) everyone logs in once again (same passwords); 6) keep the Sydney project paused 2 weeks as fallback, then delete. NFC tags hold yaktag.org links → no tag changes. Rollback = revert the config commit (entries made in Tokyo in between would need copying back).

## 4. To do next

0d. ~~Run v52~~ — done 2026-10-23 on live; its CHECK returned no rows (no access rule left calling helpers per row).

0c. **Deploy `admin-users` again** (it changed: `delete_login`) — any time before or after the push; until then "Устгах" says the login step failed.
0b. **Before pushing `feature/telegram-reset-phone-only` (strict phone-only):** run `select email from auth.users where email not like '%@yaktag.invalid';` — every row must first be moved to a phone (dashboard → Хэрэглэгчид → Засах → "📱 Дээрх утсаар нэвтэрдэг болгох"; needs the new `admin-users` deployed), or that person can't log in after the push. Then deploy `password-reset` (Edge Functions → new → paste → Deploy → **Verify JWT OFF**), then push. Herders / farm admins link Telegram once (app home card or the animal page's Telegram button) to be able to reset.
0. **After pushing `feature/phone-login-herder-app`:** (a) re-deploy the Edge Function `admin-users` (paste the file); (b) dashboard → Хэрэглэгчид → every "✉ И-мэйлээр нэвтэрдэг" row → Засах → phone in "Утас" → "📱 Дээрх утсаар нэвтэрдэг болгох" (own account too); check in SQL Editor: `select email from auth.users where email not like '%@yaktag.invalid';` → no rows; (c) open https://yaktag.org/app/ on an Android and an iPhone, install, log in as a herder.

1. ~~v51~~ — run and pushed 2026-10-12; checked live: `record_public_scan` accepts `p_age_ms` and the older call forms (unknown tag → null), security probe 180/183 (same 3 expected), background sync test sent the tap with no page open.
2. ~~Edge Function `admin-users`~~ — re-deployed 2026-10-12; the owner tested the Админ role (creating a farm + herder, sees only his own).
3. ~~Test farm's tags to the stock~~ — done 2026-10-12 (stock tags still answer "new" on the tap page, checked).
2. **BACKUP_TOKEN expiry:** GitHub → Settings → Developer settings → Fine-grained tokens → open the backup token → read "Expires". If it's near, Regenerate (longest expiry) and update the repo secret.
3. Optional **full backup:** add secret `SUPABASE_DB_URL` (Supabase → Connect → Session pooler URI with the database password), then Actions → Weekly database backup → Run workflow → both jobs green.
4. ~~Re-protect field tags~~ — not needed: YKTG is the standard (section 3n).
5. **Real lost-animal test (optional):** mark a test cow lost, tap its tag with a phone that isn't logged in, a Telegram alert with a map link should arrive, then press "Олдсон".
6. Ask **farm admins and herders to link Telegram**.
7. Google Search Console: submit `https://yaktag.org/sitemap.xml` if it isn't listed. "Page with redirect" (http://, www.) is expected — don't validate it.
8. Done earlier: Sunday backup check (2026-09-28), marketing pages (2026-10-01), order form → Telegram (v41), DNSSEC + SPF/DMARC (verified on 2026-10-07).

## 5. Idea list (not started)

- Feeding entries without signal: send them through the offline queue, as milk and pregnancy entries already do.
- ~~Install to the home screen as an app (PWA manifest)~~ — the herder app, 2026-10-23 (3u).
- **More animal kinds (owner, 2026-10-23: horses, then cats and dogs).** Proposed, not built: one system with a kind switch (🐄 Үхэр | 🐎 Адуу | …) on the app's and dashboard's main screen; lists, counts, forms and words follow it (тугал→унага, бух→азарга, үнээ→гүү); registration starts with the kind, then that kind's breeds. Already there: `cattle.species` / `breeds.species` ('cattle','horse'), 6 horse breeds, 340-day gestation, унага/азарга words, Excel column. Build it data-driven (a kinds list), so cats/dogs (pets: owner contact matters more than milk/pregnancy) are a new row, not new code. Owner to confirm the horse details first (mare's milk / airag, horse vaccine list with a vet, Mongolian age names).
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

**Test SQL safely before running it on live.** Best: the full rebuild in `db/test/` (section 1). For a quick empty throwaway Postgres 18 on port 55432:
```bash
PG="/c/Program Files/PostgreSQL/18/bin"; D="$TEMP/yt-pgtest"
"$PG/initdb" -D "$D" -U tester -A trust -E UTF8
"$PG/pg_ctl" -D "$D" -o "-p 55432 -c listen_addresses=localhost" -l "$D/log.txt" start
# ... run tests with PGCLIENTENCODING=UTF8 "$PG/psql" -h localhost -p 55432 -U tester -d postgres -f test.sql
"$PG/pg_ctl" -D "$D" stop -m fast && rm -rf "$D"
```

**Serve locally for click-tests:** `python -m http.server 8765`, then open `http://127.0.0.1:8765/admin/index.html`.
