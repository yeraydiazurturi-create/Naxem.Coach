import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.14";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" } });
const esc = (v: unknown) => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\"/g, "&quot;");
const SITE = Deno.env.get("SITE_URL") || "https://getnaxem.netlify.app";

function shell(title: string, inner: string) {
  return `<!doctype html><html lang="es"><body style="margin:0;background:#0e0e0f;padding:24px 12px;font-family:Helvetica,Arial,sans-serif"><div style="max-width:520px;margin:0 auto"><div style="font:italic 30px Georgia,serif;color:#dcc7a1;margin:0 0 16px">Nexum</div><div style="background:#efeae0;border-radius:16px;padding:24px;color:#1a1a1c"><h1 style="font-size:20px;margin:0 0 12px">${esc(title)}</h1>${inner}</div><p style="font-size:11px;color:#8d877d;text-align:center;margin:16px 0 0">Recibes este correo porque tienes una cuenta en Nexum. Puedes desactivar los avisos y los resúmenes por correo en Cuenta › Notificaciones.</p></div></body></html>`;
}
const btn = (href: string, t: string) => `<p style="margin:20px 0 0"><a href="${esc(href)}" style="background:#86222f;color:#fff;text-decoration:none;padding:12px 20px;border-radius:10px;font-weight:600;display:inline-block">${esc(t)}</a></p>`;
const p = (t: string) => `<p style="font-size:15px;line-height:1.55;margin:0 0 10px">${t}</p>`;

function render(t: string, d: any): { subject: string; html: string; text: string } | null {
  if (t === "aviso") {
    const title = String(d.title || "Nexum").slice(0, 150);
    const paras = String(d.body || "").split(/\n+/).map((x) => x.trim()).filter(Boolean);
    const hi = d.name ? `Hola ${esc(d.name)},` : "Hola,";
    return { subject: title, text: `Hola${d.name ? " " + d.name : ""}: ${paras.join(" ")} ${SITE}`,
      html: shell(title, p(hi) + paras.map((x) => p(esc(x))).join("") + btn(SITE, String(d.cta || "Abrir Nexum").slice(0, 60))) };
  }
  if (t === "weekly") {
    const s = +d.sessions || 0, c = +d.checkins || 0;
    const msg = s >= 3 ? "Semana sólida. Mantén el ritmo." : s > 0 ? "Buen comienzo. Intenta sumar una sesión más esta semana." : "Esta semana no hay entrenos registrados. Empieza con una sesión corta hoy.";
    return { subject: "Tu resumen semanal en Nexum", text: `Hola ${d.name}: esta semana ${s} entrenos y ${c} check-ins. ${msg} ${SITE}`,
      html: shell("Tu semana", p(`Hola ${esc(d.name)},`) + `<table style="width:100%;border-collapse:collapse;margin:8px 0 14px"><tr><td style="padding:12px;background:#fff;border-radius:10px;text-align:center"><b style="font-size:28px;color:#86222f">${s}</b><br><span style="font-size:12px;color:#6f685e">entrenos hechos</span></td><td style="width:10px"></td><td style="padding:12px;background:#fff;border-radius:10px;text-align:center"><b style="font-size:28px;color:#86222f">${c}</b><br><span style="font-size:12px;color:#6f685e">check-ins</span></td></tr></table>` + p(esc(msg)) + btn(SITE, "Abrir Nexum")) };
  }
  if (t === "coach") {
    const names: string[] = Array.isArray(d.names) ? d.names : [];
    const risk = +d.risk || 0;
    return { subject: risk ? `${risk} atleta${risk > 1 ? "s" : ""} necesita${risk > 1 ? "n" : ""} atención` : "Tu resumen semanal de atletas", text: `Hola ${d.name}: ${d.total} atletas, ${risk} sin actividad en 3 días o más. ${names.join(", ")} ${SITE}`,
      html: shell("Tu equipo esta semana", p(`Hola ${esc(d.name)}, tienes <b>${+d.total || 0}</b> atletas activos.`) + (risk ? p(`<b>${risk}</b> llevan 3 días o más sin actividad:`) + `<ul style="margin:0 0 10px;padding-left:20px;font-size:15px;line-height:1.6">${names.slice(0, 15).map((n) => `<li>${esc(n)}</li>`).join("")}</ul>` + p("Un mensaje a tiempo es lo que más ayuda a que no abandonen.") : p("Todos están al día. Buen trabajo.")) + btn(SITE, "Abrir Nexum")) };
  }
  if (t === "acceso") {
    return { subject: "Tu acceso a Nexum", text: `Hola ${d.name}: entra en ${SITE} con usuario ${d.usr} y contraseña ${d.pwd}.`,
      html: shell("Tu acceso a Nexum", p(`Hola ${esc(d.name)}, tu entrenador te ha dado de alta.`) + `<div style="background:#fff;border-radius:10px;padding:14px;font-size:15px;line-height:1.7">Usuario: <b>${esc(d.usr)}</b><br>Contraseña: <b>${esc(d.pwd)}</b></div>` + p("<br>Entra desde el móvil y elige «Añadir a pantalla de inicio» para usarla como una app y recibir avisos.") + btn(SITE, "Entrar en Nexum")) };
  }
  if (t === "test") return { subject: "Prueba de correo de Nexum", text: "Los correos funcionan.", html: shell("Los correos funcionan", p("Este es un mensaje de prueba de Nexum.")) };
  return null;
}

async function deliver(to: string, subject: string, html: string, text: string) {
  const gu = Deno.env.get("GMAIL_USER"), gp = Deno.env.get("GMAIL_APP_PASSWORD"), rk = Deno.env.get("RESEND_API_KEY");
  if (gu && gp) {
    const tr = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gu, pass: gp.replace(/\s+/g, "") } });
    await tr.sendMail({ from: `Nexum <${gu}>`, to, subject, html, text });
    return;
  }
  if (rk) {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${rk}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: Deno.env.get("RESEND_FROM") || "Nexum <onboarding@resend.dev>", to: [to], subject, html, text }) });
    if (!r.ok) throw new Error("Resend " + r.status + " " + (await r.text()).slice(0, 200));
    return;
  }
  throw new Error("EMAIL_NO_CONFIGURADO");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return J({});
  if (req.method !== "POST") return J({ error: "POST" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return J({ error: "JSON no válido" }, 400); }
  const { data: cfg } = await db.from("push_cfg").select("v").eq("k", "secret").maybeSingle();
  const internal = !!cfg && req.headers.get("x-push-secret") === cfg.v;
  let uid: string | null = null;
  if (!internal) {
    const tk = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(tk);
    uid = u?.user?.id || null;
    if (!uid) return J({ error: "No autorizado" }, 401);
  }
  const items: any[] = Array.isArray(body.items) ? body.items : [body];
  const out: any[] = [];
  for (const it of items.slice(0, 200)) {
    try {
      let to = String(it.to || "").trim(), data = it.data || {}, tpl = it.template;
      if (!internal) {
        if (tpl === "test") { const { data: u } = await db.auth.admin.getUserById(uid!); to = u?.user?.email || ""; }
        else if (tpl === "acceso" && it.client_id) {
          const { data: c } = await db.from("clients").select("name,usr,pwd_plain,coach,data").eq("id", it.client_id).maybeSingle();
          if (!c || c.coach !== uid) throw new Error("No permitido");
          to = String(it.to || c.data?.prof?.email || "").trim();
          data = { name: c.name, usr: c.usr, pwd: c.pwd_plain || "(la que te dio tu entrenador)" };
        } else throw new Error("No permitido");
      }
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) throw new Error("Email no válido");
      const m = render(tpl, data);
      if (!m) throw new Error("Plantilla desconocida");
      await deliver(to, m.subject, m.html, m.text);
      out.push({ to, ok: true });
    } catch (e: any) { out.push({ ok: false, error: String(e?.message || e) }); }
  }
  const bad = out.find((o) => !o.ok);
  return J({ results: out, ok: !bad, error: bad?.error }, bad ? (bad.error === "EMAIL_NO_CONFIGURADO" ? 503 : 400) : 200);
});
