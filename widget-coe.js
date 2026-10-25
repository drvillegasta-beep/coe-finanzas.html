// COE Finanzas · diseño del widget de iPhone (Scriptable).
// Lo descarga el script corto del teléfono; así los cambios de diseño llegan sin volver a copiar nada.
// Recibe: TOKEN, API, KEY, APP (variables del script del teléfono).
const C = { fondo: new Color("#14171c"), caja: new Color("#1f242c"), txt: Color.white(), gris: new Color("#9aa4b2"), rojo: new Color("#ef4444"), ambar: new Color("#f59e0b"), azul: new Color("#60a5fa"), verde: new Color("#34d399") };
const dinero = n => "$" + Math.round(n || 0).toLocaleString("es-MX");
const corto = n => (n || 0) >= 1e6 ? "$" + ((n || 0) / 1e6).toFixed(1) + " M" : (n || 0) >= 1e4 ? "$" + Math.round((n || 0) / 1e3) + " k" : dinero(n);
const dm = iso => iso ? iso.slice(8, 10) + "/" + iso.slice(5, 7) : "";
const BASE = APP.split("#")[0];
const ir = h => BASE + "#" + h;
const LOGO = BASE.replace(/[^/]*$/, "") + "assets/coe-logo.png";
const APPS = {
  fin: BASE + "#prop",
  con: "https://drvillegasta-beep.github.io/coe-conciliacion.html/coe-conciliacion.html",
  qui: "https://drvillegasta-beep.github.io/coe-quirofano/quirofano-v2.html",
  far: "https://drvillegasta-beep.github.io/coe-quirofano/farmacia.html",
  opt: "https://drvillegasta-beep.github.io/coe-conciliacion.html/coe-optica.html"
};
const NIV = { r: C.rojo, a: C.ambar, v: C.verde };

async function datos() {
  const r = new Request(API);
  r.method = "POST";
  r.headers = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
  r.body = JSON.stringify({ p_token: TOKEN });
  return await r.loadJSON();
}
// Cuadro de pagos: título · monto · rango de fechas de pago
function cuadro(st, titulo, monto, sub, color, url) {
  const b = st.addStack(); b.layoutVertically(); b.backgroundColor = C.caja; b.cornerRadius = 10; b.setPadding(5, 8, 5, 8);
  if (url) b.url = url;
  const t = b.addText(titulo); t.font = Font.semiboldSystemFont(9); t.textColor = C.gris; t.lineLimit = 1; t.minimumScaleFactor = 0.7;
  const v = b.addText(monto); v.font = Font.boldSystemFont(16); v.textColor = color; v.lineLimit = 1; v.minimumScaleFactor = 0.5;
  if (sub) { const s = b.addText(sub); s.font = Font.systemFont(9); s.textColor = C.gris; s.lineLimit = 1; s.minimumScaleFactor = 0.6; }
  return b;
}
const rango = s => !s || !s.n ? "sin pagos · " + dm(s && s.desde) + "–" + dm(s && s.hasta) : s.n + " pago(s) · " + (s.primero === s.ultimo ? dm(s.primero) : dm(s.primero) + "–" + dm(s.ultimo)) + (s.var ? " · +" + s.var + " var." : "");

const fam = config.widgetFamily || "large";
let d;
try { d = await datos(); } catch (e) { d = { ok: false, error: "sin_conexion" }; }
const w = new ListWidget();
w.backgroundColor = C.fondo; w.url = ir("prop"); w.setPadding(11, 12, 10, 12);
w.refreshAfterDate = new Date(Date.now() + 30 * 60 * 1000);

const h = w.addStack(); h.centerAlignContent();
try { const img = await new Request(LOGO).loadImage(); const i = h.addImage(img); i.imageSize = new Size(15, 15); i.tintColor = C.txt; h.addSpacer(5); } catch (e) {}
const ht = h.addText("COE Finanzas"); ht.font = Font.boldSystemFont(11); ht.textColor = C.gris;
h.addSpacer();
const hu = h.addText(d && d.ok ? "act. " + d.actualizado : ""); hu.font = Font.systemFont(9); hu.textColor = C.gris;
w.addSpacer(6);

if (!d || !d.ok) {
  const e = w.addText(d && d.error === "enlace_invalido" ? "Este widget fue desactivado. Genera uno nuevo en COE Finanzas › Widget." : "Sin conexión. Se actualiza solo en unos minutos.");
  e.font = Font.systemFont(12); e.textColor = C.txt;
} else if (fam === "small") {
  cuadro(w, "VENCIDO", corto(d.vencido.m), d.vencido.n + " cuenta(s)", d.vencido.n ? C.rojo : C.verde, ir("prop"));
  w.addSpacer(5);
  cuadro(w, "ESTA SEMANA", corto(d.sem1 ? d.sem1.m : 0), rango(d.sem1), C.ambar, ir("prop"));
} else if (fam === "medium") {
  const r1 = w.addStack(); r1.spacing = 6;
  cuadro(r1, "VENCIDO", corto(d.vencido.m), d.vencido.n + " cuenta(s)", d.vencido.n ? C.rojo : C.verde, ir("prop"));
  cuadro(r1, "ESTA SEMANA", corto(d.sem1.m), rango(d.sem1), C.ambar, ir("prop"));
  cuadro(r1, "PRÓXIMA SEMANA", corto(d.sem2.m), rango(d.sem2), C.azul, ir("prop"));
  w.addSpacer(6);
  const c = w.addStack(); c.url = ir("tar"); c.centerAlignContent(); c.backgroundColor = C.caja; c.cornerRadius = 8; c.setPadding(5, 8, 5, 8);
  const c1 = c.addText("Contadora: " + d.conta.n + " pendiente(s)"); c1.font = Font.semiboldSystemFont(11); c1.textColor = C.txt;
  c.addSpacer();
  const c2 = c.addText(d.conta.vencidos + " vencido(s)"); c2.font = Font.boldSystemFont(11); c2.textColor = d.conta.vencidos ? C.rojo : C.verde;
} else {
  // Arriba: a la izquierda los 3 cuadros de pagos; a la derecha la lista de pendientes de la Contadora
  const top = w.addStack(); top.spacing = 6;
  const izq = top.addStack(); izq.layoutVertically(); izq.spacing = 5; izq.size = new Size(150, 0);
  cuadro(izq, "VENCIDO", dinero(d.vencido.m), d.vencido.n + " cuenta(s) sin pagar", d.vencido.n ? C.rojo : C.verde, ir("prop"));
  cuadro(izq, "ESTA SEMANA", dinero(d.sem1.m), rango(d.sem1), C.ambar, ir("prop"));
  cuadro(izq, "PRÓXIMA SEMANA", dinero(d.sem2.m), rango(d.sem2), C.azul, ir("prop"));
  const der = top.addStack(); der.layoutVertically(); der.backgroundColor = C.caja; der.cornerRadius = 10; der.setPadding(6, 8, 6, 8); der.url = ir("tar");
  const ct = der.addStack(); ct.centerAlignContent();
  const ctt = ct.addText("CONTADORA"); ctt.font = Font.semiboldSystemFont(9); ctt.textColor = C.gris;
  ct.addSpacer();
  const ctn = ct.addText(d.conta.vencidos + "/" + d.conta.n); ctn.font = Font.boldSystemFont(10); ctn.textColor = d.conta.vencidos ? C.rojo : C.verde;
  const cs = der.addText(d.conta.vencidos + " vencido(s) de " + d.conta.n); cs.font = Font.systemFont(8); cs.textColor = C.gris;
  der.addSpacer(4);
  if (!d.conta.lista.length) { const z = der.addText("✓ Al corriente"); z.font = Font.systemFont(11); z.textColor = C.verde; }
  for (const x of d.conta.lista) {
    const it = der.addStack(); it.layoutVertically(); it.url = ir(x.u);
    const a = it.addText((x.d > 0 ? "vencido hace " + x.d + " d" : x.d === 0 ? "vence hoy" : "en " + (-x.d) + " d") + (x.c ? " · crítico" : "")); a.font = Font.semiboldSystemFont(8); a.textColor = x.d > 0 ? C.rojo : C.ambar;
    const b = it.addText(x.t); b.font = Font.systemFont(10); b.textColor = C.txt; b.lineLimit = 2; b.minimumScaleFactor = 0.8;
    der.addSpacer(4);
  }
  der.addSpacer();
  // Abajo: lo urgente de cada aplicación
  w.addSpacer(8);
  const tt = w.addText("LO URGENTE POR APLICACIÓN"); tt.font = Font.semiboldSystemFont(9); tt.textColor = C.gris;
  w.addSpacer(3);
  for (const x of (d.apps || [])) {
    const f = w.addStack(); f.centerAlignContent(); f.url = APPS[x.k] || ir("dash"); f.backgroundColor = C.caja; f.cornerRadius = 8; f.setPadding(4, 8, 4, 8);
    const dot = f.addText("●"); dot.font = Font.systemFont(9); dot.textColor = NIV[x.nivel] || C.gris;
    f.addSpacer(5);
    const n = f.addText(x.app); n.font = Font.semiboldSystemFont(11); n.textColor = C.txt; n.lineLimit = 1;
    f.addSpacer(6);
    const t = f.addText(x.txt); t.font = Font.systemFont(10); t.textColor = x.nivel === "v" ? C.gris : C.txt; t.lineLimit = 1; t.minimumScaleFactor = 0.6;
    f.addSpacer();
    w.addSpacer(3);
  }
}
w.addSpacer();
if (config.runsInWidget) Script.setWidget(w); else if (fam === "small") await w.presentSmall(); else if (fam === "medium") await w.presentMedium(); else await w.presentLarge();
Script.complete();
