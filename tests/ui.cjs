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
    await page.evaluate(() => A.go({ v: "kitchen" }));
    await page.waitForFunction(() => [...document.querySelectorAll(".kcard img.dish")].some(i => i.complete && i.naturalWidth > 0), null, { timeout: 5000 }).catch(() => {});
    ok(await page.evaluate(() => [...document.querySelectorAll(".kcard img.dish")].some(i => i.naturalWidth > 0)), "la photo du plat ne s'affiche pas sur le bon de cuisine");
    ok((await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "prep" })).ok && (await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "pret" })).ok, "le cuisinier ne peut pas avancer le bon");
    await login(page, "Brigitte");
    ok((await rpc(page, "gb_kitchen_step", { p_id: bon, p_status: "servi" })).ok, "la serveuse ne peut pas confirmer le retrait");
  });

  await test("Caissière : rubrique Plats (sans écran cuisine) et courses payées avec le tiroir", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID());
    const plat = await page.evaluate(() => S.products.find(p => p.name === "Ndolé"));
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table plats" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: plat.id, p_qty: 2 });
    ok((await rpc(page, "gb_ticket_send", { p_ticket: id })).ok, "envoi des plats");
    await login(page, "Paul");
    const rc = await rpc(page, "gb_market_add", { p_items: [{ a: "Tomates", m: 1500 }], p_method: "tiroir" }); ok(!rc.ok && /Seule la caisse/.test(rc.e), "le cuisinier a pu payer avec le tiroir");
    await login(page, "Mireille");
    const nav = await page.evaluate(() => navFor()); ok(nav.includes("plats") && !nav.includes("kitchen"), "menu de la caissière : " + nav.join(","));
    ok(await page.evaluate(() => !KDS_OK()), "la caissière peut encore ouvrir l'écran mural");
    await page.evaluate(() => A.go({ v: "plats" })); await page.waitForTimeout(150);
    const t1 = await page.evaluate(() => document.querySelector("main, #app").textContent);
    ok(/Ndolé/.test(t1) && /Reste à encaisser/.test(t1) && /Contrôle cuisine \/ caisse/.test(t1), "relevé des plats incomplet");
    const st = await page.evaluate(() => platStats().tot); ok(st.sent >= 2 && st.sentM >= 2 * plat.price, "plats non payés mal comptés : " + JSON.stringify(st));
    // Le client paie : les plats passent en « payés »
    await login(page, "Brigitte"); const tot = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id);
    ok((await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: tot })).ok, "encaissement");
    await login(page, "Mireille");
    const st2 = await page.evaluate(() => platStats().tot); ok(st2.cashed + st2.paid >= 2 && st2.sent === st.sent - 2, "plats payés mal comptés : " + JSON.stringify(st2));
    // Courses payées avec le tiroir : retirées des espèces attendues
    await page.evaluate(() => A.go({ v: "day" })); await page.waitForFunction(() => V.mk && V.mk.items, null, { timeout: 4000 });
    const lit = () => page.evaluate(() => { const r = [...document.querySelectorAll(".between")].find(e => /Espèces attendues en caisse/.test(e.textContent)); return +r.querySelector(".num").textContent.replace(/\D/g, ""); });
    const avant = await lit();
    ok(await page.$('.segs [data-v="tiroir"].on'), "le tiroir n'est pas proposé par défaut à la caissière");
    await page.fill("#mk_a0", "Tomates"); await page.fill("#mk_m0", "1500"); await page.click('[data-a="mkSave"]');
    await page.waitForFunction(() => V.mk && V.mk.tiroir_jour === 1500, null, { timeout: 4000 });
    ok(await lit() === avant - 1500, `espèces attendues non diminuées (${avant} → ${await lit()})`);
    ok(/Courses payées avec le tiroir/.test(await page.textContent("#app")), "ligne des courses absente du comptage");
    const r = await rpc(page, "gb_day_close", { p_counted: avant - 1500, p_force: true }); ok(r.ok, "clôture : " + r.e);
    ok(r.v.ecart === 0 && r.v.depenses_caisse === 1500 && r.v.plats.qte >= 2 && r.v.boissons === r.v.ventes - r.v.plats.montant, "rapport de clôture : " + JSON.stringify({ e: r.v.ecart, d: r.v.depenses_caisse, p: r.v.plats }));
    await page.evaluate(s => { V.modal = { type: "summary", s }; render(); }, r.v); await page.waitForTimeout(100);
    const rap = await page.evaluate(() => document.body.textContent);
    ok(/Plats vendus/.test(rap) && /dont plats/.test(rap) && /Courses payées avec le tiroir/.test(rap), "le rapport n'affiche pas plats, boissons et courses");
  });

  await test("Saisie d'un montant : le curseur reste à la fin malgré l'actualisation", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID());
    const p = await page.evaluate(() => S.products.find(p => p.category !== "Cuisine" && p.active && !p.parent_id).id);
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table curseur" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: p, p_qty: 2 });
    ok((await rpc(page, "gb_ticket_send", { p_ticket: id })).ok, "envoi");
    await page.evaluate(id => { V.open[id] = true; render(); }, id); await page.waitForTimeout(150);
    const sel = `[id="rcv_${id}"]`; await page.click(sel);
    for (const ch of "15000") { await page.keyboard.type(ch); await page.waitForTimeout(320); }   // une actualisation entre chaque chiffre
    const v = await page.inputValue(sel); ok(v === "15000", `montant saisi « ${v} » au lieu de « 15000 »`);
    await page.keyboard.type("a"); await page.waitForTimeout(320); ok(await page.inputValue(sel) === "15000", "une lettre a été acceptée dans le montant");
  });

  await test("Rappel de versement : bandeau serveuse, retard visible à la caisse, réglage du PDG", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID());
    const p = await page.evaluate(() => S.products.find(p => p.category !== "Cuisine" && p.active && !p.parent_id).id);
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table rappel" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: p, p_qty: 1 });
    await rpc(page, "gb_ticket_send", { p_ticket: id }); const tot = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id);
    ok((await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: tot })).ok, "encaissement");
    await page.evaluate(() => A.go({ v: "service" })); await page.waitForTimeout(100);
    ok(!/Pensez à verser/.test(await page.textContent("#app")), "rappel affiché trop tôt");
    // L'encaissement date de 50 minutes
    await page.evaluate(id => { const k = Object.keys(localStorage).find(x => /^gesco-demo-v\d+$/.test(x)); const d = JSON.parse(localStorage.getItem(k));
      d.tickets.filter(t => t.status === "cashed" && t.pay_method === "cash").forEach(t => t.cashed_at = new Date(Date.now() - 50 * 60000).toISOString()); localStorage.setItem(k, JSON.stringify(d)); }, id);
    await login(page, "Brigitte"); await page.evaluate(() => A.go({ v: "service" })); await page.waitForTimeout(100);
    ok(/Pensez à verser/.test(await page.textContent("#app")), "bandeau de rappel absent chez la serveuse");
    await login(page, "Mireille"); await page.evaluate(() => A.go({ v: "direct" })); await page.waitForTimeout(100);
    ok(/depuis 5\d min/.test(await page.textContent("#app")), "retard de versement non signalé à la caisse");
    await login(page, "Marcel"); await page.evaluate(() => A.go({ v: "settings" })); await page.waitForTimeout(100);
    ok(/Rappel de versement des espèces/.test(await page.textContent("#app")), "réglage des rappels absent");
    await page.fill("#rr2", "10"); await page.click('[data-a="saveRemit"]'); await page.waitForTimeout(150);
    ok(await page.evaluate(() => (S.bar.opts || {}).remit_r2 === undefined), "délais non croissants acceptés");
    await page.fill("#rr1", "15"); await page.fill("#rr2", "30"); await page.fill("#rr3", "60"); await page.click('[data-a="saveRemit"]'); await page.waitForTimeout(150);
    ok(await page.evaluate(() => S.bar.opts.remit_r1 === 15 && S.bar.opts.remit_r3 === 60), "délais non enregistrés");
    // « Ma paie » cachée sans salaire ni paiement (cuisinier de la démo)
    await login(page, "Paul"); await page.evaluate(() => A.go({ v: "moi" })); await page.waitForTimeout(100);
    ok(!/Ma paie/.test(await page.textContent("#app")), "« Ma paie » affichée sans aucun salaire");
    await login(page, "Aline"); await page.evaluate(() => A.go({ v: "moi" })); await page.waitForTimeout(100);
    ok(/Ma paie/.test(await page.textContent("#app")), "« Ma paie » absente alors qu'un salaire existe");
  });

  await test("PDF : logo du snack, rapport de clôture et bon de commande ; le directeur voit les rapports", async page => {
    const lirePdf = () => page.evaluate(async () => { const b = window.__lastPdf; window.__lastPdf = null; const t = await b.text(); return { n: b.size, pdf: t.startsWith("%PDF"), img: /\/Subtype\s*\/Image/.test(t) }; });
    await login(page, "Marcel"); await page.evaluate(() => A.go({ v: "settings" })); await page.waitForTimeout(100);
    await page.setInputFiles("#logo_file", path.resolve(__dirname, "logo-test.png")); await page.waitForTimeout(100); await page.click('[data-a="logoSave"]');
    await page.waitForFunction(() => /^data:image\/png/.test(S.bar.logo_path || ""), null, { timeout: 5000 });
    await page.fill("#doc_tel", "6 90 12 34 56"); await page.click('[data-a="docTelSave"]'); await page.waitForTimeout(150);
    ok(await page.evaluate(() => S.bar.opts.phone === "6 90 12 34 56"), "téléphone des documents non enregistré");
    await login(page, "Mireille");
    const r = await rpc(page, "gb_day_close", { p_counted: 0, p_force: true }); ok(r.ok, "clôture : " + r.e);
    await page.evaluate(s => { V.modal = { type: "summary", s: { ...s, par: S.me.name } }; render(); }, r.v);
    await page.click('[data-a="repPdf"]:not([data-wa])'); await page.waitForFunction(() => !!window.__lastPdf, null, { timeout: 15000 });
    const p1 = await lirePdf(); ok(p1.pdf && p1.img && p1.n > 3000 && p1.n < 200000, "PDF du rapport invalide : " + JSON.stringify(p1));
    await page.evaluate(() => { V.modal = null; A.go({ v: "stock" }); }); await page.evaluate(() => A.reaLoad(true)); await page.waitForTimeout(300);
    await page.click('[data-a="poCreate"]'); await page.waitForSelector('[data-a="poPdf"]', { timeout: 5000 });
    await page.click('[data-a="poPdf"]:not([data-wa])'); await page.waitForFunction(() => !!window.__lastPdf, null, { timeout: 15000 });
    const p2 = await lirePdf(); ok(p2.pdf && p2.img, "PDF du bon de commande invalide : " + JSON.stringify(p2));
    await login(page, "Hervé"); ok(await page.evaluate(() => navFor().includes("day") && S.days.length > 0), "le directeur n'a pas les rapports de clôture");
    await page.evaluate(() => A.go({ v: "day" })); await page.click('[data-a="showDay"]'); await page.waitForTimeout(100);
    ok(await page.$('[data-a="repPdf"][data-wa]'), "bouton WhatsApp du rapport absent chez le directeur");
  }, { ctx: { viewport: { width: 360, height: 780 }, acceptDownloads: true } });

  await test("Cuisinier : production du jour et coût matière", async page => {
    await login(page, "Brigitte");
    const id = await page.evaluate(() => crypto.randomUUID()), plat = await page.evaluate(() => S.products.find(p => p.name === "Ndolé"));
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table prod" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: plat.id, p_qty: 2 });
    await rpc(page, "gb_ticket_send", { p_ticket: id });
    await login(page, "Paul"); const bons = await page.evaluate(id => S.kitchen.filter(o => o.ticket_id === id).map(o => o.id), id);
    for (const b of bons) { await rpc(page, "gb_kitchen_step", { p_id: b, p_status: "prep" }); await rpc(page, "gb_kitchen_step", { p_id: b, p_status: "pret" }); }
    await rpc(page, "gb_market_add", { p_items: [{ a: "Feuilles de ndolé", m: 2100 }], p_method: "cash" });
    await page.evaluate(() => A.go({ v: "kitchen" })); await page.waitForFunction(() => V.ks && V.mk && V.mk.items, null, { timeout: 4000 }); await page.waitForTimeout(100);
    const t = await page.textContent("#app");
    ok(/Ma production du jour/.test(t) && /Ndolé/.test(t), "carte de production absente");
    ok(await page.evaluate(n => (document.body.textContent.match(/(\d+) plats? ·/) || [])[1] >= 2, plat.price), "plats sortis mal comptés");
    ok(/Coût matière/.test(t), "coût matière absent");
    await login(page, "Brigitte"); const tot = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id);
    await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: tot });
    await login(page, "Hervé"); await page.evaluate(() => A.go({ v: "kitchen" })); await page.waitForFunction(() => V.ks && V.mk && V.mk.items, null, { timeout: 4000 }); await page.waitForTimeout(100);
    ok(/Production de la cuisine/.test(await page.textContent("#app")) && await page.$(".card .pill.ok, .card .pill.warn, .card .pill.bad"), "coût matière (%) absent chez le directeur");
    const st = await page.evaluate(() => V.ks[0]); ok(st.courses >= 2100 && st.montant >= 2 * 3500 && st.sortis >= 2, "statistiques du jour fausses : " + JSON.stringify(st));
  });

  await test("Ardoise : la serveuse demande, la caisse valide, plafond, remboursement dans le tiroir", async page => {
    const nouveau = async (cl, q) => { const id = await page.evaluate(() => crypto.randomUUID()), p = await page.evaluate(() => S.products.find(p => p.name.startsWith("Castel")).id);
      await rpc(page, "gb_ticket_create", { p_id: id, p_client: cl }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: p, p_qty: q }); await rpc(page, "gb_ticket_send", { p_ticket: id }); return id; };
    await login(page, "Brigitte"); const t1 = await nouveau("Table ardoise", 2);
    await page.evaluate(id => { V.open[id] = true; A.go({ v: "service" }); }, t1); await page.waitForTimeout(100);
    await page.click(`[data-a="credPick"][data-t="${t1}"]`); const tonton = await page.evaluate(() => S.credit.find(c => c.name === "Tonton Paul").id);
    await page.selectOption(`#cr_${t1}`, tonton); await page.click(`[data-a="credReq"][data-t="${t1}"]`); await page.waitForTimeout(250);
    ok(await page.evaluate(id => { const t = S.tickets.find(x => x.id === id); return t.status === "cashed" && t.pay_method === "credit"; }, t1), "demande d'ardoise non enregistrée");
    const t2 = await nouveau("Table Essomba", 3); const ess = await page.evaluate(() => S.credit.find(c => c.name === "M. Essomba").id);
    ok((await rpc(page, "gb_ticket_credit", { p_ticket: t2, p_client: ess })).ok, "2e demande");
    await login(page, "Mireille"); await page.evaluate(() => A.go({ v: "direct" })); await page.waitForTimeout(100);
    ok(/Ardoise demandée/.test(await page.textContent("#app")), "la caisse ne voit pas la demande d'ardoise");
    await page.click(`[data-a="credOk"][data-t="${t1}"]`); await page.waitForTimeout(250);
    ok(await page.evaluate(id => S.tickets.find(x => x.id === id).status === "paid", t1), "ardoise non validée par la caisse");
    const r = await rpc(page, "gb_credit_validate", { p_ticket: t2, p_ok: true }); ok(!r.ok && /Plafond dépassé/.test(r.e), "plafond non respecté : " + JSON.stringify(r));
    ok(await page.evaluate(() => navFor().includes("ardoise")), "onglet Ardoise absent chez la caissière");
    const avant = await page.evaluate(() => sum(S.remits, r => r.received));
    await page.evaluate(() => A.go({ v: "ardoise" })); await page.waitForFunction(() => Array.isArray(V.cr), null, { timeout: 4000 });
    ok(/Tonton Paul/.test(await page.textContent("#app")), "liste des ardoises vide");
    await page.click(`[data-a="crPay"][data-id="${tonton}"]`); await page.fill("#crm", "2000"); await page.click(`[data-a="crPayGo"][data-id="${tonton}"]`); await page.waitForTimeout(300);
    ok(await page.evaluate(a => sum(S.remits, r => r.received) === a + 2000, avant), "le remboursement en espèces n'entre pas dans le tiroir");
    await login(page, "Marcel"); ok((await rpc(page, "gb_credit_validate", { p_ticket: t2, p_ok: true })).ok, "le PDG ne peut pas valider au-delà du plafond");
    await login(page, "Brigitte"); const rs = await rpc(page, "gb_credit_client_save", { p_id: null, p_name: "Moi-même", p_phone: "", p_limit: 999999 }); ok(!rs.ok, "une serveuse a ouvert une ardoise");
    await login(page, "Marcel"); await page.evaluate(() => A.go({ v: "settings" })); await page.waitForTimeout(100);
    await page.click('[data-a="optTog"][data-k="f_ardoise"]'); await page.waitForTimeout(200);
    ok(await page.evaluate(() => !navFor().includes("ardoise")), "l'ardoise reste visible après désactivation");
  });

  await test("Emballages : vides calculés, comptage avec écart, vides rendus avec le bon de commande", async page => {
    await login(page, "Brigitte"); const id = await page.evaluate(() => crypto.randomUUID()), p = await page.evaluate(() => S.products.find(p => p.name.startsWith("Castel")).id);
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table vides" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: p, p_qty: 4 }); await rpc(page, "gb_ticket_send", { p_ticket: id });
    const tot = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id); await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: tot });
    await login(page, "Mireille"); await page.evaluate(() => A.go({ v: "stock" })); await page.waitForFunction(() => Array.isArray(V.pk), null, { timeout: 4000 });
    const k = await page.evaluate(() => V.pk.find(x => x.name === "Casier 65 cl")); ok(k && k.theo >= 52, "vides théoriques faux : " + JSON.stringify(k && k.theo));
    ok(/Emballages consignés/.test(await page.textContent("#app")), "carte des emballages absente");
    await page.click(`[data-a="pkAct"][data-id="${k.id}"][data-k="comptage"]`); await page.fill("#pkq", String(k.theo - 3)); await page.click(`[data-a="pkGo"][data-id="${k.id}"]`);
    await page.waitForFunction(() => Array.isArray(V.pk), null, { timeout: 4000 }); await page.waitForTimeout(100);
    const k2 = await page.evaluate(id => V.pk.find(x => x.id === id), k.id); ok(k2.theo === k.theo - 3 && k2.last_count.qty - k2.last_count.theo === -3, "écart de comptage non enregistré");
    await page.evaluate(() => A.reaLoad(true)); await page.waitForTimeout(300); await page.click('[data-a="poCreate"]'); await page.waitForSelector('[data-a="poE"]', { timeout: 5000 });
    await page.click('[data-a="poE"]'); await page.fill(`#pe_${k.id}`, "24"); await page.click('[data-a="poEGo"]'); await page.waitForTimeout(200);
    const po = await page.evaluate(() => V.pos[0]); ok((po.empties || []).length === 1 && po.empties[0].q === 24, "vides non enregistrés sur le bon");
    ok(/Vides rendus : 24 Casier 65 cl/.test(await page.evaluate(id => poText(V.pos.find(x => x.id === id)), po.id)), "vides absents du message au fournisseur");
    await page.evaluate(() => { window.__lastPdf = null; }); await page.click('[data-a="poPdf"]:not([data-wa])'); await page.waitForFunction(() => !!window.__lastPdf, null, { timeout: 15000 });
    ok((await rpc(page, "gb_po_receive", { p_id: po.id, p_items: null })).ok, "réception du bon");
    const th = await page.evaluate(id => B.rpc("gb_pack_state", {}).then(L => L.find(x => x.id === id).theo), k.id); ok(th === k2.theo - 24, `vides non retirés à la livraison (${k2.theo} → ${th})`);
  }, { ctx: { viewport: { width: 360, height: 780 }, acceptDownloads: true } });

  await test("Lounge : prix de nuit, entrées à la porte, réservation VIP, bouteille gardée, rapport", async page => {
    await login(page, "Marcel"); await page.evaluate(() => A.go({ v: "settings" })); await page.waitForTimeout(100);
    const h = await page.evaluate(() => { const d = new Date(Date.now() + (new Date().getTimezoneOffset() + 60) * 60000 - 60000); return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); });
    ok((await rpc(page, "gb_bar_opts", { p_patch: { nuit_debut: h } })).ok, "heure de nuit");
    await page.evaluate(() => render()); ok(await page.$('[data-a="dtSave"]') && await page.$("#nuit_h"), "réglages de nuit ou de porte absents");
    await login(page, "Brigitte"); const castel = await page.evaluate(() => S.products.find(p => p.name.startsWith("Castel")));
    ok(await page.evaluate(() => nightNow()), "le tarif de nuit n'est pas actif à l'heure choisie");
    const id = await page.evaluate(() => crypto.randomUUID()); await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table nuit" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: castel.id, p_qty: 2 });
    ok(await page.evaluate(([id, np]) => S.tickets.find(t => t.id === id).items[0].unit_price === np, [id, castel.night_price]), "le prix de nuit n'est pas appliqué au ticket");
    ok(await page.evaluate(() => navFor().includes("resa")), "la serveuse ne voit pas les réservations");
    await page.evaluate(() => A.go({ v: "resa" })); await page.waitForTimeout(100);
    await page.click('[data-a="rsOpen"]'); await page.waitForTimeout(300);
    const rs = await page.evaluate(() => S.resas.find(r => r.name === "M. Ngono")); ok(rs.status === "arrivee" && rs.ticket_id, "le ticket de la table réservée n'est pas ouvert");
    await page.evaluate(() => A.go({ v: "resa" })); await page.waitForTimeout(100); ok(/Il manque/.test(await page.textContent("#app")), "minimum de consommation non signalé");
    await login(page, "Mireille"); ok(await page.evaluate(() => navFor().includes("porte")), "onglet Porte absent");
    await page.evaluate(() => A.go({ v: "porte" })); await page.waitForTimeout(100);
    const avant = await page.evaluate(() => sum(S.remits, r => r.received));
    await page.click('[data-a="dqStep"][data-v="1"]'); await page.click('[data-a="doorSell"][data-i="0"]'); await page.waitForTimeout(300);
    ok(await page.evaluate(a => sum(S.remits, r => r.received) === a + 4000, avant), "les entrées en espèces n'entrent pas dans le tiroir");
    await page.click('[data-a="doorX"]'); await page.waitForTimeout(300); ok(await page.evaluate(a => sum(S.remits, r => r.received) === a, avant), "annulation d'entrée sans effet");
    await page.click('[data-a="doorSell"][data-i="2"]'); await page.waitForTimeout(250);
    await page.evaluate(() => A.go({ v: "vouch" })); await page.waitForTimeout(100); await page.click('[data-a="kpNew"]');
    await page.fill("#kpc", "M. Kamga"); await page.selectOption("#kpp", castel.id); await page.click('[data-a="kpAdd"]'); await page.waitForTimeout(250);
    ok(await page.evaluate(() => S.kept.some(k => k.client === "M. Kamga")), "bouteille non gardée");
    const kid = await page.evaluate(() => S.kept.find(k => k.client === "M. Kamga").id); await page.click(`[data-a="kpClose"][data-id="${kid}"]`); await page.waitForTimeout(250);
    ok(await page.evaluate(() => !S.kept.some(k => k.client === "M. Kamga")), "bouteille non rendue");
    const r = await rpc(page, "gb_day_close", { p_counted: 0, p_force: true }); ok(r.ok && r.v.entrees.n >= 5 && r.v.entrees.montant >= 16000, "entrées absentes du rapport : " + JSON.stringify(r.v && r.v.entrees));
  });

  await test("Impression : addition et reçu (ESC/POS 58 mm, impression du système)", async page => {
    await login(page, "Brigitte"); const id = await page.evaluate(() => crypto.randomUUID()), p = await page.evaluate(() => S.products.find(p => p.name.startsWith("Castel")).id);
    await rpc(page, "gb_ticket_create", { p_id: id, p_client: "Table imprimée" }); await rpc(page, "gb_ticket_set_qty", { p_ticket: id, p_product: p, p_qty: 3 }); await rpc(page, "gb_ticket_send", { p_ticket: id });
    await page.evaluate(() => { localStorage.setItem("gesco-printer", JSON.stringify("systeme")); window.print = () => { window.__printed = (window.__printed || 0) + 1; }; });
    await page.evaluate(id => { V.open[id] = true; A.go({ v: "service" }); }, id); await page.waitForTimeout(100);
    await page.click(`[data-a="prTk"][data-t="${id}"]`); await page.waitForTimeout(200);
    const r = await page.evaluate(() => ({ n: window.__printed, mode: window.__lastPrint.mode, txt: window.__lastPrint.lines.map(l => l[1]).join("\n"), len: Math.max(...window.__lastPrint.lines.map(l => l[1].length)), b0: [...window.__lastPrint.bytes.slice(0, 2)] }));
    ok(r.n === 1 && r.mode === "systeme", "impression du système non lancée");
    ok(/ADDITION/.test(r.txt) && /TOTAL/.test(r.txt) && /Table imprim/.test(r.txt) && r.len <= 32, "contenu de l'addition incorrect : " + r.txt);
    ok(r.b0[0] === 27 && r.b0[1] === 64, "commandes ESC/POS absentes");
    const tot = await page.evaluate(id => S.tickets.find(t => t.id === id).total, id); await rpc(page, "gb_ticket_cash", { p_ticket: id, p_method: "cash", p_received: tot + 500 });
    await page.evaluate(id => { V.open[id] = true; V.wf = "cash"; render(); }, id); await page.click(`[data-a="prTk"][data-t="${id}"][data-k="recu"]`); await page.waitForTimeout(150);
    const r2 = await page.evaluate(() => window.__lastPrint.lines.map(l => l[1]).join("\n")); ok(/RECU/.test(r2) && /Monnaie rendue/.test(r2), "reçu incorrect : " + r2);
    await page.evaluate(() => A.go({ v: "moi" })); await page.waitForTimeout(100); ok(/Imprimante de cet appareil/.test(await page.textContent("#app")), "réglage de l'imprimante absent");
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
