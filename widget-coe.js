// COE Finanzas · diseño del widget de iPhone (Scriptable).
// Lo descarga el script corto del teléfono; así los cambios de diseño llegan sin volver a copiar nada.
// Recibe: TOKEN, API, KEY, APP (variables del script del teléfono).
const C = { fondo: new Color("#14171c"), caja: new Color("#1f242c"), txt: Color.white(), gris: new Color("#9aa4b2"), rojo: new Color("#ef4444"), ambar: new Color("#f59e0b"), azul: new Color("#60a5fa"), verde: new Color("#34d399") };
const dinero = n => "$" + Math.round(n || 0).toLocaleString("es-MX");
const corto = n => (n || 0) >= 1e6 ? "$" + ((n || 0) / 1e6).toFixed(1) + " M" : (n || 0) >= 1e4 ? "$" + Math.round((n || 0) / 1e3) + " k" : dinero(n);
const dia = iso => { const d = new Date(iso + "T12:00:00"); return ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"][d.getDay()] + " " + d.getDate(); };
const ir = h => APP.split("#")[0] + "#" + h;
const LOGO = APP.split("#")[0].replace(/[^/]*$/, "") + "assets/coe-logo.png";

async function datos() {
  const r = new Request(API);
  r.method = "POST";
  r.headers = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
  r.body = JSON.stringify({ p_token: TOKEN });
  return await r.loadJSON();
}
function caja(st, titulo, valor, sub, color, url) {
  const b = st.addStack(); b.layoutVertically(); b.backgroundColor = C.caja; b.cornerRadius = 10; b.setPadding(6, 8, 6, 8);
  if (url) b.url = url;
  const t = b.addText(titulo); t.font = Font.semiboldSystemFont(9); t.textColor = C.gris; t.lineLimit = 1; t.minimumScaleFactor = 0.7;
  const v = b.addText(valor); v.font = Font.boldSystemFont(16); v.textColor = color || C.txt; v.minimumScaleFactor = 0.5; v.lineLimit = 1;
  if (sub) { const s = b.addText(sub); s.font = Font.systemFont(9); s.textColor = C.gris; s.lineLimit = 1; s.minimumScaleFactor = 0.6; }
  b.addSpacer();
  return b;
}

const fam = config.widgetFamily || "large";
let d;
try { d = await datos(); } catch (e) { d = { ok: false, error: "sin_conexion" }; }
const w = new ListWidget();
w.backgroundColor = C.fondo; w.url = ir("prop"); w.setPadding(12, 13, 10, 13);
w.refreshAfterDate = new Date(Date.now() + 30 * 60 * 1000);

const h = w.addStack(); h.centerAlignContent();
try { const img = await new Request(LOGO).loadImage(); const i = h.addImage(img); i.imageSize = new Size(16, 16); i.tintColor = C.txt; h.addSpacer(5); } catch (e) {}
const ht = h.addText("COE Finanzas"); ht.font = Font.boldSystemFont(11); ht.textColor = C.gris;
h.addSpacer();
const hu = h.addText(d && d.ok ? "act. " + d.actualizado : ""); hu.font = Font.systemFont(9); hu.textColor = C.gris;
w.addSpacer(6);

if (!d || !d.ok) {
  const e = w.addText(d && d.error === "enlace_invalido" ? "Este widget fue desactivado. Genera uno nuevo en COE Finanzas › Widget." : "Sin conexión. Se actualiza solo en unos minutos.");
  e.font = Font.systemFont(12); e.textColor = C.txt;
} else if (fam === "small") {
  const a = w.addText("Vencido"); a.font = Font.semiboldSystemFont(10); a.textColor = C.gris;
  const av = w.addText(corto(d.vencido.m)); av.font = Font.boldSystemFont(22); av.textColor = d.vencido.n ? C.rojo : C.verde; av.minimumScaleFactor = 0.6;
  const an = w.addText(d.vencido.n + " cuenta(s)"); an.font = Font.systemFont(10); an.textColor = C.gris;
  w.addSpacer(5);
  const hh = w.addText("Hoy " + corto(d.hoy_pago ? d.hoy_pago.m : 0) + " · 7 d " + corto(d.semana.m)); hh.font = Font.semiboldSystemFont(10); hh.textColor = C.ambar; hh.minimumScaleFactor = 0.6;
  const p = w.addText((d.fps + d.complementos) + " por solicitar · " + d.pedidos + " por autorizar"); p.font = Font.systemFont(9); p.textColor = C.gris; p.minimumScaleFactor = 0.6;
} else {
  const r1 = w.addStack(); r1.spacing = 6;
  caja(r1, "VENCIDO", corto(d.vencido.m), d.vencido.n + " cuenta(s)", d.vencido.n ? C.rojo : C.verde, ir("prop"));
  caja(r1, "PAGAR HOY", corto(d.hoy_pago ? d.hoy_pago.m : 0), (d.hoy_pago ? d.hoy_pago.n : 0) + " pago(s)", (d.hoy_pago && d.hoy_pago.n) ? C.ambar : C.verde, ir("prop"));
  caja(r1, "PRÓX. 7 DÍAS", corto(d.semana.m), d.semana.n + " pago(s)" + (d.semana.variables ? " +" + d.semana.variables + " var." : ""), C.azul, ir("prop"));
  w.addSpacer(6);
  const r2 = w.addStack(); r2.spacing = 6;
  caja(r2, "POR SOLICITAR", String(d.fps + d.complementos), d.fps_vencidas ? d.fps_vencidas + " fuera de plazo" : d.complementos + " complemento(s)", (d.fps_vencidas ? C.rojo : (d.fps + d.complementos) ? C.ambar : C.verde), ir("fps"));
  caja(r2, "POR AUTORIZAR", String(d.pedidos), "pedido(s)", d.pedidos ? C.azul : C.verde, ir("ped"));
  caja(r2, "PENDIENTES", String(d.pendientes), "vencido(s)", d.pendientes ? C.rojo : C.verde, ir("tar"));
  if (fam === "large" || fam === "extraLarge") {
    w.addSpacer(9);
    const tt = w.addText("LO MÁS URGENTE"); tt.font = Font.semiboldSystemFont(9); tt.textColor = C.gris;
    w.addSpacer(3);
    const U = (d.urgentes || []).slice(0, 4);
    if (!U.length) { const n = w.addText("✓ Nada urgente"); n.font = Font.systemFont(12); n.textColor = C.verde; }
    for (const x of U) {
      const f = w.addStack(); f.centerAlignContent(); f.url = ir(x.u); f.backgroundColor = C.caja; f.cornerRadius = 8; f.setPadding(4, 8, 4, 8);
      const col = f.addStack(); col.layoutVertically();
      const m = col.addText(x.m); m.font = Font.semiboldSystemFont(9); m.textColor = /Pago|urgente/i.test(x.m) ? C.rojo : C.ambar; m.lineLimit = 1;
      const n = col.addText(x.n); n.font = Font.systemFont(11); n.textColor = C.txt; n.lineLimit = 1; n.minimumScaleFactor = 0.8;
      f.addSpacer();
      const a = f.addText("›"); a.font = Font.boldSystemFont(14); a.textColor = C.gris;
      w.addSpacer(3);
    }
    if (d.caja && d.caja.fecha) {
      w.addSpacer(4);
      const cj = w.addStack(); cj.url = ir("ingd"); cj.centerAlignContent();
      const c1 = cj.addText("Caja " + d.caja.fecha.slice(8, 10) + "/" + d.caja.fecha.slice(5, 7) + "  "); c1.font = Font.systemFont(10); c1.textColor = C.gris;
      const c2 = cj.addText(dinero(d.caja.total)); c2.font = Font.semiboldSystemFont(10); c2.textColor = C.verde;
      cj.addSpacer();
      const c3 = cj.addText("mes " + corto(d.caja.mes)); c3.font = Font.systemFont(10); c3.textColor = C.gris;
    }
  }
}
w.addSpacer();
if (config.runsInWidget) Script.setWidget(w); else if (fam === "small") await w.presentSmall(); else if (fam === "medium") await w.presentMedium(); else await w.presentLarge();
Script.complete();
