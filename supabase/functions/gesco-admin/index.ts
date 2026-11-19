// GesCo Bar · fonction serveur : inscription d'un bar, connexion par PIN, ajout du personnel.
// verify_jwt = false : les actions publiques (inscription, liste, PIN) n'ont pas de session ;
// l'action staff_create vérifie elle-même le jeton de l'appelant.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL = Deno.env.get("SUPABASE_URL")!;
function pickKey(legacy: string, modern: string): string | undefined {
  const v = Deno.env.get(legacy);
  if (v) return v;
  const raw = Deno.env.get(modern);
  if (!raw) return undefined;
  try { const o = JSON.parse(raw); return o.default ?? Object.values(o)[0] as string; } catch { return raw; }
}
const SERVICE = pickKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const fail = (msg: string, status = 400) => json({ error: msg }, status);

const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

function randomSecret(n = 32) {
  const b = new Uint8Array(n); crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/[^a-zA-Z0-9]/g, "").slice(0, n) + "Aa1!";
}
const staffEmail = () => `${crypto.randomUUID()}@staff.gescobar.app`;
const pinOk = (p: unknown) => typeof p === "string" && /^[0-9]{4,6}$/.test(p);

// Ouvre une session pour un utilisateur sans mot de passe connu (lien magique généré côté serveur, jamais envoyé)
async function sessionFor(userId: string, publicKey: string) {
  const { data: u, error: e1 } = await admin.auth.admin.getUserById(userId);
  if (e1 || !u?.user?.email) throw new Error("Compte introuvable.");
  const { data: link, error: e2 } = await admin.auth.admin.generateLink({ type: "magiclink", email: u.user.email });
  if (e2 || !link?.properties?.hashed_token) throw new Error("Connexion impossible pour le moment.");
  const pub = createClient(URL, publicKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let r = await pub.auth.verifyOtp({ type: "magiclink", token_hash: link.properties.hashed_token });
  if (r.error) r = await pub.auth.verifyOtp({ type: "email", token_hash: link.properties.hashed_token });
  if (r.error || !r.data.session) throw new Error("Connexion impossible pour le moment.");
  return { access_token: r.data.session.access_token, refresh_token: r.data.session.refresh_token };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("Méthode non autorisée.", 405);
  const publicKey = req.headers.get("apikey") ?? pickKey("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS") ?? "";
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail("Requête invalide."); }

  try {
    switch (body.action) {
      case "register": {
        const { bar_name, city, owner_name, email, password, pin } = body as Record<string, string>;
        if (!bar_name?.trim() || !owner_name?.trim()) return fail("Indiquez le nom du bar et votre nom.");
        if (!email || !/^\S+@\S+\.\S+$/.test(email)) return fail("Adresse e-mail invalide.");
        if (!password || password.length < 8) return fail("Le mot de passe doit faire au moins 8 caractères.");
        if (!pinOk(pin)) return fail("Le PIN doit contenir 4 à 6 chiffres.");
        const { data: u, error } = await admin.auth.admin.createUser({
          email: email.trim().toLowerCase(), password, email_confirm: true,
          user_metadata: { name: owner_name.trim() },
        });
        if (error || !u.user) {
          const m = (error?.message ?? "").toLowerCase();
          return fail(m.includes("already") ? "Un compte existe déjà avec cet e-mail." : "Inscription impossible : " + (error?.message ?? ""));
        }
        const { data, error: e2 } = await admin.rpc("gb_admin_create_bar", {
          p_user: u.user.id, p_bar_name: bar_name, p_city: city ?? "", p_owner_name: owner_name, p_pin: pin,
        });
        if (e2) { await admin.auth.admin.deleteUser(u.user.id); return fail(e2.message); }
        return json({ ok: true, code: data.code });
      }

      case "staff_list": {
        const code = String(body.code ?? "").trim().toUpperCase();
        if (!/^[A-Z0-9]{4,10}$/.test(code)) return fail("Code du bar invalide.");
        const { data, error } = await admin.rpc("gb_admin_staff_list", { p_code: code });
        if (error) return fail(error.message);
        if (!data) return fail("Aucun bar ne correspond à ce code.", 404);
        return json(data);
      }

      case "pin_login": {
        const code = String(body.code ?? "").trim().toUpperCase();
        const staffId = String(body.staff_id ?? "");
        const pin = String(body.pin ?? "");
        const { data, error } = await admin.rpc("gb_admin_check_pin", { p_code: code, p_staff: staffId, p_pin: pin });
        if (error) return fail(error.message);
        if (!data?.ok) return fail(data?.error ?? "PIN incorrect.", 401);
        return json(await sessionFor(data.user_id, publicKey));
      }

      case "staff_create": {
        const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
        const { data: me, error: e0 } = await admin.auth.getUser(jwt);
        if (e0 || !me?.user) return fail("Session expirée. Reconnectez-vous.", 401);
        const { data: caller } = await admin.rpc("gb_admin_caller", { p_user: me.user.id });
        if (!caller || caller.role !== "caisse") return fail("Action réservée à la caisse.", 403);
        const { name, role, pin } = body as Record<string, string>;
        if (!name?.trim()) return fail("Indiquez un nom.");
        if (!["caisse", "serveuse"].includes(role)) return fail("Rôle inconnu.");
        if (!pinOk(pin)) return fail("Le PIN doit contenir 4 à 6 chiffres.");
        const { data: u, error } = await admin.auth.admin.createUser({
          email: staffEmail(), password: randomSecret(), email_confirm: true,
          user_metadata: { name: name.trim(), staff: true },
        });
        if (error || !u.user) return fail("Création impossible : " + (error?.message ?? ""));
        const { data: sid, error: e2 } = await admin.rpc("gb_admin_add_staff", {
          p_caller: me.user.id, p_user: u.user.id, p_name: name, p_role: role, p_pin: pin,
        });
        if (e2) { await admin.auth.admin.deleteUser(u.user.id); return fail(e2.message); }
        return json({ ok: true, staff_id: sid });
      }

      default:
        return fail("Action inconnue.");
    }
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e), 500);
  }
});
