// Edge Function: create-checkout  (JWT: ACTIVADO · verify_jwt = true)
// Atletas: pago del plan de su entrenador (3/6/9 meses), portal de facturación, confirmación del pago y,
// desde la v63, suscripción Nexum Premium (atletas sin entrenador, mensual, IVA incluido).
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

async function stripe(path: string, params?: Record<string, string>, method = "POST") {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("Falta el secreto STRIPE_SECRET_KEY en Supabase");
  const r = await fetch("https://api.stripe.com/v1" + path, {
    method,
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/x-www-form-urlencoded" },
    body: method === "POST" ? new URLSearchParams(params || {}) : undefined,
  });
  const d = await r.json();
  if (!r.ok) throw new Error(d?.error?.message || "Stripe error");
  return d;
}

// v63 · Producto y precio mensual del Premium. Se crean la primera vez y se rehacen si cambia `premium_precio` en app_config.
async function premiumPrice(db: any): Promise<string> {
  const { data: rows } = await db.from("app_config").select("key,value")
    .in("key", ["premium_precio", "premium_product_id", "premium_price_id", "premium_price_cents"]);
  const cfg: Record<string, any> = Object.fromEntries((rows || []).map((r: any) => [r.key, r.value]));
  const cents = Math.round(Number(cfg.premium_precio ?? 9.95) * 100);
  if (!(cents >= 100 && cents <= 100000)) throw new Error("Precio Premium no válido");
  if (cfg.premium_price_id && Number(cfg.premium_price_cents) === cents) return String(cfg.premium_price_id);
  let product = cfg.premium_product_id ? String(cfg.premium_product_id) : "";
  if (!product) {
    const p = await stripe("/products", { name: "Nexum Premium", description: "Nexum sin entrenador: seguimiento completo y chat con otros atletas Premium" });
    product = p.id;
  }
  const pr = await stripe("/prices", {
    product, currency: "eur", unit_amount: String(cents), "recurring[interval]": "month",
    tax_behavior: "inclusive", nickname: "Nexum Premium mensual",
  });
  await db.from("app_config").upsert([
    { key: "premium_product_id", value: product },
    { key: "premium_price_id", value: pr.id },
    { key: "premium_price_cents", value: cents },
  ], { onConflict: "key" });
  return pr.id;
}

// Sesión de Stripe Checkout: incrustada (si el cliente la pide) o redirigida
async function checkout(base: Record<string, string>, embedded: boolean, site: string) {
  if (embedded) {
    const emb = {
      ...base,
      redirect_on_completion: "if_required",
      return_url: site + "/?pago=ok&session_id={CHECKOUT_SESSION_ID}",
    };
    let s;
    try {
      s = await stripe("/checkout/sessions", { ...emb, ui_mode: "embedded_page" });
    } catch (_e) {
      s = await stripe("/checkout/sessions", { ...emb, ui_mode: "embedded" });
    }
    return json({ client_secret: s.client_secret, id: s.id });
  }
  const s = await stripe("/checkout/sessions", {
    ...base,
    success_url: site + "/?pago=ok",
    cancel_url: site + "/?pago=cancelado",
  });
  return json({ url: s.url });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { usr, pwd, action, plan: body_plan, embedded } = await req.json();
    if (!usr || !pwd) return json({ error: "datos incompletos" }, 400);
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: cfgRow } = await db.from("app_config").select("value").eq("key", "comision").maybeSingle();
    const feeCfg = Number(cfgRow?.value ?? 20);
    const feePct = isFinite(feeCfg) && feeCfg >= 0 && feeCfg <= 50 ? feeCfg : 20;

    const { data: cid } = await db.rpc("client_id_by_cred", { p_u: String(usr), p_p: String(pwd) });
    const { data: cl } = cid ? await db.from("clients").select("*").eq("id", cid).maybeSingle() : { data: null };
    if (!cl) return json({ error: "credenciales" }, 401);

    const site = Deno.env.get("SITE_URL") || req.headers.get("origin") || "";
    if (!site) return json({ error: "Falta el secreto SITE_URL en Supabase" }, 500);

    if (action === "portal") {
      if (!cl.stripe_customer_id) return json({ error: "sin suscripción" }, 400);
      const p = await stripe("/billing_portal/sessions", { customer: cl.stripe_customer_id, return_url: site });
      return json({ url: p.url });
    }

    if (action === "confirm") {
      const list = await stripe("/checkout/sessions?limit=30", undefined, "GET");
      const mine = (list.data || [])
        .filter((x: any) => x.metadata?.client_id === String(cl.id) && x.status === "complete" && x.mode === "subscription" &&
          (x.payment_status === "paid" || (x.metadata?.premium === "1" && x.payment_status === "no_payment_required")))
        .sort((a: any, b: any) => b.created - a.created)[0];
      if (!mine) return json({ paid: false });

      // v63 · Premium
      if (mine.metadata?.premium === "1") {
        if (cl.coach_id || cl.coach) return json({ paid: false });
        let until = new Date(Date.now() + 31 * 864e5);
        try {
          const sub = await stripe("/subscriptions/" + mine.subscription, undefined, "GET");
          if (!["active", "trialing"].includes(sub.status)) return json({ paid: false });
          const end = sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end;
          if (end) until = new Date(end * 1000);
        } catch (_e) { /* se queda con 31 días */ }
        await db.from("clients").update({
          pago_estado: "pagado", pagado_hasta: until.toISOString(),
          stripe_customer_id: mine.customer, stripe_subscription_id: mine.subscription,
          premium: true, premium_sub_id: mine.subscription,
        }).eq("id", cl.id);
        try {
          const invId = typeof mine.invoice === "string" ? mine.invoice : mine.invoice?.id;
          if (invId && mine.amount_total > 0) {
            await db.rpc("record_premium_invoice", { p_stripe_invoice: invId, p_client: cl.id, p_total_cents: mine.amount_total,
              p_tax_cents: mine.total_details?.amount_tax ?? 0, p_paid_at: new Date(mine.created * 1000).toISOString() });
          }
        } catch (_e) { /* no bloquea el acceso */ }
        return json({ paid: true, premium: true });
      }

      const plan = Number(mine.metadata?.plan_meses);
      let until = new Date(Date.now() + 31 * 864e5);
      try {
        const sub = await stripe("/subscriptions/" + mine.subscription, undefined, "GET");
        const end = sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end;
        if (end) until = new Date(end * 1000);
        if ([3, 6, 9].includes(plan) && !sub.cancel_at && sub.status !== "canceled") {
          const stop = new Date(sub.start_date ? sub.start_date * 1000 : Date.now());
          stop.setMonth(stop.getMonth() + plan);
          await stripe("/subscriptions/" + mine.subscription, { cancel_at: String(Math.floor(stop.getTime() / 1000)) });
        }
      } catch (_e) { /* se queda con 31 días */ }
      await db.from("clients").update({
        pago_estado: "pagado", pagado_hasta: until.toISOString(),
        stripe_customer_id: mine.customer, stripe_subscription_id: mine.subscription,
        ...([3, 6, 9].includes(plan) ? { plan_meses: plan } : {}),
      }).eq("id", cl.id);
      // Factura de la mensualidad (idempotente: no se duplica si el webhook ya la creó)
      try {
        const invId = typeof mine.invoice === "string" ? mine.invoice : mine.invoice?.id;
        if (invId && mine.amount_total > 0) {
          await db.rpc("record_invoice", { p_stripe_invoice: invId, p_client: cl.id, p_total_cents: mine.amount_total,
            p_paid_at: new Date(mine.created * 1000).toISOString() });
        }
      } catch (_e) { /* no bloquea el acceso */ }
      return json({ paid: true });
    }

    // v63 · Suscripción Nexum Premium (solo atletas sin entrenador)
    if (action === "premium") {
      if (cl.coach_id || cl.coach) return json({ error: "Ya tienes entrenador" }, 409);
      if (cl.suspendido) return json({ error: "Cuenta suspendida" }, 403);
      // Si ya tiene una suscripción Premium viva, se gestiona desde el portal (cambiar tarjeta, cancelar…)
      if (cl.premium_sub_id && cl.stripe_customer_id) {
        try {
          const sub = await stripe("/subscriptions/" + cl.premium_sub_id, undefined, "GET");
          if (["active", "trialing", "past_due", "unpaid"].includes(sub.status)) {
            const p = await stripe("/billing_portal/sessions", { customer: cl.stripe_customer_id, return_url: site });
            return json({ url: p.url, portal: true });
          }
        } catch (_e) { /* la suscripción ya no existe: se crea otra */ }
      }
      // v66 · Nexum no cobra Premium hasta que el administrador activa «cobro_premium» (alta de autónomo + datos fiscales) …
      const { data: cpRow } = await db.from("app_config").select("value").eq("key", "cobro_premium").maybeSingle();
      if (cpRow?.value !== true) return json({ error: "Premium todavía no está disponible. Mientras tanto puedes seguir usando Nexum sin coste.", code: "COBRO_OFF" }, 409);
      // … y solo tras aceptar las condiciones de Premium (desistimiento de 14 días y servicio inmediato)
      const { data: lv } = await db.rpc("nx_legal_version");
      const { data: acc } = await db.from("legal_acceptances").select("id").eq("subject_kind", "client").eq("subject_id", cl.id)
        .eq("doc", "premium").eq("version", String(lv)).maybeSingle();
      if (!acc) return json({ error: "Antes de contratar Premium acepta las condiciones (servicio inmediato y desistimiento).", code: "LEGAL" }, 409);
      const price = await premiumPrice(db);
      const email = String(cl.data?.prof?.email || "").trim();
      const base: Record<string, string> = {
        mode: "subscription",
        "line_items[0][price]": price,
        "line_items[0][quantity]": "1",
        "subscription_data[metadata][client_id]": String(cl.id),
        "subscription_data[metadata][premium]": "1",
        "metadata[client_id]": String(cl.id),
        "metadata[premium]": "1",
        client_reference_id: String(cl.id),
        allow_promotion_codes: "true",
        locale: "es",
        ...(cl.stripe_customer_id ? { customer: cl.stripe_customer_id }
          : (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? { customer_email: email } : {})),
      };
      return await checkout(base, !!embedded, site);
    }

    const plan = Number(body_plan);
    if (![3, 6, 9].includes(plan)) return json({ error: "Elige un plan de 3, 6 o 9 meses" }, 400);
    const { data: co } = await db.from("coaches").select("*").eq("id", cl.coach_id).maybeSingle();
    const direct = !!co?.cobra_directo;
    if (!co || (!direct && (!co.stripe_account_id || !co.stripe_charges_enabled)))
      return json({ error: "El entrenador aún no ha activado los cobros" }, 409);
    const cents = Math.round(Number(co["precio_" + plan]) * 100);
    if (!(cents >= 100)) return json({ error: "precio no válido" }, 409);

    const base: Record<string, string> = {
      mode: "subscription",
      "line_items[0][quantity]": "1",
      "line_items[0][price_data][currency]": "eur",
      "line_items[0][price_data][unit_amount]": String(cents),
      "line_items[0][price_data][recurring][interval]": "month",
      "line_items[0][price_data][product_data][name]":
        `Plan de ${plan} meses con ` + (`${co.nombre || ""} ${co.apellidos || ""}`.trim() || co.empresa_nombre),
      "subscription_data[metadata][client_id]": String(cl.id),
      "subscription_data[metadata][plan_meses]": String(plan),
      "metadata[client_id]": String(cl.id),
      "metadata[plan_meses]": String(plan),
      client_reference_id: String(cl.id),
      ...(direct ? {} : {
        "subscription_data[application_fee_percent]": String(feePct),
        "subscription_data[transfer_data][destination]": co.stripe_account_id,
      }),
      ...(cl.stripe_customer_id ? { customer: cl.stripe_customer_id } : {}),
    };
    return await checkout(base, !!embedded, site);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
