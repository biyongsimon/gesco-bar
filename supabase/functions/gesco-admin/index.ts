// GesCo Bar · fonction serveur : inscription, connexion par PIN, ajout du personnel, paiement Mobile Money par numéro (Notch Pay), abonnements payés en direct, installation du compte éditeur, assistant IA.
// verify_jwt = false : les actions publiques (inscription, liste, PIN) n'ont pas de session ;
// les autres actions vérifient elles-mêmes le jeton de l'appelant.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { KB } from "./kb.ts";

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
  // Les claviers de téléphone ajoutent souvent un espace après l'adresse (saisie automatique) : on le retire.
  if (typeof body.email === "string") body.email = body.email.replace(/\s+/g, "").toLowerCase();

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
        if (!caller || !["pdg", "directeur"].includes(caller.role)) return fail("Seuls le directeur et le PDG ajoutent des membres.", 403);
        const { name, role, pin } = body as Record<string, string>;
        if (!name?.trim()) return fail("Indiquez un nom.");
        if (!["directeur", "caisse", "serveuse"].includes(role)) return fail("Rôle inconnu.");
        if (role === "directeur" && caller.role !== "pdg") return fail("Seul le PDG peut ajouter un directeur.", 403);
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

      case "momo_push": case "momo_status": case "momo_link": {
        const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
        const { data: me, error: e0 } = await admin.auth.getUser(jwt);
        if (e0 || !me?.user) return fail("Session expirée. Reconnectez-vous.", 401);
        const NP = "https://api.notchpay.co/payments";
        const np = async (method: string, path: string, key: string, payload?: unknown) => {
          const r = await fetch(NP + path, { method, headers: { Authorization: key, Accept: "application/json", "Content-Type": "application/json" }, body: payload ? JSON.stringify(payload) : undefined });
          const j = await r.json().catch(() => ({})); return { ok: r.ok, j };
        };
        if (body.action === "momo_link") {
          // QR automatique : lien de paiement Notch Pay du bar ; le client scanne, paie, et le ticket passe payé tout seul.
          const { data: st, error: e1 } = await admin.rpc("gb_admin_momo_link_start", { p_user: me.user.id, p_ticket: String(body.ticket ?? "") });
          if (e1) return fail(e1.message);
          if (st.reuse) return json({ id: st.id, url: st.url });
          const init = await np("POST", "", st.key, { amount: st.amount, currency: "XAF", reference: "gbqr-" + st.id, description: st.label, customer: { name: st.client || "Client" } });
          const ref = init.j?.transaction?.reference, url = init.j?.authorization_url ?? init.j?.transaction?.authorization_url;
          if (!init.ok || !ref || !url) { await admin.rpc("gb_admin_momo_update", { p_req: st.id, p_status: "echoue", p_ref: ref ?? null, p_msg: init.j?.message ?? "lien" }); console.error("notchpay_link", JSON.stringify(init.j)); return fail("Lien de paiement indisponible : " + (init.j?.message ?? "vérifiez la clé Notch Pay du bar.")); }
          await admin.rpc("gb_admin_momo_link_set", { p_req: st.id, p_ref: ref, p_url: url });
          return json({ id: st.id, url });
        }
        if (body.action === "momo_push") {
          const { ticket, phone, operator } = body as Record<string, string>;
          const { data: st, error: e1 } = await admin.rpc("gb_admin_momo_start", { p_user: me.user.id, p_ticket: ticket, p_phone: phone, p_operator: operator });
          if (e1) return fail(e1.message);
          const init = await np("POST", "", st.key, { amount: st.amount, currency: "XAF", reference: "gb-" + st.id, description: st.label, customer: { phone: st.phone, name: st.client } });
          const ref = init.j?.transaction?.reference;
          if (!init.ok || !ref) { await admin.rpc("gb_admin_momo_update", { p_req: st.id, p_status: "echoue", p_ref: null, p_msg: init.j?.message ?? "init" }); return fail("Le service de paiement a refusé la demande : " + (init.j?.message ?? "vérifiez la clé du PDG.")); }
          const ch = await np("PUT", "/" + encodeURIComponent(ref), st.key, { channel: operator === "orange" ? "cm.orange" : "cm.mtn", data: { phone: st.phone } });
          if (!ch.ok) { await admin.rpc("gb_admin_momo_update", { p_req: st.id, p_status: "echoue", p_ref: ref, p_msg: ch.j?.message ?? "charge" }); return fail("Envoi au téléphone impossible : " + (ch.j?.message ?? "réessayez.")); }
          await admin.from("momo_requests").update({ provider_ref: ref }).eq("id", st.id);
          return json({ ok: true, id: st.id, message: ch.j?.message ?? "Demande envoyée au téléphone du client." });
        }
        const { id } = body as Record<string, string>;
        const { data: g, error: e2 } = await admin.rpc("gb_admin_momo_get", { p_user: me.user.id, p_req: id });
        if (e2) return fail(e2.message);
        if (g.status !== "en_cours") return json({ status: g.status });
        if (!g.ref || !g.key) return json({ status: "en_cours" });
        const v = await np("GET", "/" + encodeURIComponent(g.ref), g.key);
        const s = String(v.j?.transaction?.status ?? "pending");
        const old = Date.now() - new Date(g.created).getTime() > (g.kind === "lien" ? 15 : 5) * 60000;
        const paid = Number(v.j?.transaction?.amount ?? 0), short = s === "complete" && paid > 0 && g.amount && paid < Number(g.amount);
        const done = s === "complete" && !short ? "reussi" : short || ["failed", "rejected", "canceled", "cancelled", "abandoned", "expired"].includes(s) || old ? "echoue" : null;
        if (done) await admin.rpc("gb_admin_momo_update", { p_req: id, p_status: done, p_ref: g.ref, p_msg: s });
        return json({ status: done ?? "en_cours", provider: s });
      }

      case "sub_push": case "sub_status": {
        // Abonnement payé directement par Mobile Money sur le compte Notch Pay de l'éditeur (secret NOTCHPAY_SUB_KEY = clé publique Notch Pay).
        const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
        const { data: me, error: e0 } = await admin.auth.getUser(jwt);
        if (e0 || !me?.user) return fail("Session expirée. Reconnectez-vous.", 401);
        const KEY = Deno.env.get("NOTCHPAY_SUB_KEY");
        if (!KEY) return fail("Le paiement direct n'est pas encore activé : utilisez le paiement par transfert.", 503);
        const NP = "https://api.notchpay.co/payments";
        const np = async (method: string, path: string, payload?: unknown) => {
          const r = await fetch(NP + path, { method, headers: { Authorization: KEY, Accept: "application/json", "Content-Type": "application/json" }, body: payload ? JSON.stringify(payload) : undefined });
          const j = await r.json().catch(() => ({})); return { ok: r.ok, j };
        };
        if (body.action === "sub_push") {
          const { plan, operator, phone } = body as Record<string, string>;
          // Clé Notch Pay de test (compte pas encore validé) : seuls les numéros fictifs du bac à sable passent.
          const p9 = String(phone ?? "").replace(/\D/g, "").replace(/^237/, "");
          if (/test/i.test(KEY) && !/^6[79]000000\d$/.test(p9)) return fail("Le paiement sur téléphone est en cours d'activation (validation du compte de paiement GesCo en cours). En attendant, choisissez « Par transfert » : votre formule s'active tout de suite.", 503);
          const { data: st, error: e1 } = await admin.rpc("gb_admin_sub_push_start", { p_user: me.user.id, p_plan: plan, p_months: Number(body.months), p_method: operator, p_phone: phone });
          if (e1) return fail(e1.message);
          const init = await np("POST", "", { amount: st.amount, currency: "XAF", reference: "gbsub-" + st.id, description: st.label, customer: { phone: st.phone, name: st.bar } });
          const ref = init.j?.transaction?.reference;
          if (!init.ok || !ref) { await admin.rpc("gb_admin_sub_push_done", { p_id: st.id, p_ok: false, p_ref: null, p_msg: "init: " + (init.j?.message ?? "") }); console.error("notchpay_sub_init", JSON.stringify(init.j)); return fail("Le service de paiement est indisponible pour le moment. Réessayez ou payez par transfert."); }
          await admin.rpc("gb_admin_sub_push_ref", { p_id: st.id, p_ref: ref });
          const ch = await np("PUT", "/" + encodeURIComponent(ref), { channel: operator === "orange" ? "cm.orange" : "cm.mtn", data: { phone: st.phone } });
          if (!ch.ok) { await admin.rpc("gb_admin_sub_push_done", { p_id: st.id, p_ok: false, p_ref: ref, p_msg: "charge: " + (ch.j?.message ?? "") }); console.error("notchpay_sub_charge", JSON.stringify(ch.j)); const m = String(ch.j?.message ?? "");
            return fail("Envoi de la demande impossible : " + (/test phone/i.test(m) ? "le paiement sur téléphone est encore en mode test. Choisissez « Par transfert » en attendant."
              : /phone|number|numéro/i.test(m) ? "ce numéro n'est pas accepté par l'opérateur choisi. Vérifiez le numéro et l'opérateur (Orange ou MTN)."
              : /insufficient|solde/i.test(m) ? "solde insuffisant sur ce compte Mobile Money." : "réessayez dans un instant ou payez par transfert.")); }
          return json({ ok: true, id: st.id, amount: st.amount, message: ch.j?.message ?? "Demande envoyée sur le téléphone." });
        }
        const { data: g, error: e2 } = await admin.rpc("gb_admin_sub_get", { p_user: me.user.id, p_id: String(body.id ?? "") });
        if (e2) return fail(e2.message);
        if (g.status !== "en_attente" || g.channel !== "notchpay") return json({ status: g.status });
        const old = Date.now() - new Date(g.created).getTime() > 15 * 60000;
        if (!g.ref) { if (old) await admin.rpc("gb_admin_sub_push_done", { p_id: g.id, p_ok: false, p_ref: null, p_msg: "Délai dépassé" }); return json({ status: old ? "echouee" : "en_attente" }); }
        const v = await np("GET", "/" + encodeURIComponent(g.ref));
        const s = String(v.j?.transaction?.status ?? "pending");
        const paid = Number(v.j?.transaction?.amount ?? 0), short = s === "complete" && paid > 0 && paid < Number(g.amount);
        if (short) console.error("notchpay_sub_amount", g.id, paid, g.amount);
        const done = s === "complete" && !short ? true : short || ["failed", "rejected", "canceled", "cancelled", "abandoned", "expired"].includes(s) || old ? false : null;
        if (done === null) return json({ status: "en_attente", provider: s });
        const { data: res } = await admin.rpc("gb_admin_sub_push_done", { p_id: g.id, p_ok: done, p_ref: g.ref, p_msg: done ? null : short ? `Montant reçu ${paid} au lieu de ${g.amount} : à vérifier` : "Notch Pay : " + s });
        return json({ status: res ?? (done ? "validee" : "echouee"), provider: s });
      }

      case "admin_setup_open": {
        const { data } = await admin.rpc("gb_admin_setup_open");
        return json({ open: !!data });
      }

      case "admin_setup": {
        const { email, password, code } = body as Record<string, string>;
        if (!email || !/^\S+@\S+\.\S+$/.test(email)) return fail("Adresse e-mail invalide.");
        if (!password || password.length < 10) return fail("Le mot de passe doit faire au moins 10 caractères.");
        if (!code || code.trim().length < 6) return fail("Indiquez le code d'installation.");
        const { data: open } = await admin.rpc("gb_admin_setup_open");
        if (!open) return fail("Le compte éditeur a déjà été créé.", 403);
        const { data: u, error } = await admin.auth.admin.createUser({ email: email.trim().toLowerCase(), password, email_confirm: true, user_metadata: { name: "BISMO Agency", editeur: true } });
        if (error || !u.user) return fail((error?.message ?? "").toLowerCase().includes("already") ? "Un compte existe déjà avec cet e-mail." : "Création impossible : " + (error?.message ?? ""));
        const { error: e2 } = await admin.rpc("gb_admin_claim_setup", { p_code: code, p_user: u.user.id, p_email: email });
        if (e2) { await admin.auth.admin.deleteUser(u.user.id); return fail(e2.message, 403); }
        return json({ ok: true });
      }

      case "assist": case "assist_history": {
        // Assistant IA : réponse par Claude (clé ANTHROPIC_API_KEY enregistrée dans les secrets Supabase), passage de relais à BISMO Agency.
        const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
        let ctx: Record<string, unknown> | null = null, uid: string | null = null;
        if (jwt && jwt !== publicKey) { const { data: me } = await admin.auth.getUser(jwt); if (me?.user) { uid = me.user.id; const { data } = await admin.rpc("gb_admin_assist_context", { p_user: uid }); ctx = data; } }
        const anonToken = String(body.token ?? ""), hash = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("gesco-assist|" + t)))).map(x => x.toString(16).padStart(2, "0")).join("");
        let threadId = String(body.thread ?? "") || null, thread: Record<string, unknown> | null = null;
        if (threadId) {
          const { data: t } = await admin.from("support_threads").select("*").eq("id", threadId).maybeSingle();
          const mine = t && ((ctx && t.staff_id === ctx.staff_id) || (!t.staff_id && anonToken.length >= 16 && t.anon_hash === await hash(anonToken)));
          thread = mine ? t : null; if (!mine) threadId = null;
        }
        const history = async () => threadId ? ((await admin.from("support_messages").select("sender,body,created_at").eq("thread_id", threadId).order("id")).data ?? []) : [];
        if (body.action === "assist_history") return json({ thread: threadId, status: thread?.status ?? null, messages: await history() });
        const msg = String(body.message ?? "").trim().slice(0, 1500);
        if (!msg) return fail("Écrivez votre question.");
        const KEY = Deno.env.get("ANTHROPIC_API_KEY");
        if (!KEY) return fail("L'assistant n'est pas encore activé. Contactez BISMO Agency.", 503);
        const okQuota = (await admin.rpc("gb_admin_assist_quota", { p_key: ctx ? "s:" + ctx.staff_id : "ip:" + (req.headers.get("x-forwarded-for") ?? "?").split(",")[0], p_max: ctx ? 80 : 25 })).data;
        if (!okQuota) return fail("Limite de messages atteinte pour aujourd'hui. Réessayez demain ou contactez BISMO Agency.", 429);
        if (!threadId) {
          if (!ctx && anonToken.length < 16) return fail("Session d'assistance invalide.");
          const { data: t, error } = await admin.from("support_threads").insert({ bar_id: ctx?.bar_id ?? null, staff_id: ctx?.staff_id ?? null, anon_hash: ctx ? null : await hash(anonToken) }).select("*").single();
          if (error) return fail("Assistance indisponible : " + error.message, 500); thread = t; threadId = t.id;
        }
        await admin.from("support_messages").insert({ thread_id: threadId, sender: "client", body: msg });
        await admin.from("support_threads").update({ last_msg_at: new Date().toISOString() }).eq("id", threadId);
        if (thread?.status === "transmis") return json({ thread: threadId, status: "transmis", reply: null, messages: await history() });
        const past = (await history()).slice(-16);
        const messages: { role: string; content: any }[] = [];
        for (const m of past) { const role = m.sender === "client" ? "user" : "assistant"; const text = m.sender === "bismo" ? "[Réponse de BISMO Agency] " + m.body : m.body;
          if (messages.length && messages[messages.length - 1].role === role) messages[messages.length - 1].content += "\n\n" + text; else messages.push({ role, content: text }); }
        if (messages[0]?.role !== "user") messages.shift();
        const sys = [{ type: "text", text: `Tu es l'assistant d'aide de GesCo Bar, application de gestion de bars au Cameroun éditée par BISMO Agency.
Règles :
- Réponds en français simple et chaleureux (ou en anglais si la personne écrit en anglais), en phrases courtes et étapes numérotées si utile. Pas de jargon technique. 120 mots maximum sauf si une procédure l'exige.
- Appuie-toi uniquement sur le guide ci-dessous et sur la situation du bar. N'invente jamais une fonction, un prix, un délai ou une procédure. Si tu ne sais pas, dis-le et propose de transmettre à BISMO Agency.
- Tu ne fais aucune action dans l'application : tu expliques comment faire. Tu ne valides aucun paiement, ne changes aucun PIN, ne supprimes rien, ne promets aucun remboursement ni geste commercial.
- Ne demande jamais un PIN, un mot de passe, un code secret Mobile Money ou une clé. Si quelqu'un en donne un, dis-lui de le changer.
- Ne donne aucune information sur un autre bar.
- Utilise l'outil transmettre_a_bismo quand : la personne demande un humain ; un paiement d'abonnement est contesté ou en retard de validation de plus de 72 h ; un bug ou une perte de données est probable ; un mot de passe PDG est perdu ; un bar est suspendu ; ou tu n'arrives pas à résoudre après deux essais. Après transmission, dis que BISMO Agency répond dans cette même discussion, en général sous 24 h.
- Tu ne donnes pas de conseil juridique, fiscal ou financier personnalisé.` }, { type: "text", text: KB, cache_control: { type: "ephemeral" } },
          { type: "text", text: "Situation actuelle de la personne (données de l'application) :\n" + (ctx ? JSON.stringify(ctx) : "Personne non connectée (écran de connexion) : on ne connaît pas son bar. Pour un problème de compte, demander le nom du bar et un numéro WhatsApp, puis transmettre.") }];
        const tools = [{ name: "transmettre_a_bismo", description: "Transmet la demande à l'équipe humaine de BISMO Agency avec un résumé.",
          input_schema: { type: "object", properties: { resume: { type: "string", description: "Résumé clair du problème et de ce qui a été essayé" }, urgence: { type: "string", enum: ["normale", "urgente"] }, contact: { type: "string", description: "Numéro WhatsApp ou nom du bar si la personne l'a donné" } }, required: ["resume", "urgence"] } }];
        const call = (msgs: unknown[]) => fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
          body: JSON.stringify({ model: Deno.env.get("ASSIST_MODEL") ?? "claude-haiku-5-5", max_tokens: 700, system: sys, tools, messages: msgs }) }).then(r => r.json());
        let r = await call(messages);
        if (r?.error) { console.error("anthropic_error", JSON.stringify(r.error)); return fail("L'assistant est momentanément indisponible. Réessayez dans un instant.", 502); }
        let status = "ia";
        const tu = (r.content ?? []).find((c: { type: string }) => c.type === "tool_use");
        if (tu) {
          const inp = tu.input ?? {};
          await admin.from("support_threads").update({ status: "transmis", summary: String(inp.resume ?? "").slice(0, 1000), urgence: inp.urgence ?? "normale", contact: inp.contact ?? null, admin_seen_at: null }).eq("id", threadId);
          status = "transmis";
          r = await call([...messages, { role: "assistant", content: r.content }, { role: "user", content: [{ type: "tool_result", tool_use_id: tu.id, content: "Demande transmise à BISMO Agency." }] }]);
        }
        let reply = (r.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("\n").trim();
        if (!reply) reply = status === "transmis" ? "Votre demande est transmise à BISMO Agency. Vous recevrez la réponse ici même, en général sous 24 h." : "Je n'ai pas compris, pouvez-vous reformuler ?";
        await admin.from("support_messages").insert({ thread_id: threadId, sender: "ia", body: reply.slice(0, 4000) });
        return json({ thread: threadId, status, reply, messages: await history() });
      }

      default:
        return fail("Action inconnue.");
    }
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e), 500);
  }
});
