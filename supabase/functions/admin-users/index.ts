// ============================================================
// YAK-TAG — admin-users (Supabase Edge Function)
//
// The account actions a web page must never do itself, because they
// need the service_role key:
//   create           — new user with a first password, role and farm.
//                      The login is ALWAYS a phone number (2026-10-23).
//   set_password     — admin resets a user's forgotten password
//   set_login_phone  — turns a user's login into a phone number (also an
//                      old e-mail login); the password stays the same
//   list_logins      — which login each user has (to find e-mail logins)
//
// Phone logins are stored as <digits>@yaktag.invalid, a reserved domain
// that never receives mail; people only ever see and type the number.
//
// Who may call it (checked against profiles on every request — the
// page's claim about who it is counts for nothing):
//   · an active SUPER ADMIN — anyone, any role (also "Админ");
//   · an active АДМИН (role 'admin', schema v49) — only малчин / ферм
//     админ, only in farms he created himself.
// The caller is identified from their own login token.
//
// Deploy: Supabase dashboard → Edge Functions → Deploy a new function
// → Via Editor → name it  admin-users  → paste this file → Deploy.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to every
// function automatically; nothing to configure.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// Must match HERDER_EMAIL_DOMAIN and normPhone() in config.js exactly,
// or a herder created here cannot log in there.
const HERDER_EMAIL_DOMAIN = "yaktag.invalid";

function normPhone(s: string): string {
  let d = String(s ?? "").replace(/\D/g, "");
  if (d.length === 11 && d.startsWith("976")) d = d.slice(3);   // +976 prefix
  return d;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  // ---- who is calling? ----
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return reply(401, { error: "Нэвтэрнэ үү." });

  const { data: me } = await admin.from("profiles")
    .select("role, status").eq("id", user.id).maybeSingle();
  const isSuper = me?.role === "super_admin" && me?.status === "active";
  const isAdmin = me?.role === "admin" && me?.status === "active";
  if (!isSuper && !isAdmin) {
    return reply(403, { error: "Зөвхөн ерөнхий админ эсвэл Админ." });
  }
  // an Админ works only in the farms he created
  const callerId = user.id;
  const ownsFarm = async (farmId: string | null): Promise<boolean> => {
    if (isSuper) return true;
    if (!farmId) return false;
    const { data } = await admin.from("farms").select("id")
      .eq("id", farmId).eq("created_by", callerId).maybeSingle();
    return !!data;
  };

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "Bad request" }); }

  // Only the actions that set a password need one.
  const password = String(body.password ?? "");
  if ((body.action === "create" || body.action === "set_password") && password.length < 8) {
    return reply(400, { error: "Нууц үг хамгийн багадаа 8 тэмдэгт байна." });
  }

  // A herder / farm admin of one of the caller's farms (the super admin: anyone).
  const mayManage = async (p: { role: string; farm_id: string | null } | null) =>
    isSuper || (!!p && ["herder", "farm_admin"].includes(p.role) && await ownsFarm(p.farm_id));

  // ---- create ----
  if (body.action === "create") {
    const fullName = String(body.full_name ?? "").trim();
    const phone = normPhone(String(body.phone ?? ""));
    const role = String(body.role ?? "herder");
    const farmId = body.farm_id ? String(body.farm_id) : null;
    // Phone only: every login is typed on a phone's number keypad.
    const email = phone ? `${phone}@${HERDER_EMAIL_DOMAIN}` : "";

    if (!fullName) return reply(400, { error: "Нэрээ оруулна уу." });
    const allowed = isSuper ? ["herder", "farm_admin", "admin", "super_admin"] : ["herder", "farm_admin"];
    if (!allowed.includes(role)) {
      return reply(400, { error: "Эрх буруу." });
    }
    const noFarm = role === "super_admin" || role === "admin";
    if (!noFarm && !farmId) return reply(400, { error: "Ферм сонгоно уу." });
    if (!noFarm && !(await ownsFarm(farmId))) {
      return reply(403, { error: "Зөвхөн өөрийн үүсгэсэн фермд хэрэглэгч нэмнэ." });
    }
    if (!phone) return reply(400, { error: "Утасны дугаар оруулна уу." });
    if (phone.length < 6 || phone.length > 15) {
      return reply(400, { error: "Утасны дугаар буруу." });
    }

    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,           // no email is ever sent
      user_metadata: { full_name: fullName },
    });
    if (cErr || !created.user) {
      const dup = /already|registered|exists/i.test(cErr?.message ?? "");
      return reply(400, { error: dup ? "Энэ утасны дугаараар хэрэглэгч аль хэдийн бүртгэлтэй." : (cErr?.message ?? "Үүсгэж чадсангүй.") });
    }

    const { error: pErr } = await admin.from("profiles").insert({
      id: created.user.id, full_name: fullName, phone: phone || null,
      role, farm_id: noFarm ? null : farmId, status: "active",
    });
    if (pErr) {
      // Don't leave a login with no profile behind.
      await admin.auth.admin.deleteUser(created.user.id);
      return reply(400, { error: "Профайл үүсгэж чадсангүй: " + pErr.message });
    }

    await admin.from("audit_log").insert({
      farm_id: noFarm ? null : farmId, actor_id: user.id, action: "create_user",
      entity: "profiles", entity_id: created.user.id,
      detail: { role, login: email },
    });
    return reply(200, { id: created.user.id, login: phone || email });
  }

  // ---- set_password ----
  if (body.action === "set_password") {
    const id = String(body.user_id ?? "");
    if (!id) return reply(400, { error: "user_id required" });
    const { data: p } = await admin.from("profiles").select("farm_id, role").eq("id", id).maybeSingle();
    if (!(await mayManage(p))) {
      return reply(403, { error: "Энэ хэрэглэгчийн нууц үгийг солих эрхгүй." });
    }
    const { error } = await admin.auth.admin.updateUserById(id, { password });
    if (error) return reply(400, { error: error.message });

    await admin.from("audit_log").insert({
      farm_id: p?.farm_id ?? null, actor_id: user.id, action: "set_password",
      entity: "profiles", entity_id: id, detail: {},
    });
    return reply(200, { ok: true });
  }

  // ---- set_login_phone ----
  // The user then logs in with this number and the SAME password. Also
  // the way to move an old e-mail login (e.g. the super admin's own) to a
  // phone login. The profile's phone is set to the same number.
  if (body.action === "set_login_phone") {
    const id = String(body.user_id ?? "");
    const phone = normPhone(String(body.phone ?? ""));
    if (!id) return reply(400, { error: "user_id required" });
    if (phone.length < 6 || phone.length > 15) {
      return reply(400, { error: "Утасны дугаар буруу." });
    }
    const { data: p } = await admin.from("profiles").select("farm_id, role").eq("id", id).maybeSingle();
    if (!(await mayManage(p))) {
      return reply(403, { error: "Энэ хэрэглэгчийн нэвтрэх нэрийг солих эрхгүй." });
    }
    const { data: before } = await admin.auth.admin.getUserById(id);
    const login = `${phone}@${HERDER_EMAIL_DOMAIN}`;
    if (before?.user?.email === login) return reply(200, { ok: true, login: phone, unchanged: true });

    const { error } = await admin.auth.admin.updateUserById(id, { email: login, email_confirm: true });
    if (error) {
      const dup = /already|registered|exists/i.test(error.message);
      return reply(400, { error: dup ? "Энэ утасны дугаараар өөр хэрэглэгч нэвтэрдэг." : error.message });
    }
    await admin.from("profiles").update({ phone }).eq("id", id);

    // Old login in the history, so it can be traced (e-mails written as-is,
    // phone logins as their number).
    const old = before?.user?.email ?? "";
    await admin.from("audit_log").insert({
      farm_id: p?.farm_id ?? null, actor_id: user.id, action: "set_login_phone",
      entity: "profiles", entity_id: id,
      detail: { from: old.endsWith(`@${HERDER_EMAIL_DOMAIN}`) ? old.split("@")[0] : old, to: phone },
    });
    return reply(200, { ok: true, login: phone });
  }

  // ---- list_logins ----
  // [{ id, login, phone_login }] for the users the caller may manage, so
  // the dashboard can mark who still logs in with an e-mail.
  if (body.action === "list_logins") {
    const out: { id: string; login: string; phone_login: boolean }[] = [];
    for (let page = 1; page <= 50; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) return reply(400, { error: error.message });
      for (const u of data.users) {
        const e = u.email ?? "";
        const phoneLogin = e.endsWith(`@${HERDER_EMAIL_DOMAIN}`);
        out.push({ id: u.id, login: phoneLogin ? e.split("@")[0] : e, phone_login: phoneLogin });
      }
      if (data.users.length < 1000) break;
    }
    if (isSuper) return reply(200, { logins: out });
    // an Админ: only herders / farm admins of the farms he created
    const { data: farms } = await admin.from("farms").select("id").eq("created_by", callerId);
    const farmIds = (farms ?? []).map(f => f.id);
    const ok = new Set<string>();
    if (farmIds.length) {
      const { data: mine } = await admin.from("profiles").select("id")
        .in("farm_id", farmIds).in("role", ["herder", "farm_admin"]);
      for (const p of mine ?? []) ok.add(p.id);
    }
    return reply(200, { logins: out.filter(o => ok.has(o.id)) });
  }

  return reply(400, { error: "Unknown action" });
});
