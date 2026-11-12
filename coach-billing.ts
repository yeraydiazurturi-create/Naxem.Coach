// Edge Function: coach-billing  (JWT: activado)  ·  v2 (tramos por nº de clientes)
// El ENTRENADOR paga su plan de Nexum con una suscripción de Stripe.
// Planes: Inicio (hasta 10 clientes) · Crece (hasta 20) · Pro (21 o más), cada uno mensual o anual. Se editan en Administración (config `coach_tiers`).
// acciones:
//   "checkout" → empezar la suscripción (la prueba gratuita se respeta; con un código del 100 % sin fin no se cobra nada)
//   "change"   → cambiar de tramo o de periodo con la suscripción ya en marcha (prorrateo de Stripe)
//   "portal"   → gestionar tarjeta, facturas y cancelación
// El precio sale SIEMPRE de la base de datos (config coach_tiers), nunca del navegador.
// Antes de cobrar se exige: cobros activados por el administrador, términos aceptados (versión vigente), datos de facturación del entrenador
// (NIF válido, nombre y dirección) y que el nº de clientes quepa en el tramo.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (error: string, code: string, s = 409) => json({ error, code }, s);

// ---------- lógica pura (se prueba aparte) ----------
export type Tier = { key: string; nombre: string; max: number | null; mensual: number; anual?: number | null };

/** Precio del periodo (sin IVA). Anual = precio anual del tramo, o 10 mensualidades si no está definido. */
export function tierPrice(t: Tier, anual: boolean): number {
  if (!anual) return Number(t.mensual);
  const a = Number(t.anual);
  return a > 0 ? a : Math.round(Number(t.mensual) * 10 * 100) / 100;
}
export const centsOf = (eur: number) => Math.round(eur * 100);
/** Coste mensual equivalente (para saber si un cambio es subida o bajada). */
export const perMonth = (t: Tier, anual: boolean) => tierPrice(t, anual) / (anual ? 12 : 1);
/** Prorrateo: probando no se cobra nada; si cambia de periodo o sube de precio se factura ya; si baja, crédito para la próxima factura. */
export function prorationFor(status: string, interval: "month" | "year", prevInterval: string, up: boolean): string {
  if (status === "trialing") return "none";
  if (interval !== prevInterval) return "always_invoice";
  return up ? "always_invoice" : "create_prorations";
}
/** Descuento del código del entrenador adaptado al periodo. En anual, «N meses» se convierte en un único descuento proporcional. */
export function couponFor(pct: number, months: number, interval: "month" | "year"):
  { percent_off: number; duration: "forever" | "once" | "repeating"; duration_in_months?: number } {
  const p = Math.max(0, Math.min(100, pct));
  if (!months) return { percent_off: p, duration: "forever" };
  if (interval === "year") return { percent_off: Math.round(p * Math.min(months, 12) / 12 * 100) / 100, duration: "once" };
  return { percent_off: p, duration: "repeating", duration_in_months: months };
}
export function limiteOk(tier: Tier, clientes: number): boolean {
  return tier.max == null || clientes <= tier.max;
}
// ----------------------------------------------------

async function stripe(path: string, params?: Record<string, string>, method = "POST") {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("Falta el secreto STRIPE_SECRET_KEY en Supabase");
  const r = await fetch("https://api.stripe.com/v1" + path, {
    method,
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/x-www-form-urlencoded" },
    body: method === "POST" ? new URLSearchParams(params || {}) : undefined,
  });
  const d = await r.json();
  if (!r.ok) throw new Error((d && d.error && d.error.message) || "Stripe error");
  return d;
}

// Tipo de IVA fijo (no incluido en el precio). Se crea una vez y se reutiliza.
async function taxRate(pct: number): Promise<string> {
  const l = await stripe("/tax_rates?active=true&limit=100", undefined, "GET");
  const f = (l.data || []).find((t: any) => Number(t.percentage) === pct && !t.inclusive && t.metadata && t.metadata.nexum === "iva");
  if (f) return f.id;
  const c = await stripe("/tax_rates", {
    display_name: "IVA", percentage: String(pct), inclusive: "false", country: "ES", "metadata[nexum]": "iva",
  });
  return c.id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const token = (req.headers.get("authorization") || "").replace(/^Bearer /i, "");
    const { data: u } = await db.auth.getUser(token);
    if (!u || !u.user) return json({ error: "no autenticado" }, 401);
    const body = await req.json().catch(() => ({}));
    const action = body.action;
    const site = Deno.env.get("SITE_URL") || req.headers.get("origin") || "";
    if (!site) return json({ error: "Falta el secreto SITE_URL en Supabase" }, 500);

    const { data: co } = await db.from("coaches").select("*").eq("id", u.user.id).maybeSingle();
    if (!co) return json({ error: "No eres entrenador" }, 403);

    if (action === "portal") {
      if (!co.stripe_customer_id) return json({ error: "Aún no tienes una suscripción" }, 400);
      const p = await stripe("/billing_portal/sessions", { customer: co.stripe_customer_id, return_url: site });
      return json({ url: p.url });
    }

    if (action !== "checkout" && action !== "change") return json({ error: "acción desconocida" }, 400);

    // ---- Comprobaciones comunes (legal y fiscal) ----
    const { data: cfgRows } = await db.from("app_config").select("key,value").in("key", ["nexum_iva", "cobro_entrenadores"]);
    const cfg: Record<string, any> = {};
    for (const r of cfgRows || []) cfg[r.key] = r.value;
    const ivaN = Number(cfg.nexum_iva);
    const iva = cfg.nexum_iva != null && isFinite(ivaN) ? ivaN : 21;

    // En un cambio de plan el entrenador elige tramo y periodo; en checkout se usa el que ya guardó con coach_set_plan
    const planKey: string = action === "change" ? String(body.plan || "") : String(co.plan || "");
    const anual: boolean = action === "change" ? body.per === "anual" : Number(co.plan_meses) === 12;
    if (!planKey) return fail("Elige primero tu plan", "SIN_PLAN");
    const { data: tier } = await db.rpc("nx_tier", { p_key: planKey });
    if (!tier) return fail("Plan no válido", "PLAN_INVALIDO", 400);
    const t = tier as Tier;

    const { count: nCl } = await db.from("clients").select("id", { count: "exact", head: true }).or(`coach.eq.${co.id},coach_id.eq.${co.id}`);
    if (!limiteOk(t, nCl || 0)) {
      return fail(`Tienes ${nCl} clientes y el plan ${t.nombre} admite hasta ${t.max}. Elige un plan mayor.`, "LIMITE_PLAN");
    }

    // Código del 100 % sin fin: no hay nada que cobrar
    const pct = Math.max(0, Math.min(100, Number(co.promo_pct) || 0));
    const pm = Number(co.promo_meses) || 0;
    if (action === "checkout" && pct >= 100 && !pm) {
      await db.from("coaches").update({ sub_estado: "gratis" }).eq("id", co.id);
      return json({ free: true });
    }

    if (cfg.cobro_entrenadores !== true) {
      return fail("Los cobros de planes aún no están activados. Puedes seguir usando Nexum durante tu prueba.", "COBRO_OFF");
    }

    const { data: lv } = await db.rpc("nx_legal_version");
    const { data: acc } = await db.from("legal_acceptances").select("id").eq("subject_kind", "coach").eq("subject_id", co.id)
      .eq("doc", "terminos").eq("version", String(lv)).maybeSingle();
    if (!acc) return fail("Antes de pagar acepta las condiciones del servicio y la política de privacidad.", "LEGAL");

    const { data: nifOk } = await db.rpc("nx_nif_ok", { p: co.nif || "" });
    const nombreFact = (co.empresa_nombre || ((co.nombre || "") + " " + (co.apellidos || ""))).trim();
    const dirFact = co.direccion || co.empresa_localidad || "";
    if (!nifOk || !nombreFact || !dirFact) {
      return fail("Para emitirte la factura necesitamos tu NIF válido, tu nombre o empresa y tu dirección. Complétalos en «Datos de cobro».", "DATOS_FACTURA");
    }

    const interval: "month" | "year" = anual ? "year" : "month";
    const cents = centsOf(tierPrice(t, anual));
    const etiqueta = "Nexum · plan " + t.nombre + (anual ? " (anual)" : " (mensual)");
    const taxId = iva > 0 ? await taxRate(iva) : "";

    // ---- Cambiar de plan con la suscripción en marcha ----
    if (action === "change") {
      if (!co.stripe_subscription_id) return fail("Todavía no tienes una suscripción: empieza con «Activar plan».", "SIN_SUB");
      if (co.sub_estado === "past_due") return fail("Primero actualiza tu método de pago desde «Gestionar suscripción».", "PAGO_PENDIENTE");
      const sub = await stripe("/subscriptions/" + co.stripe_subscription_id, undefined, "GET");
      if (!["active", "trialing"].includes(sub.status)) return fail("Tu suscripción no está activa.", "SIN_SUB");
      const item = sub.items?.data?.[0];
      if (!item) return fail("No se encontró tu suscripción.", "SIN_SUB", 500);
      const prevInterval: string = item.price?.recurring?.interval || "month";
      const { data: prevTier } = await db.rpc("nx_tier", { p_key: co.plan || "" });
      const prevPm = prevTier ? perMonth(prevTier as Tier, prevInterval === "year") : 0;
      const up = perMonth(t, anual) > prevPm;
      const prorr = prorationFor(sub.status, interval, prevInterval, up);
      const upd: Record<string, string> = {
        "items[0][id]": item.id,
        "items[0][price_data][currency]": "eur",
        "items[0][price_data][product]": typeof item.price.product === "string" ? item.price.product : item.price.product.id,
        "items[0][price_data][unit_amount]": String(cents),
        "items[0][price_data][recurring][interval]": interval,
        proration_behavior: prorr,
        "metadata[plan]": planKey,
        "metadata[coach_id]": String(co.id),
      };
      if (taxId) upd["items[0][tax_rates][0]"] = taxId;
      await stripe("/subscriptions/" + co.stripe_subscription_id, upd);
      await db.from("coaches").update({
        plan: planKey, plan_precio: tierPrice(t, anual), plan_meses: anual ? 12 : 1, plan_desde: new Date().toISOString().slice(0, 10),
      }).eq("id", co.id);
      return json({ ok: true, plan: planKey, anual, proration: prorr });
    }

    // ---- Empezar la suscripción ----
    if (co.sub_estado === "active" || co.sub_estado === "trialing") return fail("Ya tienes una suscripción en marcha. Usa «Cambiar de plan».", "YA_SUB");
    await db.from("coaches").update({ plan_precio: tierPrice(t, anual) }).eq("id", co.id); // por si el administrador cambió el precio después de elegir

    const p: Record<string, string> = {
      mode: "subscription",
      locale: "es",
      "line_items[0][quantity]": "1",
      "line_items[0][price_data][currency]": "eur",
      "line_items[0][price_data][unit_amount]": String(cents),
      "line_items[0][price_data][recurring][interval]": interval,
      "line_items[0][price_data][product_data][name]": etiqueta,
      "subscription_data[metadata][coach_id]": String(co.id),
      "subscription_data[metadata][plan]": planKey,
      "subscription_data[metadata][periodo]": interval,
      "metadata[coach_id]": String(co.id),
      "metadata[plan]": planKey,
      success_url: site + "/?plan=ok",
      cancel_url: site + "/?plan=cancelado",
    };
    if (taxId) p["line_items[0][tax_rates][0]"] = taxId;
    if (co.stripe_customer_id) p.customer = co.stripe_customer_id;
    else if (co.email) p.customer_email = co.email;

    // Si todavía le quedan días de prueba, no se cobra hasta que acaben.
    // Stripe exige que el fin de la prueba esté al menos 48 horas en el futuro.
    const now = Math.floor(Date.now() / 1000);
    const te = co.prueba_hasta ? Math.floor(new Date(co.prueba_hasta).getTime() / 1000) : 0;
    if (te > now) p["subscription_data[trial_end]"] = String(Math.max(te, now + 50 * 3600));

    // Código de descuento del entrenador (sin meses = siempre; con meses, durante esos meses o su equivalente en el plan anual)
    if (pct > 0) {
      const c = couponFor(pct, pm, interval);
      const cp: Record<string, string> = {
        percent_off: String(c.percent_off), duration: c.duration,
        name: "Código " + (co.promo_code || ""), "metadata[coach_id]": String(co.id),
      };
      if (c.duration_in_months) cp.duration_in_months = String(c.duration_in_months);
      const made = await stripe("/coupons", cp);
      p["discounts[0][coupon]"] = made.id;
    }

    const s = await stripe("/checkout/sessions", p);
    return json({ url: s.url });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
