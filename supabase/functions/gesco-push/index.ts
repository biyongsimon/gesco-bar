// GesCo Bar · notifications push (application fermée).
// - { action: "key" } : clé publique VAPID (créée au premier appel, la clé privée ne quitte jamais le serveur)
// - appel interne de la base (en-tête x-hook) : { staff: [...], title, body, url, tag } -> envoi à tous les appareils de ces employés
// - appel interne { admins: true, ... } -> alertes de l'éditeur (nouvelle erreur, site en panne)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const URL = Deno.env.get("SUPABASE_URL")!;
const raw = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEYS") ?? "";
let SERVICE = raw; try { const o = JSON.parse(raw); SERVICE = o.default ?? Object.values(o)[0]; } catch { /* clé simple */ }
const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function config() {
  let { data: c } = await admin.rpc("gb_admin_push_config");
  if (!c?.pub || !c?.priv) {
    const k = webpush.generateVAPIDKeys();
    await admin.rpc("gb_admin_push_set_vapid", { p_pub: k.publicKey, p_priv: k.privateKey });
    ({ data: c } = await admin.rpc("gb_admin_push_config"));
  }
  return c as { pub: string; priv: string; hook: string };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  let body: Record<string, unknown>; try { body = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }
  try {
    const c = await config();
    if (body.action === "key") return json({ key: c.pub });
    if (!c.hook || req.headers.get("x-hook") !== c.hook) return json({ error: "Non autorisé." }, 401);
    webpush.setVapidDetails("https://gescobar-cm.pages.dev", c.pub, c.priv);
    const payload = JSON.stringify({ title: String(body.title ?? "GesCo Bar").slice(0, 120), body: String(body.body ?? "").slice(0, 300), url: String(body.url ?? "./"), tag: String(body.tag ?? "") });
    if (body.admins === true) {
      const { data: list } = await admin.rpc("gb_admin_push_admins");
      let sent = 0; const gone: string[] = [], ok: string[] = [];
      await Promise.all(((list ?? []) as { endpoint: string; p256dh: string; auth: string }[]).map(async (s) => {
        try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" }); sent++; ok.push(s.endpoint); }
        catch (e) { const code = (e as { statusCode?: number }).statusCode; if (code === 404 || code === 410) gone.push(s.endpoint); else console.error("push_admin_error", code, String((e as Error).message ?? e).slice(0, 200)); }
      }));
      await admin.rpc("gb_admin_push_admins_done", { p_ok: ok, p_gone: gone });
      return json({ sent, removed: gone.length });
    }
    const staff = (Array.isArray(body.staff) ? body.staff : []).map(String).slice(0, 200);
    if (!staff.length) return json({ sent: 0 });
    const { data: subs } = await admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").in("staff_id", staff);
    let sent = 0; const gone: string[] = [], ok: string[] = [];
    await Promise.all((subs ?? []).map(async (s) => {
      try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600, urgency: "high" }); sent++; ok.push(s.id); }
      catch (e) { const code = (e as { statusCode?: number }).statusCode; if (code === 404 || code === 410) gone.push(s.id); else console.error("push_error", code, String((e as Error).message ?? e).slice(0, 200)); }
    }));
    if (gone.length) await admin.from("push_subscriptions").delete().in("id", gone);
    if (ok.length) await admin.from("push_subscriptions").update({ last_ok: new Date().toISOString() }).in("id", ok);
    return json({ sent, removed: gone.length });
  } catch (e) { console.error("push_fatal", String(e)); return json({ error: "Envoi impossible." }, 500); }
});
