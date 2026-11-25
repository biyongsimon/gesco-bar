// Surveillance du site en ligne : l'application s'affiche-t-elle vraiment chez les bars ?
// - attend que la version envoyée sur GitHub soit en ligne (si ATTENDRE_VERSION=1)
// - ouvre l'application et la console dans Chrome, vérifie qu'elles démarrent sans erreur
// - vérifie que les fonctions serveur et la base répondent
// Sortie : code 1 et un résumé dans surveillance.txt si quelque chose ne va pas.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const SITE = process.env.SITE || "https://gescobar-cm.pages.dev";
const SUPA = "https://tkiuepleshsvptranoik.supabase.co";
const local = fs.readFileSync(path.resolve(__dirname, "../dist/web/index.html"), "utf8");
const BUILD = (local.match(/APP_BUILD = "([0-9a-f]+)"/) || [])[1];
const KEY = (local.match(/key: "(sb_publishable_[^"]+)"/) || [])[1];
const pannes = [];
const panne = m => { pannes.push(m); console.log("✘ " + m); };
const bon = m => console.log("✔ " + m);

(async () => {
  // 1) La bonne version est-elle en ligne ?
  if (process.env.ATTENDRE_VERSION === "1" && BUILD) {
    let enLigne = "";
    for (let i = 0; i < 30; i++) {
      try { const h = await (await fetch(SITE + "/?v=" + Date.now(), { cache: "no-store" })).text(); enLigne = (h.match(/APP_BUILD = "([0-9a-f]+)"/) || [])[1] || ""; } catch (e) {}
      if (enLigne === BUILD) break;
      await new Promise(r => setTimeout(r, 20000));
    }
    if (enLigne === BUILD) bon(`la version ${BUILD} est en ligne`); else panne(`la nouvelle version ${BUILD} n'est pas en ligne après 10 min (en ligne : ${enLigne || "illisible"})`);
  }

  // 2) Serveur : fonctions et base
  try {
    const r = await fetch(SUPA + "/functions/v1/gesco-admin", { method: "POST", headers: { "Content-Type": "application/json", apikey: KEY }, body: JSON.stringify({ action: "staff_list", code: "ZZZZZZ" }) });
    const j = await r.json().catch(() => ({}));
    if (r.status === 404 && /Aucun bar/.test(j.error || "")) bon("fonction serveur et base de données : répondent"); else panne(`fonction serveur gesco-admin : réponse inattendue (${r.status} ${JSON.stringify(j).slice(0, 120)})`);
  } catch (e) { panne("fonction serveur gesco-admin injoignable : " + e.message); }
  try {
    const r = await fetch(SUPA + "/functions/v1/gesco-push", { method: "POST", headers: { "Content-Type": "application/json", apikey: KEY }, body: JSON.stringify({ action: "key" }) });
    const j = await r.json().catch(() => ({}));
    if (r.ok && j.key) bon("notifications : le service répond"); else panne(`service de notifications : réponse inattendue (${r.status})`);
  } catch (e) { panne("service de notifications injoignable : " + e.message); }

  // 3) L'application et la console s'affichent-elles vraiment ?
  const b = await chromium.launch();
  for (const [nom, url, pret] of [
    ["application", SITE + "/", () => window.__gescoOK === true && !!document.querySelector("#app [data-a]")],
    ["console éditeur", SITE + "/console", () => typeof V !== "undefined" && !!document.querySelector("input, [data-a]")],
  ]) {
    const ctx = await b.newContext({ viewport: { width: 393, height: 852 }, serviceWorkers: "block" }), page = await ctx.newPage(), errs = [];
    page.on("pageerror", e => errs.push(e.message));
    try {
      const rep = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
      if (!rep || rep.status() >= 400) throw new Error("page " + (rep ? rep.status() : "sans réponse"));
      await page.waitForFunction(pret, null, { timeout: 30000 });
      if (await page.$("#gesco-rescue")) throw new Error("écran « GesCo n'a pas pu démarrer » affiché");
      if (errs.length) throw new Error("erreur JavaScript : " + errs[0]);
      bon(nom + " : s'affiche correctement");
    } catch (e) { panne(`${nom} ne s'affiche pas (${String(e.message).split("\n")[0].slice(0, 160)})`); }
    await ctx.close();
  }
  await b.close();

  fs.writeFileSync(path.resolve(__dirname, "../surveillance.txt"), pannes.join(" · "));
  console.log(pannes.length ? `\n${pannes.length} problème(s).` : "\nTout fonctionne.");
  process.exit(pannes.length ? 1 : 0);
})().catch(e => { fs.writeFileSync(path.resolve(__dirname, "../surveillance.txt"), "le contrôle lui-même a échoué : " + e.message); console.error(e); process.exit(1); });
