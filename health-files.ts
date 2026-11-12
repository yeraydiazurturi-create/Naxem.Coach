// NEXUM · Edge Function «health-files» (v65 · Salud)
// Gestiona los PDF del bucket PRIVADO «health». Despliegue: verify_jwt = false (autentica ella misma).
//   · Atleta  → { u, p }  (usuario y contraseña de atleta, igual que el resto de RPC)
//   · Entrenador → cabecera Authorization: Bearer <sesión de Supabase>; solo si el atleta es SUYO.
//   · El administrador (si no es el entrenador del atleta) y otros entrenadores NO tienen acceso.
// Acciones:
//   upload  (atleta)             → URL firmada de subida {path, token}  (PDF ≤ 10 MB)
//   url     (atleta | entrenador) → URL firmada de lectura de 120 s  { id }
//   delete  (atleta)             → borra fila y PDF { id }
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX = 10 * 1024 * 1024;
const BUCKET = "health";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return J({ error: "método no permitido" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return J({ error: "datos no válidos" }, 400); }
  const act = String(b?.action || "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- quién llama ----
  let cid: string | null = null;          // atleta autenticado por usuario/contraseña
  let uid: string | null = null;          // entrenador autenticado por sesión
  if (typeof b.u === "string" && typeof b.p === "string" && b.u && b.p) {
    const { data, error } = await sb.rpc("client_id_by_cred", { p_u: b.u, p_p: b.p });
    if (error || !data) return J({ error: "credenciales" }, 401);
    cid = String(data);
  } else {
    const tk = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (tk) {
      const { data } = await sb.auth.getUser(tk);
      uid = data?.user?.id || null;
    }
    if (!uid) return J({ error: "sin sesión" }, 401);
  }

  try {
    // ---------- upload ----------
    if (act === "upload") {
      if (!cid) return J({ error: "solo el atleta puede subir sus informes" }, 403);
      const size = Number(b.size || 0);
      if (!(size > 0) || size > MAX) return J({ error: "El PDF no puede superar 10 MB" }, 400);
      const { count } = await sb.from("health_docs").select("id", { count: "exact", head: true }).eq("client_id", cid);
      if ((count || 0) >= 100) return J({ error: "Has llegado al máximo de 100 informes" }, 400);
      const path = `${cid}/${crypto.randomUUID()}.pdf`;
      const { data, error } = await sb.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error || !data) return J({ error: "No se pudo preparar la subida" }, 500);
      return J({ path, token: data.token });
    }

    // ---------- url / delete: necesitan el documento ----------
    if (act === "url" || act === "delete") {
      const id = String(b.id || "");
      if (!UUID.test(id)) return J({ error: "documento no válido" }, 400);
      const { data: d } = await sb.from("health_docs").select("id,client_id,file_path,file_name").eq("id", id).maybeSingle();
      if (!d) return J({ error: "no encontrado" }, 404);
      let allowed = false;
      if (cid) allowed = d.client_id === cid;
      else if (uid && act === "url") {
        const { data: c } = await sb.from("clients").select("coach,coach_id").eq("id", d.client_id).maybeSingle();
        allowed = !!c && (c.coach === uid || c.coach_id === uid);
      }
      if (!allowed) return J({ error: "sin acceso" }, 403);

      if (act === "url") {
        if (!d.file_path) return J({ error: "este informe no tiene PDF" }, 404);
        const opt = b.dl ? { download: d.file_name || "informe.pdf" } : undefined;
        const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(d.file_path, 120, opt);
        if (error || !data) return J({ error: "No se pudo abrir el PDF" }, 500);
        return J({ url: data.signedUrl, name: d.file_name || "informe.pdf" });
      }
      // delete (solo atleta)
      if (d.file_path) await sb.storage.from(BUCKET).remove([d.file_path]);
      const { error } = await sb.from("health_docs").delete().eq("id", id);
      if (error) return J({ error: "No se pudo borrar" }, 500);
      return J({ ok: true });
    }
    return J({ error: "acción no válida" }, 400);
  } catch (_e) {
    return J({ error: "error interno" }, 500);
  }
});
