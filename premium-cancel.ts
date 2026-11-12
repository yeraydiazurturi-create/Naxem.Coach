// Edge Function: premium-cancel  (JWT: DESACTIVADO · verify_jwt = false; se autentica con el secreto interno x-push-secret)
// La base de datos la llama cuando a un atleta Premium se le asigna entrenador: cancela su suscripción Premium en Stripe.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return J({ error: "POST" }, 405);
  const { data: cfg } = await db.from("push_cfg").select("v").eq("k", "secret").maybeSingle();
  if (!cfg || req.headers.get("x-push-secret") !== cfg.v) return J({ error: "No autorizado" }, 401);
  let body: any;
  try { body = await req.json(); } catch { return J({ error: "JSON no válido" }, 400); }
  const sub = String(body?.sub || "");
  if (!/^sub_[A-Za-z0-9]+$/.test(sub)) return J({ error: "Suscripción no válida" }, 400);
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) return J({ error: "Falta STRIPE_SECRET_KEY" }, 500);
  // Solo se cancelan suscripciones Premium: nunca la de un plan de entrenador
  const g = await fetch("https://api.stripe.com/v1/subscriptions/" + sub, { headers: { Authorization: "Bearer " + key } });
  if (g.status === 404) return J({ ok: true, ya: true });
  const s = await g.json();
  if (!g.ok) return J({ error: s?.error?.message || "Stripe error" }, 502);
  if (s.metadata?.premium !== "1") return J({ error: "No es una suscripción Premium" }, 409);
  if (s.status === "canceled") return J({ ok: true, ya: true });
  const r = await fetch("https://api.stripe.com/v1/subscriptions/" + sub, { method: "DELETE", headers: { Authorization: "Bearer " + key } });
  if (!r.ok) return J({ error: (await r.json())?.error?.message || "Stripe error" }, 502);
  return J({ ok: true });
});
