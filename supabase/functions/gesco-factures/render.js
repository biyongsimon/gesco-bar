// GesCo Bar · mise en page du reçu / de la facture d'abonnement (A4), avec pdf-lib.
// Utilisé par la fonction serveur gesco-factures ; testable hors serveur (node) en passant le module pdf-lib.

const GREEN = [15 / 255, 92 / 255, 60 / 255], INK = [19 / 255, 32 / 255, 26 / 255], MUTED = [91 / 255, 106 / 255, 98 / 255], LINE = [219 / 255, 227 / 255, 221 / 255], SOFT = [240 / 255, 245 / 255, 241 / 255];

// Les polices standard du PDF ne connaissent que le jeu WinAnsi : on remplace le reste
const WIN = "€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ";
export function clean(s) {
  return String(s ?? "").normalize("NFC").replace(/[\u00a0\u202f\u2009\u2007]/g, " ").replace(/[\u2010\u2011\u2012]/g, "-")
    .replace(/[^\x20-\x7e\u00a0-\u00ff]/g, c => WIN.includes(c) ? c : "");
}
export const fcfa = n => String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " FCFA";
const d2 = n => String(n).padStart(2, "0");
export function dfr(v) { if (!v) return ""; const s = String(v); if (/^\d{4}-\d{2}-\d{2}$/.test(s)) { const [y, m, d] = s.split("-"); return `${d}/${m}/${y}`; }
  const t = new Date(new Date(s).getTime() + 3600e3); return `${d2(t.getUTCDate())}/${d2(t.getUTCMonth() + 1)}/${t.getUTCFullYear()}`; } // heure de Douala (UTC+1)

// Montant en lettres (usage camerounais : « Arrêté le présent … à la somme de … »)
const U = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize", "quatorze", "quinze", "seize", "dix-sept", "dix-huit", "dix-neuf"];
const T = ["", "", "vingt", "trente", "quarante", "cinquante", "soixante"];
function sub100(n) {
  if (n < 20) return U[n];
  if (n < 70) { const t = Math.floor(n / 10), u = n % 10; return T[t] + (u === 0 ? "" : u === 1 ? " et un" : "-" + U[u]); }
  if (n < 80) return n === 71 ? "soixante et onze" : "soixante-" + U[n - 60];
  if (n === 80) return "quatre-vingts";
  return "quatre-vingt-" + U[n - 80];
}
function sub1000(n) {
  const c = Math.floor(n / 100), r = n % 100;
  const head = c === 0 ? "" : c === 1 ? "cent" : U[c] + " cent" + (r === 0 ? "s" : "");
  return [head, r ? sub100(r) : ""].filter(Boolean).join(" ");
}
export function enLettres(n) {
  n = Math.round(Number(n) || 0); if (n === 0) return "zéro";
  const parts = [], mil = Math.floor(n / 1e9), mio = Math.floor(n / 1e6) % 1000, k = Math.floor(n / 1000) % 1000, r = n % 1000;
  if (mil) parts.push(sub1000(mil).replace(/cents$/, "cent") + (mil > 1 ? " milliards" : " milliard"));
  if (mio) parts.push(sub1000(mio).replace(/cents$/, "cent") + (mio > 1 ? " millions" : " million"));
  if (k) parts.push(k === 1 ? "mille" : sub1000(k).replace(/cents$/, "cent") + " mille");
  if (r) parts.push(sub1000(r));
  return parts.join(" ");
}

const OPS = { orange: "Orange Money", mtn: "MTN Mobile Money" };
const ROLES = { pdg: "PDG", directeur: "directeur", caisse: "caisse", serveuse: "serveuse" };
const tel = s => { const d = String(s || "").replace(/\D/g, "").replace(/^237/, ""); return d.length === 9 ? `${d.slice(0, 3)} ${d.slice(3, 5)} ${d.slice(5, 7)} ${d.slice(7)}` : String(s || ""); };

// Lignes du document : prix mensuel × mois, remise de l'année (2 mois offerts) ; sinon une ligne au montant payé
export function lines(inv) {
  const per = inv.period_from && inv.period_to ? `du ${dfr(inv.period_from)} au ${dfr(inv.period_to)}` : "";
  const label = `Abonnement GesCo Bar · formule ${inv.plan_label}`;
  const full = inv.unit_price * inv.months, free = inv.months === 12 ? inv.unit_price * 2 : 0;
  if (!inv.is_test && inv.unit_price > 0 && full - free === inv.amount) {
    const L = [{ d: label, s: per, q: String(inv.months), u: fcfa(inv.unit_price), m: fcfa(full) }];
    if (free) L.push({ d: "Remise paiement annuel : 2 mois offerts", s: "", q: "", u: "", m: "- " + fcfa(free) });
    return L;
  }
  return [{ d: label + (inv.is_test ? " (paiement de test)" : ""), s: per, q: String(inv.months), u: "", m: fcfa(inv.amount) }];
}

export async function renderInvoice(PDFLib, inv, assets = {}) {
  const { PDFDocument, StandardFonts, rgb, degrees } = PDFLib, c = a => rgb(a[0], a[1], a[2]);
  const pdf = await PDFDocument.create();
  pdf.setTitle(clean(`${inv.title} ${inv.number}`)); pdf.setAuthor("BISMO AGENCY"); pdf.setCreator("GesCo Bar"); pdf.setProducer("GesCo Bar");
  const page = pdf.addPage([595.28, 841.89]), W = 595.28, M = 42;
  const R = await pdf.embedFont(StandardFonts.Helvetica), B = await pdf.embedFont(StandardFonts.HelveticaBold), I = await pdf.embedFont(StandardFonts.HelveticaOblique);
  const S = inv.seller || {}, C = inv.client || {}, P = inv.payer || {};
  const tw = (s, f, z) => f.widthOfTextAtSize(clean(s), z);
  const txt = (s, x, y, o = {}) => { const f = o.f || R, z = o.z || 9, t = clean(s); let xx = x; if (o.a === "r") xx = x - f.widthOfTextAtSize(t, z); else if (o.a === "c") xx = x - f.widthOfTextAtSize(t, z) / 2;
    page.drawText(t, { x: xx, y, size: z, font: f, color: c(o.c || INK) }); };
  const wrap = (s, f, z, w) => { const out = []; let cur = ""; for (const word of clean(s).split(/\s+/)) { const t = cur ? cur + " " + word : word; if (f.widthOfTextAtSize(t, z) > w && cur) { out.push(cur); cur = word; } else cur = t; } if (cur) out.push(cur); return out; };
  const rect = (x, y, w, h, fill, stroke) => page.drawRectangle({ x, y, width: w, height: h, color: fill ? c(fill) : undefined, borderColor: stroke ? c(stroke) : undefined, borderWidth: stroke ? 0.8 : 0 });
  const img = async bytes => { if (!bytes) return null; try { return await pdf.embedPng(bytes); } catch { try { return await pdf.embedJpg(bytes); } catch { return null; } } };

  // Bandeau et en-tête
  rect(0, 841.89 - 8, W, 8, GREEN);
  let top = 841.89 - 30;
  const logo = await img(assets.logo);
  if (logo) { const k = Math.min(150 / logo.width, 46 / logo.height), w = logo.width * k, h = logo.height * k; page.drawImage(logo, { x: M, y: top - h, width: w, height: h }); }
  else txt(S.enseigne || "BISMO AGENCY", M, top - 26, { f: B, z: 20, c: GREEN });
  const title = String(inv.title || "Facture").toUpperCase();
  txt(title, W - M, top - 16, { f: B, z: 20, c: GREEN, a: "r" });
  txt(`N° ${inv.number}`, W - M, top - 32, { f: B, z: 11, a: "r" });
  txt(`Date : ${dfr(inv.issued_at)}`, W - M, top - 46, { z: 9, c: MUTED, a: "r" });
  // Tampon « PAYÉ »
  const st = "PAYÉ", sw = tw(st, B, 13) + 22; rect(W - M - sw, top - 74, sw, 20, null, GREEN); txt(st, W - M - sw / 2, top - 68, { f: B, z: 13, c: GREEN, a: "c" });

  // Vendeur (gauche) et client (droite)
  let y = top - 100;
  const colW = (W - 2 * M - 16) / 2, xR = M + colW + 16;
  txt("ÉMIS PAR", M, y, { f: B, z: 8, c: MUTED }); txt(String(inv.title).toLowerCase().startsWith("reçu") ? "REÇU DE" : "FACTURÉ À", xR, y, { f: B, z: 8, c: MUTED });
  const sellerL = [[S.enseigne || "BISMO AGENCY", B, 11], [`${S.nom || ""}${S.statut ? ", " + S.statut.toLowerCase() : ""}`, R, 9], [S.niu ? `NIU : ${S.niu}` : "", R, 9], [S.rccm ? `RCCM : ${S.rccm}` : "", R, 9],
    [S.adresse || "", R, 9], [[S.telephone, S.telephone2].filter(Boolean).join(" · "), R, 9], [S.email || "", R, 9]].filter(l => l[0]);
  const clientL = [[C.raison_sociale || C.bar || "", B, 11], [C.raison_sociale && C.bar && C.raison_sociale !== C.bar ? `Établissement : ${C.bar}` : "", R, 9], [C.niu ? `NIU : ${C.niu}` : "", R, 9],
    [C.pdg ? `Responsable : ${C.pdg}` : "", R, 9], [[C.ville, C.code ? "code GesCo " + C.code : ""].filter(Boolean).join(" · "), R, 9], [C.telephone ? "Tél. " + tel(C.telephone) : "", R, 9], [C.email || "", R, 9]].filter(l => l[0]);
  const boxH = Math.max(sellerL.length, clientL.length) * 13 + 14;
  rect(xR - 8, y - 8 - boxH + 6, colW + 8, boxH, SOFT);
  sellerL.forEach((l, i) => txt(l[0], M, y - 16 - i * 13, { f: l[1], z: l[2] }));
  clientL.forEach((l, i) => wrap(l[0], l[1], l[2], colW - 8).slice(0, 1).forEach(t => txt(t, xR, y - 16 - i * 13, { f: l[1], z: l[2] })));
  y = y - 16 - boxH - 8;

  // Tableau
  const cols = [{ k: "d", w: 0.42, t: "Désignation" }, { k: "q", w: 0.1, t: "Mois", a: "r" }, { k: "u", w: 0.2, t: "Prix mensuel", a: "r" }, { k: "m", w: 0.28, t: "Montant", a: "r" }];
  const TW = W - 2 * M; let x = M;
  rect(M, y - 6, TW, 22, GREEN);
  cols.forEach(cl => { const cw = cl.w * TW; txt(cl.t, cl.a === "r" ? x + cw - 6 : x + 6, y + 2, { f: B, z: 9, c: [1, 1, 1], a: cl.a }); x += cw; });
  y -= 6;
  for (const L of lines(inv)) {
    const dl = wrap(L.d, B, 9.5, cols[0].w * TW - 12), h = 16 + dl.length * 12 + (L.s ? 12 : 0);
    page.drawLine({ start: { x: M, y: y - h }, end: { x: M + TW, y: y - h }, thickness: 0.6, color: c(LINE) });
    dl.forEach((t, i) => txt(t, M + 6, y - 16 - i * 12, { f: B, z: 9.5 }));
    if (L.s) txt(L.s, M + 6, y - 16 - dl.length * 12, { z: 8.5, c: MUTED });
    x = M; cols.forEach(cl => { const cw = cl.w * TW; if (cl.k !== "d") txt(L[cl.k], x + cw - 6, y - 16, { z: 9.5, a: "r", f: cl.k === "m" ? B : R }); x += cw; });
    y -= h;
  }
  // Total
  y -= 10; const tbw = 230; rect(W - M - tbw, y - 30, tbw, 30, SOFT);
  txt("TOTAL PAYÉ", W - M - tbw + 12, y - 19, { f: B, z: 10, c: MUTED }); txt(fcfa(inv.amount), W - M - 12, y - 20, { f: B, z: 15, c: GREEN, a: "r" });
  y -= 44; txt("Montant net, sans TVA.", W - M, y, { z: 8, c: MUTED, a: "r" });
  y -= 18;
  const words = `Arrêté le présent ${String(inv.title).toLowerCase().startsWith("reçu") ? "reçu" : "document"} à la somme de ${enLettres(inv.amount)} francs CFA (${fcfa(inv.amount)}).`;
  wrap(words, I, 9.5, TW).forEach(t => { txt(t, M, y, { f: I, z: 9.5 }); y -= 13; });

  // Paiement
  y -= 10; txt("PAIEMENT", M, y, { f: B, z: 8, c: MUTED }); y -= 15;
  const how = `${OPS[P.methode] || "Mobile Money"}${P.canal === "notchpay" ? " (demande validée sur le téléphone)" : " (transfert)"}`;
  const payL = [`Payé le ${dfr(P.paye_le || inv.issued_at)} par ${how}`, P.reference ? `Référence de la transaction : ${P.reference}` : "",
    P.nom ? `Paiement effectué par ${P.nom}${P.role ? " (" + (ROLES[P.role] || P.role) + ")" : ""}${P.telephone ? " depuis le " + tel(P.telephone) : ""}` : ""].filter(Boolean);
  payL.forEach(t => { wrap(t, R, 9.5, TW * 0.58).forEach(w => { txt(w, M, y, { z: 9.5 }); y -= 13; }); });

  // Signature (droite)
  const sy = y + payL.length * 13 + 15, sx = W - M - 180;
  txt(`Pour ${S.enseigne || "BISMO AGENCY"}`, sx + 90, sy, { f: B, z: 9, a: "c" });
  const sig = await img(assets.signature), stamp = await img(assets.cachet);
  if (stamp) { const h = 70, w = stamp.width * h / stamp.height; page.drawImage(stamp, { x: sx + 90 - w / 2 - 25, y: sy - 82, width: w, height: h, opacity: 0.85 }); }
  if (sig) { const h = 48, w = Math.min(160, sig.width * h / sig.height); page.drawImage(sig, { x: sx + 90 - w / 2, y: sy - 62, width: w, height: w * sig.height / sig.width }); }
  txt(S.nom || "", sx + 90, sy - 78, { z: 9, a: "c" });

  // Note de bas de document
  y = Math.min(y, sy - 92) - 14;
  wrap(`Ce document certifie le paiement de l'abonnement GesCo Bar pour la période indiquée. Il est conservé dans votre espace GesCo, rubrique Abonnement, Historique. Conditions : ${S.site || "gescobar-cm.pages.dev"}/conditions · Remboursement : ${S.site || "gescobar-cm.pages.dev"}/remboursement`, R, 8, TW)
    .forEach(t => { txt(t, M, y, { z: 8, c: MUTED }); y -= 11; });

  // Filigrane du paiement de test
  if (inv.is_test) page.drawText("DOCUMENT DE TEST · SANS VALEUR", { x: 72, y: 215, size: 30, font: B, color: rgb(0.85, 0.2, 0.2), opacity: 0.18, rotate: degrees(32) });

  // Pied de page
  page.drawLine({ start: { x: M, y: 62 }, end: { x: W - M, y: 62 }, thickness: 0.8, color: c(GREEN) });
  txt("Merci de votre confiance.", W / 2, 48, { f: B, z: 9, c: GREEN, a: "c" });
  txt([S.enseigne, S.nom ? S.nom + ", " + (S.statut || "").toLowerCase() : "", S.niu ? "NIU " + S.niu : "", S.rccm ? "RCCM " + S.rccm.toLowerCase() : ""].filter(Boolean).join(" · "), W / 2, 36, { z: 7.5, c: MUTED, a: "c" });
  txt([S.adresse, S.telephone, S.email, S.site].filter(Boolean).join(" · "), W / 2, 26, { z: 7.5, c: MUTED, a: "c" });
  rect(0, 0, W, 6, GREEN);
  return await pdf.save();
}
