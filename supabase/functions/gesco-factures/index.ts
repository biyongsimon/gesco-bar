// GesCo Bar · reçu / facture d'abonnement : fabrique le PDF, le range dans le stockage privé « factures » et l'envoie par e-mail.
// Appelée par la base (en-tête x-hook) juste après un paiement validé, et toutes les 10 minutes pour les reprises.
// Envoi des e-mails : service Resend (secret RESEND_API_KEY, saisi par l'éditeur dans Supabase ; adresse d'envoi : secret INVOICE_FROM).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import * as PDFLib from "npm:pdf-lib@1.17.1";
import { renderInvoice, fcfa, dfr, clean } from "./render.js";

const URL = Deno.env.get("SUPABASE_URL")!;
const raw = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEYS") ?? "";
let SERVICE = raw; try { const o = JSON.parse(raw); SERVICE = o.default ?? Object.values(o)[0]; } catch { /* clé simple */ }
const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const SITE = "https://gescobar-cm.pages.dev";
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

// Logo servi par le site ; signature et cachet gardés dans le stockage privé (dossier _bismo), jamais publiés. Une image absente est omise.
const cache: Record<string, Uint8Array | null> = {};
async function asset(path: string) {
  if (path in cache) return cache[path];
  try { const r = await fetch(SITE + path); cache[path] = r.ok ? new Uint8Array(await r.arrayBuffer()) : null; } catch { cache[path] = null; }
  return cache[path];
}
async function privateAsset(name: string) {
  const dl = await admin.storage.from("factures").download(`_bismo/${name}.png`);
  return dl.error || !dl.data ? null : new Uint8Array(await dl.data.arrayBuffer());
}
const b64 = (u: Uint8Array) => { let s = ""; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const { data: cfg } = await admin.rpc("gb_admin_push_config");
  if (!cfg?.hook || req.headers.get("x-hook") !== cfg.hook) return json({ error: "Non autorisé." }, 401);
  let body: Record<string, unknown>; try { body = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }
  const id = String(body.id ?? "");
  if (body.action === "asset") { // dépôt de la signature ou du cachet de l'éditeur (PNG, 300 Ko maximum)
    const name = String(body.name ?? ""), data = Uint8Array.from(atob(String(body.b64 ?? "")), ch => ch.charCodeAt(0));
    if (!["signature", "cachet"].includes(name) || data.length < 100 || data.length > 300000 || data[1] !== 0x50 || data[2] !== 0x4e) return json({ error: "Image invalide." }, 400);
    const up = await admin.storage.from("factures").upload(`_bismo/${name}.png`, data, { contentType: "image/png", upsert: true });
    return up.error ? json({ error: up.error.message }, 500) : json({ ok: true, name, size: data.length });
  }
  if (body.action === "purge") { // documents de test seulement : PDF et ligne supprimés
    const { data: t } = await admin.from("invoices").select("id,pdf_path,is_test").eq("id", id).maybeSingle();
    if (!t?.is_test) return json({ error: "Seuls les documents de test se suppriment." }, 400);
    if (t.pdf_path) { const rm = await admin.storage.from("factures").remove([t.pdf_path]); if (rm.error) return json({ error: rm.error.message }, 500); }
    await admin.from("invoices").delete().eq("id", id);
    return json({ ok: true, purged: id });
  }
  const { data: inv, error } = await admin.rpc("gb_admin_invoice_claim", { p_id: id });
  if (error) return json({ error: error.message }, 500);
  if (!inv) return json({ ok: true, skipped: true });
  let pdfPath: string | null = inv.pdf_path;
  try {
    // 1. Le PDF (fabriqué une seule fois : le document envoyé et le document conservé sont identiques)
    let bytes: Uint8Array;
    if (!pdfPath) {
      bytes = await renderInvoice(PDFLib, inv, { logo: await asset("/bismo-logo.png"), signature: await privateAsset("signature"), cachet: await privateAsset("cachet") });
      const path = `${inv.bar_id}/${inv.number}.pdf`;
      const up = await admin.storage.from("factures").upload(path, bytes, { contentType: "application/pdf", upsert: true });
      if (up.error) throw new Error("stockage : " + up.error.message);
      pdfPath = path;
    } else {
      const dl = await admin.storage.from("factures").download(pdfPath);
      if (dl.error || !dl.data) throw new Error("lecture du PDF : " + (dl.error?.message ?? ""));
      bytes = new Uint8Array(await dl.data.arrayBuffer());
    }
    // 2. L'e-mail
    const to: string[] = inv.email_to ?? [];
    if (!to.length) { await admin.rpc("gb_admin_invoice_done", { p_id: id, p_pdf: pdfPath, p_status: "sans_adresse", p_error: null }); return json({ ok: true, status: "sans_adresse" }); }
    const KEY = Deno.env.get("RESEND_API_KEY");
    if (!KEY) { await admin.rpc("gb_admin_invoice_done", { p_id: id, p_pdf: pdfPath, p_status: "sans_cle", p_error: "Clé d'envoi des e-mails non configurée" }); return json({ ok: true, status: "sans_cle" }); }
    const S = inv.seller ?? {}, C = inv.client ?? {}, P = inv.payer ?? {}, kind = String(inv.title || "Facture");
    const roleTxt = P.nom ? (P.role === "pdg" ? "vous-même" : `${esc(P.nom)} (${P.role === "directeur" ? "directeur" : esc(P.role)})`) : "";
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#13201a;max-width:560px;margin:auto">
      <div style="height:6px;background:#0f5c3c"></div>
      <p style="font-size:16px">Bonjour ${esc(C.pdg || "")},</p>
      <p>Merci pour votre paiement. Votre abonnement GesCo Bar <b>${esc(inv.plan_label)}</b> pour <b>${esc(C.bar || "")}</b> est actif${inv.period_to ? ` jusqu'au <b>${dfr(inv.period_to)}</b>` : ""}.</p>
      <table style="border-collapse:collapse;width:100%;margin:12px 0;font-size:14px">
        <tr><td style="padding:6px 0;color:#5b6a62">${esc(kind)}</td><td style="text-align:right"><b>${esc(inv.number)}</b></td></tr>
        <tr><td style="padding:6px 0;color:#5b6a62">Période</td><td style="text-align:right">${inv.period_from ? `du ${dfr(inv.period_from)} au ${dfr(inv.period_to)}` : `${inv.months} mois`}</td></tr>
        <tr><td style="padding:6px 0;color:#5b6a62">Montant payé</td><td style="text-align:right"><b>${esc(fcfa(inv.amount))}</b></td></tr>
        ${roleTxt ? `<tr><td style="padding:6px 0;color:#5b6a62">Payé par</td><td style="text-align:right">${roleTxt}</td></tr>` : ""}
      </table>
      <p>Vous trouverez le document en pièce jointe. Il reste aussi disponible dans GesCo, rubrique <b>Abonnement → Historique</b>.</p>
      ${inv.is_test ? `<p style="color:#b42318"><b>Paiement de test : ce document n'a pas de valeur comptable.</b></p>` : ""}
      <p>Merci de votre confiance,<br>${esc(S.enseigne || "BISMO AGENCY")}</p>
      <p style="font-size:12px;color:#5b6a62;border-top:1px solid #dde3df;padding-top:10px">${esc([S.enseigne, S.nom, S.niu ? "NIU " + S.niu : "", S.adresse].filter(Boolean).join(" · "))}<br>${esc([S.telephone, S.email].filter(Boolean).join(" · "))} · <a href="${SITE}" style="color:#0f5c3c">${esc(S.site || "gescobar-cm.pages.dev")}</a></p></div>`;
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ from: Deno.env.get("INVOICE_FROM") ?? "GesCo Bar <factures@biyongsimon.com>", to, reply_to: S.email || undefined,
        subject: clean(`${kind} ${inv.number} · abonnement GesCo Bar ${inv.plan_label}`), html,
        attachments: [{ filename: `${inv.number}.pdf`, content: b64(bytes) }] }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`e-mail refusé (${r.status}) : ${j?.message ?? ""}`);
    await admin.rpc("gb_admin_invoice_done", { p_id: id, p_pdf: pdfPath, p_status: "envoye", p_error: null });
    return json({ ok: true, status: "envoye" });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("facture_erreur", id, msg);
    await admin.rpc("gb_admin_invoice_done", { p_id: id, p_pdf: pdfPath, p_status: "echec", p_error: msg });
    return json({ ok: false, error: msg }, 500);
  }
});
