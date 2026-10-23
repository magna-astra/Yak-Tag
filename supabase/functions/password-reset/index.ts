// ============================================================
// YAK-TAG — password-reset (Supabase Edge Function), 2026-10-23
//
// A forgotten password, without an admin: the YAK-TAG Telegram bot sends
// a 6-digit code to the Telegram linked to that phone login (dashboard /
// animal page / app → "Telegram холбох"). The person types the code and
// a new password in the herder app (app/?reset=1). No e-mail, no SMS,
// free. Someone without Telegram asks the super admin / Админ (Хэрэглэгчид
// → "Нууц үг") — the last resort.
//
//   request  { phone }                   → sends a code (if the login exists,
//                                            is active and has Telegram)
//   confirm  { phone, code, password }   → sets the new password
//
// Called by people who are NOT logged in, so this function is public:
// in Supabase, "Verify JWT" (Enforce JWT verification) must be OFF for it.
// Protection instead:
//   · the answer to "request" is the same whether the number exists or not
//     (nobody can find out who has an account);
//   · at most 1 code a minute and 3 an hour per login;
//   · a code lives 15 minutes and dies after 5 wrong tries;
//   · only a hash of the code is kept, in the login's app_metadata, which
//     no browser can read or write;
//   · after a reset the same Telegram is told "password changed".
//
// Deploy: Supabase dashboard → Edge Functions → Deploy a new function →
// Via Editor → name it  password-reset  → paste this file → Deploy →
// then in its Details / Settings switch "Verify JWT" OFF.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically;
// the bot token is read from app_secrets (telegram_token), as the alerts do.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// Must match HERDER_EMAIL_DOMAIN and normPhone() in config.js exactly.
const HERDER_EMAIL_DOMAIN = "yaktag.invalid";
function normPhone(s: string): string {
  let d = String(s ?? "").replace(/\D/g, "");
  if (d.length === 11 && d.startsWith("976")) d = d.slice(3);   // +976 prefix
  return d;
}

const CODE_TTL_MS = 15 * 60 * 1000;
const MAX_TRIES = 5;
const COOLDOWN_MS = 60 * 1000;
const MAX_PER_HOUR = 3;

const SENT = "Хэрэв энэ дугаар YAK-TAG-ийн Telegram-тай холбогдсон бол код илгээлээ. Telegram-аа шалгана уу. Код ирээгүй бол 1 минутын дараа дахин оролдох, эсвэл админд хандана уу.";
const BAD_CODE = "Код буруу эсвэл хугацаа нь дууссан. Шинэ код авна уу.";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function sha256(s: string): Promise<string> {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
}
function sixDigits(): string {
  const a = new Uint32Array(1);
  let n: number;
  do { crypto.getRandomValues(a); n = a[0]; } while (n >= 4294000000);   // no modulo bias
  return String(n % 1000000).padStart(6, "0");
}
function sameText(a: string, b: string): boolean {                     // constant time
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

type Reset = { h?: string; exp?: number; tries?: number; sent?: number[] };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "Bad request" }); }

  const phone = normPhone(String(body.phone ?? ""));
  if (phone.length < 6 || phone.length > 15) return reply(400, { error: "Утасны дугаар буруу." });
  const login = `${phone}@${HERDER_EMAIL_DOMAIN}`;

  // the login with this phone (the user list is small; 1000 per page)
  let user: { id: string; app_metadata?: Record<string, unknown> } | null = null;
  for (let page = 1; page <= 50 && !user; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) return reply(500, { error: "Түр алдаа гарлаа. Дахин оролдоно уу." });
    user = data.users.find(u => u.email === login) ?? null;
    if (data.users.length < 1000) break;
  }
  const { data: prof } = user
    ? await admin.from("profiles").select("status, farm_id").eq("id", user.id).maybeSingle()
    : { data: null };
  const active = !!user && prof?.status === "active";

  const telegram = async (text: string) => {
    if (!user) return false;
    const { data: link } = await admin.from("telegram_links").select("chat_id").eq("profile_id", user.id).maybeSingle();
    const { data: tok } = await admin.from("app_secrets").select("value").eq("name", "telegram_token").maybeSingle();
    if (!link || !tok) return false;
    try {
      const r = await fetch(`https://api.telegram.org/bot${tok.value}/sendMessage`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: link.chat_id, text }),
      });
      if (!r.ok) console.warn("telegram", r.status);
      return r.ok;
    } catch (e) { console.warn("telegram", e); return false; }
  };

  // ---- request: send a code ----
  if (body.action === "request") {
    if (!active) return reply(200, { ok: true, message: SENT });
    const now = Date.now();
    const old = (user!.app_metadata?.pw_reset ?? {}) as Reset;
    const sent = (old.sent ?? []).filter(t => now - t < 3600000);
    if (sent.length && now - sent[sent.length - 1] < COOLDOWN_MS) return reply(200, { ok: true, message: SENT });
    if (sent.length >= MAX_PER_HOUR) return reply(200, { ok: true, message: SENT });

    const code = sixDigits();
    const { error } = await admin.auth.admin.updateUserById(user!.id, {
      app_metadata: { pw_reset: { h: await sha256(`${user!.id}:${code}`), exp: now + CODE_TTL_MS, tries: 0, sent: [...sent, now] } },
    });
    if (error) return reply(500, { error: "Түр алдаа гарлаа. Дахин оролдоно уу." });
    await telegram(
      `🔑 YAK-TAG нууц үг сэргээх код: ${code}\n\n` +
      `15 минут хүчинтэй. Кодыг хэнд ч битгий хэлээрэй.\n` +
      `Та өөрөө хүсээгүй бол энэ мессежийг үл тоомсорлоно уу — нууц үг өөрчлөгдөхгүй.`);
    return reply(200, { ok: true, message: SENT });
  }

  // ---- confirm: code + new password ----
  if (body.action === "confirm") {
    const code = String(body.code ?? "").replace(/\D/g, "");
    const password = String(body.password ?? "");
    if (password.length < 8) return reply(400, { error: "Нууц үг хамгийн багадаа 8 тэмдэгт байна." });
    if (!active || code.length !== 6) return reply(400, { error: BAD_CODE });
    const r = (user!.app_metadata?.pw_reset ?? null) as Reset | null;
    if (!r || !r.h || !r.exp || Date.now() > r.exp || (r.tries ?? 0) >= MAX_TRIES) {
      return reply(400, { error: BAD_CODE });
    }
    if (!sameText(await sha256(`${user!.id}:${code}`), r.h)) {
      await admin.auth.admin.updateUserById(user!.id, { app_metadata: { pw_reset: { ...r, tries: (r.tries ?? 0) + 1 } } });
      return reply(400, { error: BAD_CODE });
    }
    const { error } = await admin.auth.admin.updateUserById(user!.id, { password, app_metadata: { pw_reset: null } });
    if (error) return reply(400, { error: error.message });

    await admin.from("audit_log").insert({
      farm_id: prof?.farm_id ?? null, actor_id: user!.id, action: "password_reset_telegram",
      entity: "profiles", entity_id: user!.id, detail: {},
    });
    await telegram("✅ YAK-TAG нууц үг тань солигдлоо.\nТа өөрөө солиогүй бол админд яаралтай хандана уу.");
    return reply(200, { ok: true });
  }

  return reply(400, { error: "Unknown action" });
});
