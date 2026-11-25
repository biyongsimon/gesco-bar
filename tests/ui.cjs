// Tests de l'interface GesCo Bar sur la version démo (dist/demo.html, données locales, sans réseau Supabase).
// Lancement : node tests/ui.cjs   (après python3 app/build.py). Code de sortie 1 si un test échoue.
// Captures des échecs : tests/echecs/*.png
const { chromium } = require("playwright");
const path = require("path"), fs = require("fs"), os = require("os");
const DEMO = "file://" + path.resolve(__dirname, "../dist/demo.html");
const OUT = path.resolve(__dirname, "echecs");
const PERSONNES = { Aline: "1111", Brigitte: "2222", Carine: "3333", Mireille: "0000", Paul: "4444", "Hervé": "5555", Marcel: "9999" };
const MOBILE = { viewport: { width: 360, height: 780 } }, PC = { viewport: { width: 1280, height: 800 } };

let browser; const bilan = [];
const ok = (c, m) => { if (!c) throw new Error(m); };

async function login(page, nom) {
  await page.evaluate(async () => { try { await B.logout(); } catch (e) {} });
  await page.reload(); await page.waitForFunction(() => typeof V !== "undefined" && document.querySelector("[data-a]"));
  if (await page.$('[data-a="loadStaff"]')) await page.click('[data-a="loadStaff"]');
  await page.click(`.who-pick button:has-text("${nom}")`);
  for (const k of PERSONNES[nom]) await page.click(`.pad [data-k="${k}"]`);
  if (await page.$('[data-a="pinGo"]')) await page.click('[data-a="pinGo"]').catch(() => {});
  await page.waitForFunction(() => V.screen === "app" && S && S.me, null, { timeout: 8000 });
  await page.waitForTimeout(150);
}
const rpc = (page, nom, args) => page.evaluate(async ([n, a]) => { try { const v = await B.rpc(n, a); await refresh(); return { ok: true, v }; } catch (e) { return { ok: false, e: e.message }; } }, [nom, args]);

async function test(nom, fn, opts = {}) {
  const ctx = await browser.newContext(opts.ctx || MOBILE), page = await ctx.newPage(), errs = [];
  page.on("pageerror", e => errs.push(e.message));
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  if (opts.init) await page.addInitScript(opts.init);
  const t0 = Date.now();
  try {
    await page.goto(DEMO);
    await page.evaluate(() => { localStorage.clear(); localStorage.setItem("gesco-ntf-ask", "1"); });
    await page.reload();
    page.on("load", () => { if (page.url().includes("/dist/web/")) errs.length = 0; });
    await fn(page);
    ok(!errs.length || page.url().includes("/dist/web/"), "Erreur JavaScript : " + errs[0]);
    bilan.push([nom, true]); console.log(`✔ ${nom} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  } catch (e) {
    bilan.push([nom, false]); console.log(`✘ ${nom}\n    ${String(e.message).split("\n")[0]}`);
    fs.mkdirSync(OUT, { recursive: true }); await page.screenshot({ path: path.join(OUT, nom.replace(/[^a-z0-9]+/gi, "-") + ".png"), fullPage: true }).catch(() => {});
  } finally { await ctx.close(); }
}

// Parcourt tous les onglets de la personne connectée : aucune erreur, aucun débordement horizontal
async function tousLesOnglets(page) {
  const onglets = await page.evaluate(() => navFor()); const deborde = [];
  for (const v of onglets) {
    await page.evaluate(v => { V.modal = null; A.go({ v }); }, v); await page.waitForTimeout(120);
    const d = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    if (d > 1) deborde.push(`${v} (+${d}px)`);
  }
  ok(!deborde.length, "Débordement horizontal : " + deborde.join(", "));
  return onglets.length;
}

(async () => {
  browser = await chromium.launch();

  for (const nom of Object.keys(PERSONNES)) await test(`${nom} : tous les onglets s'ouvrent sur téléphone (360 px)`, async page => {
    await login(page, nom); const n = await tousLesOnglets(page); ok(n >= 3, `seulement ${n} onglets`);
  });
  for (const nom of ["Mireille", "Marcel"]) await test(`${nom} : poste caisse sur ordinateur (1280 px)`, async page => {
    await login(page, nom); ok(await page.evaluate(() => desk()), "affichage ordinateur non activé"); await tousLesOnglets(page);
  }, { ctx: PC });

  await test("Ticket : envoi, encaissement, versement, puis commande close", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID());
    const biere = await page.evaluate(() => S.products.find(p => p.name.startsWith("Castel")).id);
    ok((await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table test" })).ok, "création du ticket");
    ok((await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: biere, p_qty: 2 })).ok, "ajout de 2 bières");
    ok((await rpc(page, "gb_ticket_send", { p_ticket: id })).ok, "envoi à la caisse");
    const total = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id);
    const c = await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: total }); ok(c.ok, "encaissement : " + c.e);
    const moi = await page.evaluate(() => S.me.id);
    await login(page, "Mireille");
    const v = await rpc(page, "gb_remit", { p_waitress: moi, p_received: total }); ok(v.ok, "versement : " + v.e);
    ok(await page.evaluate(id => S.tickets.find(t => t.id === id).status, id) === "paid", "le ticket n'est pas payé");
    const r = await rpc(page, "gb_ticket_reopen", { p_ticket: id }); ok(!r.ok && /close/.test(r.e), "une commande payée a pu être rouverte");
    await login(page, "Brigitte");
    const a = await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: biere, p_qty: 3 }); ok(!a.ok, "un article a pu être ajouté à une commande payée");
  });

  await test("Ticket envoyé : seuls les articles choisis s'affichent", async page => {
    await login(page, "Aline");
    const id = await page.evaluate(async () => { const id = crypto.randomUUID(); await B.rpc("gb_ticket_create", { p_id: id, p_client: "Table 5" });
      await B.rpc("gb_ticket_set_qty", { p_ticket: id, p_product: S.products.find(p => p.name.startsWith("Castel")).id, p_qty: 2 });
      await B.rpc("gb_ticket_send", { p_ticket: id }); await refresh(); V.open = { [id]: true }; render(); return id; });
    await page.waitForTimeout(200);
    ok(await page.evaluate(() => document.querySelectorAll(".tk.open .pcard").length) === 0, "le catalogue complet est affiché");
    ok(await page.$('[data-a="more"]'), "bouton « Ajouter ou corriger un article » absent");
    await page.click('[data-a="more"]'); await page.waitForTimeout(150);
    ok(await page.evaluate(() => document.querySelectorAll(".tk.open .pcard").length) > 5, "le catalogue ne s'ouvre pas");
  });

  await test("Cuisine : seul le cuisinier fait avancer les bons", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID());
    const plat = await page.evaluate(() => S.products.find(p => p.name === "Poulet DG").id);
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table cuisine" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: plat, p_qty: 1 });
    ok((await rpc(page, "gb_ticket_send", { p_ticket: id })).ok, "envoi du plat");
    const bon = await page.evaluate(id => (S.kitchen.find(o => o.ticket_id === id) || {}).id, id); ok(bon, "aucun bon en cuisine");
    await login(page, "Mireille");
    const r = await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "pret" }); ok(!r.ok && /Seule la cuisine/.test(r.e), "la caisse a pu marquer le plat prêt");
    await page.evaluate(() => A.go({ v: "kitchen" })); await page.waitForTimeout(150);
    ok(await page.evaluate(() => document.querySelectorAll('[data-a="kStep"]').length) === 0, "la caisse voit des boutons d'action cuisine");
    await login(page, "Paul");
    ok((await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "prep" })).ok && (await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "pret" })).ok, "le cuisinier ne peut pas avancer le bon");
    await login(page, "Brigitte");
    ok((await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "servi" })).ok, "la serveuse ne peut pas confirmer le retrait");
  });

  await test("Abonnement : mode test caché (petit montant, 1 mois)", async page => {
    await login(page, "Marcel");
    await page.evaluate(() => { S.bar.sub_test_price = 200; V.f.ab_p = "gold"; A.go({ v: "abo" }); }); await page.waitForTimeout(150);
    ok(await page.evaluate(() => /Mode test/.test(document.body.innerText)), "bandeau « Mode test » absent");
    ok(await page.evaluate(() => document.querySelectorAll('[data-k2="ab_m"]').length) === 0, "les durées sont proposées en mode test");
    await page.evaluate(() => { S.bar.sub_test_price = null; render(); }); await page.waitForTimeout(100);
    ok(await page.evaluate(() => document.querySelectorAll('[data-k2="ab_m"]').length) === 4, "les 4 durées ne reviennent pas");
  });

  await test("Notifications bloquées : la fenêtre d'aide s'ouvre", async page => {
    await login(page, "Carine");
    await page.evaluate(() => { V.menu = true; render(); }); await page.waitForTimeout(100);
    ok(/Débloquer/.test(await page.textContent('[data-a="notifOn"]')), "le bouton ne dit pas « Débloquer »");
    await page.click('[data-a="notifOn"]'); await page.waitForTimeout(200);
    ok(await page.evaluate(() => /bloquées sur cet appareil/.test(document.body.innerText)), "les étapes ne s'affichent pas");
  }, { init: () => { Object.defineProperty(Notification, "permission", { get: () => "denied" }); Notification.requestPermission = async () => "denied"; } });

  await test("Bar suspendu : motif, demande de réactivation avec preuve, message à l'équipe", async page => {
    const img = path.join(os.tmpdir(), "gesco-preuve.png");
    fs.writeFileSync(img, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"));
    await login(page, "Marcel");
    await page.evaluate(() => { const k = Object.keys(localStorage).find(x => /^gesco-demo-v\d+$/.test(x)); const d = JSON.parse(localStorage.getItem(k));
      Object.assign(d.bar, { suspended: true, suspend_reason: "Abonnement impayé", suspended_at: new Date().toISOString() }); localStorage.setItem(k, JSON.stringify(d)); });
    await page.reload(); await page.waitForFunction(() => document.querySelector(".lockv"), null, { timeout: 8000 });
    ok(/Motif : Abonnement impayé/.test(await page.textContent(".lockv")), "motif absent");
    await page.fill("#re_msg", "Nous avons payé, voici la preuve."); await page.dispatchEvent("#re_msg", "input");
    await page.setInputFiles("#re_files", img); await page.waitForTimeout(150);
    await page.click('[data-a="reactSend"]');
    await page.waitForFunction(() => /Transmise à BISMO Agency/.test(document.body.innerText), null, { timeout: 5000 });
    ok(await page.$('[data-a="reactFile"]'), "la preuve n'apparaît pas dans l'échange");
    await login(page, "Carine");
    ok(/Prévenez votre PDG/.test(await page.textContent(".lockv")), "la serveuse ne voit pas la consigne");
    ok(!(await page.$("#re_msg")), "la serveuse peut envoyer une demande");
  });

  await test("Démarrage normal : aucun écran de secours", async page => {
    await login(page, "Brigitte"); await page.waitForTimeout(8600);
    ok(!(await page.$("#gesco-rescue")), "l'écran de secours s'affiche alors que l'application marche");
    ok(await page.evaluate(() => window.__gescoOK === true), "l'application ne signale pas son démarrage");
  });

  await test("Écran blanc : la garde prévient BISMO et propose de réparer", async page => {
    const recu = [];
    await page.route(/cdn\.jsdelivr\.net/, r => r.abort());   // bibliothèque introuvable = l'application ne peut pas démarrer
    await page.route(/supabase\.co\/rest\/v1\/rpc\/gb_log_error/, r => { recu.push(r.request().postDataJSON()); r.fulfill({ status: 204, body: "" }); });
    page.removeAllListeners("pageerror");   // ici les erreurs JavaScript sont voulues
    await page.goto("file://" + path.resolve(__dirname, "../dist/web/index.html"));
    await page.waitForSelector("#gesco-rescue", { timeout: 15000 });
    ok(/n’a pas pu démarrer/.test(await page.textContent("#gesco-rescue")), "message de l'écran de secours absent");
    ok(await page.$('#gesco-rescue button[onclick*="__gescoRepair"]'), "bouton « Réparer » absent");
    await page.waitForTimeout(500);
    ok(recu.length === 1 && /^DÉMARRAGE/.test(recu[0].p_message), "le rapport de démarrage n'a pas été envoyé");
    ok(/Fichier non chargé|createClient|supabase/i.test(recu[0].p_stack || recu[0].p_message), "la cause n'est pas dans le rapport");
  }, { ctx: MOBILE });

  await test("Erreur hors réseau : gardée puis envoyée au retour du réseau", async page => {
    await login(page, "Brigitte");
    const ctx = page.context(); await ctx.setOffline(true);
    await page.evaluate(() => { window.__envoyes = []; B.logError = a => { if (!navigator.onLine) return errKeep(a); window.__envoyes.push(a); }; reportErr(new TypeError("panne simulée hors réseau")); });
    ok(await page.evaluate(() => JSON.parse(localStorage.getItem("gesco-errq") || "[]").length) === 1, "l'erreur n'est pas gardée hors réseau");
    await ctx.setOffline(false); await page.evaluate(() => errFlush());
    ok(await page.evaluate(() => window.__envoyes.length === 1 && /hors réseau/.test(window.__envoyes[0].p_stack)), "l'erreur n'est pas envoyée au retour du réseau");
    ok(await page.evaluate(() => !localStorage.getItem("gesco-errq")), "la file n'est pas vidée");
  });

  await browser.close();
  const ko = bilan.filter(b => !b[1]).length;
  console.log(`\n${bilan.length - ko} réussi(s), ${ko} échoué(s) sur ${bilan.length}.`);
  process.exit(ko ? 1 : 0);
})().catch(e => { console.error("Erreur du lanceur de tests :", e); process.exit(2); });
