"""Assemble les deux versions de GesCo Bar à partir de src/app.html.
- dist/web/ : application en ligne (PWA) branchée sur Supabase, à déployer sur Netlify/Vercel.
- dist/demo.html : version démo autonome (données locales), publiée comme page Claude.
"""
import json, pathlib, shutil
ROOT = pathlib.Path(__file__).parent
import hashlib
SRC = (ROOT / "src/app.html").read_text(encoding="utf-8").replace("__LOGO_B64__", (ROOT / "src/logo.b64").read_text().strip())
SRC = SRC.replace("__BUILD__", hashlib.sha1(SRC.encode()).hexdigest()[:8])
SUPABASE_URL = "https://tkiuepleshsvptranoik.supabase.co"
SUPABASE_KEY = "sb_publishable_GF4euX-Zbx3Bve-WSkgBWA_u4JoBY6w"  # clé publique (publishable), faite pour le navigateur
SB_JS = '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>'
OUT = ROOT.parent / "dist"

live_cfg = '{ mode: /[?&]demo\\b/.test(location.search) ? "demo" : "live", url: %s, key: %s }' % (json.dumps(SUPABASE_URL), json.dumps(SUPABASE_KEY))
live = SRC.replace("/*CONFIG*/", live_cfg).replace("<!--SUPABASE-->", SB_JS).replace("<!--VIEWPORT_SIDES-->", "")
head, body = live.split('<div id="app">', 1)
doc = f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0f5c3c">
<meta name="description" content="GesCo Bar : tickets par serveuse, caisse, stock et reliquats pour les bars et snacks.">
<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="icon-192.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<style>:root{{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}</style>
{head.strip()}
</head>
<body>
<div id="app">{body}
<script>
// Mise à jour automatique : dès qu'une nouvelle version est publiée, l'application se recharge toute seule (les tickets non envoyés restent gardés sur le téléphone).
if ("serviceWorker" in navigator && location.protocol === "https:") {{
  const had = !!navigator.serviceWorker.controller; let done = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {{ if (!had || done) return; done = true;
    const go = () => {{ const a = document.activeElement; if (a && /INPUT|TEXTAREA|SELECT/.test(a.tagName)) return setTimeout(go, 4000); location.reload(); }}; go(); }});
  navigator.serviceWorker.register("sw.js").then(r => {{ setInterval(() => r.update().catch(() => {{}}), 15 * 60000);
    document.addEventListener("visibilitychange", () => {{ if (document.visibilityState === "visible") r.update().catch(() => {{}}); }}); }}).catch(() => {{}});
}}
</script>
</body>
</html>
"""
web = OUT / "web"; web.mkdir(parents=True, exist_ok=True)
(web / "index.html").write_text(doc, encoding="utf-8")
for f in (ROOT / "public").iterdir():
    if f.is_dir(): shutil.copytree(f, web / f.name, dirs_exist_ok=True)
    else: shutil.copy(f, web / f.name)
(web / "_headers").write_text("/sw.js\n  Cache-Control: no-cache\n/\n  Cache-Control: no-cache\n/index.html\n  Cache-Control: no-cache\n/console\n  Cache-Control: no-cache\n  X-Robots-Tag: noindex\n/console.html\n  Cache-Control: no-cache\n  X-Robots-Tag: noindex\n", encoding="utf-8")
# Console éditeur (BISMO Agency)
console = (ROOT / "src/admin.html").read_text(encoding="utf-8").replace("__BUILD__", hashlib.sha1((ROOT / "src/admin.html").read_bytes()).hexdigest()[:8]).replace("__LOGO_B64__", (ROOT / "src/logo.b64").read_text().strip()).replace("__URL__", SUPABASE_URL).replace("__KEY__", SUPABASE_KEY)
(web / "console.html").write_text(console, encoding="utf-8")

import base64
PIMG = {f.stem: "data:image/webp;base64," + base64.b64encode(f.read_bytes()).decode() for f in sorted((ROOT / "public/produits").glob("*.webp"))}
demo = SRC.replace("/*PIMG*/null", json.dumps(PIMG)).replace("/*CONFIG*/", '{ mode: "demo" }').replace("<!--SUPABASE-->", "").replace(
    "<!--VIEWPORT_SIDES-->", '<meta name="claude:viewport-fit-sides" content="cover">')
(OUT / "demo.html").write_text(demo, encoding="utf-8")
print("ok", len(doc), len(demo))
