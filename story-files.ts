// NEXUM · Edge Function «story-files» (v67 · Stories)
// Archivos del bucket PRIVADO «stories». Despliegue: verify_jwt = false (autentica ella misma).
//   · Atleta      → { u, p }  (usuario y contraseña de atleta)
//   · Entrenador / administrador → cabecera Authorization: Bearer <sesión de Supabase>
// Acciones:
//   upload { ext, size }  → URL firmada de subida { path, token }. Solo si la persona puede publicar.
//   urls   { ids }        → URLs firmadas de lectura (1 h) SOLO de las stories que esa persona puede ver.
//   purge                 → borra del almacenamiento lo caducado, lo borrado y los archivos huérfanos (lo llama el cron cada hora; es idempotente).
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUCKET = "stories";
const EXT = new Set(["jpg", "webp", "png", "mp4", "webm", "mov"]);
const MAX_IMG = 6 * 1024 * 1024;
const MAX_VID = 25 * 1024 * 1024;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return J({ error: "método no permitido" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return J({ error: "datos no válidos" }, 400); }
  const act = String(b?.action || "");
  const url = Deno.env.get("SUPABASE_URL")!;
  const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    // ---------- purge: sin autenticación; solo toca lo que ya caducó o se borró ----------
    if (act === "purge") {
      const { data: rows } = await svc.from("stories").select("id,path")
        .not("path", "is", null)
        .or(`deleted_at.not.is.null,expires_at.lt.${new Date(Date.now() - 30 * 60 * 1000).toISOString()}`)
        .limit(200);
      const list = rows || [];
      if (list.length) {
        await svc.storage.from(BUCKET).remove(list.map((r: any) => r.path));
        await svc.from("stories").update({ path: null, purged_at: new Date().toISOString() }).in("id", list.map((r: any) => r.id));
      }
      // archivos subidos que nunca llegaron a publicarse (más de 1 día y sin fila en «stories»)
      const { data: orf } = await svc.rpc("story_orphans");
      const huerfanos: string[] = Array.isArray(orf) ? orf : [];
      if (huerfanos.length) await svc.storage.from(BUCKET).remove(huerfanos);
      return J({ ok: true, borradas: list.length, huerfanos: huerfanos.length });
    }

    // ---------- el resto: quién llama ----------
    // Se llama a las funciones de la base de datos CON la identidad de quien pregunta, así las reglas
    // de quién ve y quién publica viven en un único sitio (la base de datos).
    let call: (fn: string, args?: Record<string, unknown>) => Promise<{ data: any; error: any }>;
    if (typeof b.u === "string" && typeof b.p === "string" && b.u && b.p) {
      const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
      call = (fn, args = {}) => anon.rpc(fn, { p_u: b.u, p_p: b.p, ...args });
    } else {
      const tk = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
      if (!tk) return J({ error: "sin sesión" }, 401);
      const usr = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${tk}` } },
      });
      call = (fn, args = {}) => usr.rpc(fn, { p_u: null, p_p: null, ...args });
    }
    const me = await call("story_me");
    if (me.error || !me.data) return J({ error: "sin acceso" }, 401);

    // ---------- upload ----------
    if (act === "upload") {
      if (!me.data.canpost) return J({ error: "Ahora mismo no puedes publicar stories" }, 403);
      const ext = String(b.ext || "").toLowerCase().replace(/^\./, "");
      if (!EXT.has(ext)) return J({ error: "Formato no admitido (usa foto o vídeo)" }, 400);
      const isVid = ext === "mp4" || ext === "webm" || ext === "mov";
      const size = Number(b.size || 0);
      if (!(size > 0)) return J({ error: "archivo vacío" }, 400);
      if (size > (isVid ? MAX_VID : MAX_IMG)) return J({ error: isVid ? "El vídeo no puede superar 25 MB" : "La foto no puede superar 6 MB" }, 400);
      const path = `${me.data.kind}/${me.data.id}/${crypto.randomUUID()}.${ext}`;
      const { data, error } = await svc.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error || !data) return J({ error: "No se pudo preparar la subida" }, 500);
      return J({ path, token: data.token });
    }

    // ---------- urls ----------
    if (act === "urls") {
      const ids: string[] = (Array.isArray(b.ids) ? b.ids : []).map(String).filter((x: string) => UUID.test(x)).slice(0, 60);
      if (!ids.length) return J({ urls: {} });
      const feed = await call("story_feed");
      if (feed.error) return J({ error: "sin acceso" }, 403);
      const visibles = new Set((feed.data || []).filter((s: any) => s.media).map((s: any) => String(s.id)));
      const ok = ids.filter((i) => visibles.has(i));
      if (!ok.length) return J({ urls: {} });
      const { data: rows } = await svc.from("stories").select("id,path").in("id", ok).not("path", "is", null);
      const paths = (rows || []).map((r: any) => r.path);
      if (!paths.length) return J({ urls: {} });
      const { data: signed, error } = await svc.storage.from(BUCKET).createSignedUrls(paths, 3600);
      if (error || !signed) return J({ error: "No se pudieron abrir los archivos" }, 500);
      const byPath = new Map(signed.map((s: any) => [s.path, s.signedUrl]));
      const out: Record<string, string> = {};
      for (const r of rows || []) { const u = byPath.get(r.path); if (u) out[r.id] = u as string; }
      return J({ urls: out });
    }

    return J({ error: "acción no válida" }, 400);
  } catch (_e) {
    return J({ error: "error interno" }, 500);
  }
});
