-- ============================================================================
-- NEXUM · STORIES (v67 + v68)
-- Stories de 24 h (foto, vídeo ≤ 30 s o texto) para entrenadores y atletas.
--   · v68: textos colocados DENTRO de la foto/vídeo (columna «ov») y foto de perfil de quien publica en el círculo («story_photos»).
--   · Alcance de cada story: 'grupo' (el entrenador y sus atletas), 'comunidad' (toda la plataforma)
--     o 'nexum' (solo el administrador; sale como «Nexum»).
--   · Los atletas sin entrenador ven lo de la comunidad y lo de Nexum.
--   · Todo va por funciones (RLS cerrada). Los archivos van a un bucket PRIVADO con URLs firmadas.
-- Idempotente: se puede volver a ejecutar.
-- ============================================================================

-- ---------- 1. Tablas ----------
create table if not exists public.stories (
  id          uuid primary key default gen_random_uuid(),
  author_kind text not null check (author_kind in ('client','coach','admin')),
  author_id   uuid not null,
  group_id    uuid,
  scope       text not null default 'grupo' check (scope in ('grupo','comunidad','nexum')),
  kind        text not null check (kind in ('image','video','text')),
  body        text check (body is null or char_length(body) <= 280),
  bg          text check (bg is null or bg ~ '^[a-z0-9]{1,12}$'),
  path        text,
  dur         integer check (dur is null or dur between 1 and 30),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '24 hours',
  deleted_at  timestamptz,
  purged_at   timestamptz,
  constraint stories_contenido_chk check (
    (kind = 'text' and path is null and char_length(btrim(coalesce(body, ''))) > 0)
    or (kind in ('image','video') and (path is not null or purged_at is not null)))
);
create index if not exists stories_expira_idx on public.stories (expires_at);
create index if not exists stories_grupo_idx on public.stories (group_id, created_at desc);
create index if not exists stories_autor_idx on public.stories (author_id, created_at desc);

create table if not exists public.story_views (
  story_id    uuid not null references public.stories(id) on delete cascade,
  viewer_kind text not null check (viewer_kind in ('client','coach')),
  viewer_id   uuid not null,
  viewed_at   timestamptz not null default now(),
  primary key (story_id, viewer_kind, viewer_id)
);

create table if not exists public.story_reports (
  id            bigserial primary key,
  story_id      uuid not null references public.stories(id) on delete cascade,
  reporter_kind text not null check (reporter_kind in ('client','coach')),
  reporter_id   uuid not null,
  reason        text check (reason is null or char_length(reason) <= 300),
  status        text not null default 'pendiente' check (status in ('pendiente','resuelta')),
  created_at    timestamptz not null default now(),
  unique (story_id, reporter_kind, reporter_id)
);

alter table public.stories enable row level security;
alter table public.story_views enable row level security;
alter table public.story_reports enable row level security;
revoke all on public.stories, public.story_views, public.story_reports from anon, authenticated;
revoke all on sequence public.story_reports_id_seq from anon, authenticated;

-- ---------- 1b. (v68) Textos sobre la foto o el vídeo ----------
-- «ov» = lista (máx. 4) de textos colocados sobre la foto/vídeo:
--   [{"t":"Hoy pierna","x":50,"y":30,"s":8,"c":"w","b":1}]
--   t texto (1–140) · x,y posición del centro en % de la foto (0–100) · s tamaño (3–16, en % del ancho) · c color (clave) · b fondo (0 sin, 1 oscuro, 2 color)
alter table public.stories add column if not exists ov jsonb;

create or replace function public.nx_story_ov_ok(o jsonb)
returns boolean language plpgsql immutable set search_path = public as $$
declare it jsonb; k text;
begin
  if o is null then return true; end if;
  if jsonb_typeof(o) <> 'array' or jsonb_array_length(o) > 4 then return false; end if;
  for it in select value from jsonb_array_elements(o) loop
    if jsonb_typeof(it) <> 'object' then return false; end if;
    for k in select jsonb_object_keys(it) loop
      if k not in ('t', 'x', 'y', 's', 'c', 'b') then return false; end if;
    end loop;
    if coalesce(jsonb_typeof(it->'t'), '') <> 'string' or char_length(btrim(it->>'t')) not between 1 and 140 then return false; end if;
    if coalesce(jsonb_typeof(it->'x'), '') <> 'number' or (it->>'x')::numeric not between 0 and 100 then return false; end if;
    if coalesce(jsonb_typeof(it->'y'), '') <> 'number' or (it->>'y')::numeric not between 0 and 100 then return false; end if;
    if coalesce(jsonb_typeof(it->'s'), '') <> 'number' or (it->>'s')::numeric not between 3 and 16 then return false; end if;
    if coalesce(jsonb_typeof(it->'c'), '') <> 'string' or (it->>'c') !~ '^[a-z]{1,2}$' then return false; end if;
    if coalesce(jsonb_typeof(it->'b'), '') <> 'number' or (it->>'b')::numeric not in (0, 1, 2) then return false; end if;
  end loop;
  return true;
end $$;
revoke all on function public.nx_story_ov_ok(jsonb) from public, anon, authenticated;

alter table public.stories drop constraint if exists stories_ov_chk;
alter table public.stories add constraint stories_ov_chk
  check (ov is null or (kind in ('image', 'video') and public.nx_story_ov_ok(ov)));

-- ---------- 2. Bucket privado (25 MB, solo imagen y vídeo) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stories', 'stories', false, 26214400, array['image/*','video/*'])
on conflict (id) do update set public = false, file_size_limit = 26214400, allowed_mime_types = array['image/*','video/*'];

-- ---------- 3. Quién llama (atleta por usuario/contraseña · entrenador/admin por sesión) ----------
create or replace function public.nx_story_who(p_u text, p_p text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c clients; k coaches; a boolean; uid uuid; v_cobro boolean; g uuid;
begin
  if coalesce(p_u, '') <> '' then
    select * into c from clients where lower(usr) = lower(p_u) and pwd = crypt(p_p, pwd) limit 1;
    if not found or coalesce(c.suspendido, false) then return null; end if;
    g := coalesce(c.coach_id, c.coach);
    select coalesce((value #>> '{}')::boolean, false) into v_cobro from app_config where key = 'cobro_premium';
    return jsonb_build_object('kind', 'client', 'id', c.id, 'grp', g, 'name', c.name, 'admin', false,
      'canpost', case when g is not null then true else (not coalesce(v_cobro, false)) or pm_activo(c) end);
  end if;
  uid := auth.uid();
  if uid is null then return null; end if;
  a := exists (select 1 from admins where user_id = uid);
  select * into k from coaches where id = uid;
  if found then
    if coalesce(k.suspendido, false) and not a then return null; end if;
    return jsonb_build_object('kind', 'coach', 'id', uid, 'grp', uid, 'name', btrim(coalesce(k.nombre, '') || ' ' || coalesce(k.apellidos, '')), 'admin', a, 'canpost', true);
  end if;
  if a then return jsonb_build_object('kind', 'coach', 'id', uid, 'grp', null, 'name', 'Nexum', 'admin', true, 'canpost', true); end if;
  return null;
end $$;

-- ¿Puede esa persona ver esa story?
create or replace function public.nx_story_vis(s public.stories, w jsonb)
returns boolean language sql stable security definer set search_path = public as $$
  select s.deleted_at is null and s.expires_at > now() and (
       coalesce((w->>'admin')::boolean, false)
    or s.author_id = (w->>'id')::uuid
    or s.scope in ('comunidad', 'nexum')
    or (s.scope = 'grupo' and s.group_id is not null and s.group_id = nullif(w->>'grp', '')::uuid))
$$;

revoke all on function public.nx_story_who(text, text), public.nx_story_vis(public.stories, jsonb) from public, anon, authenticated;

-- ---------- 4. Funciones que usa la app ----------
-- Lo que puedo hacer (la edge function «story-files» lo usa antes de dejar subir un archivo)
create or replace function public.story_me(p_u text default null, p_p text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p);
begin
  if w is null then return null; end if;
  return jsonb_build_object('kind', w->>'kind', 'id', w->>'id', 'name', w->>'name', 'grupo', (w->>'grp') is not null,
    'admin', coalesce((w->>'admin')::boolean, false), 'canpost', coalesce((w->>'canpost')::boolean, false));
end $$;

create or replace function public.story_feed(p_u text default null, p_p text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid;
begin
  if w is null then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid;
  return coalesce((
    select jsonb_agg(q.x order by q.t)
    from (
      select s.created_at as t, jsonb_build_object(
        'id', s.id, 'author_id', s.author_id,
        'author_kind', case when s.scope = 'nexum' then 'admin' else s.author_kind end,
        'name', case when s.scope = 'nexum' then 'Nexum'
                     else coalesce((select c.name from clients c where c.id = s.author_id),
                                   (select btrim(coalesce(k.nombre, '') || ' ' || coalesce(k.apellidos, '')) from coaches k where k.id = s.author_id), '—') end,
        'scope', s.scope, 'kind', s.kind, 'text', s.body, 'bg', s.bg, 'media', s.path is not null, 'dur', s.dur, 'ov', s.ov,
        'created_at', s.created_at, 'expires_at', s.expires_at, 'mine', s.author_id = me,
        'mod', (s.author_id = me or coalesce((w->>'admin')::boolean, false) or (w->>'kind' = 'coach' and s.group_id = me)),
        'seen', s.author_id = me or exists (select 1 from story_views v where v.story_id = s.id and v.viewer_id = me),
        'views', case when (s.author_id = me or coalesce((w->>'admin')::boolean, false) or (w->>'kind' = 'coach' and s.group_id = me))
                      then (select count(*) from story_views v where v.story_id = s.id) end) as x
      from stories s
      where public.nx_story_vis(s, w)
      order by s.created_at desc limit 300) q), '[]'::jsonb);
end $$;

drop function if exists public.story_add(text, text, text, text, text, text, integer, text);
create or replace function public.story_add(p_u text, p_p text, p_kind text, p_text text, p_bg text, p_path text, p_dur integer, p_scope text, p_ov jsonb default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid; grp uuid; v_scope text; n integer; v_id uuid; v_body text;
begin
  if w is null or not coalesce((w->>'canpost')::boolean, false) then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid; grp := nullif(w->>'grp', '')::uuid;
  if p_kind not in ('image', 'video', 'text') then raise exception 'Tipo de story no válido'; end if;
  if p_kind = 'text' and btrim(coalesce(p_text, '')) = '' then raise exception 'Escribe algo para tu story'; end if;
  if char_length(coalesce(p_text, '')) > 280 then raise exception 'El texto no puede superar los 280 caracteres'; end if;
  v_scope := coalesce(nullif(p_scope, ''), 'grupo');
  if v_scope not in ('grupo', 'comunidad', 'nexum') then raise exception 'Alcance no válido'; end if;
  if v_scope = 'nexum' and not coalesce((w->>'admin')::boolean, false) then raise exception 'No permitido'; end if;
  if grp is null and v_scope = 'grupo' then v_scope := 'comunidad'; end if;
  if p_kind in ('image', 'video') then
    if p_path is null or p_path !~ ('^' || (w->>'kind') || '/' || me::text || '/[0-9a-f-]{36}\.(jpg|webp|png|mp4|webm|mov)$') then raise exception 'Archivo no válido'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'stories' and name = p_path) then raise exception 'El archivo no se ha subido bien. Inténtalo de nuevo'; end if;
    if p_kind = 'video' and (p_dur is null or p_dur not between 1 and 30) then raise exception 'El vídeo debe durar entre 1 y 30 segundos'; end if;
  end if;
  -- textos sobre la foto: un JSON «null» o una lista vacía cuentan como «sin textos»
  if p_ov is not null and (jsonb_typeof(p_ov) = 'null' or (jsonb_typeof(p_ov) = 'array' and jsonb_array_length(p_ov) = 0)) then p_ov := null; end if;
  v_body := nullif(btrim(coalesce(p_text, '')), '');
  if p_ov is not null then
    if p_kind not in ('image', 'video') then raise exception 'Los textos sobre la foto solo valen para fotos y vídeos'; end if;
    if not public.nx_story_ov_ok(p_ov) then raise exception 'Los textos de la story no son válidos'; end if;
    -- el texto plano (denuncias, moderación) es la suma de los textos puestos sobre la foto
    v_body := left((select string_agg(btrim(e.value->>'t'), ' · ') from jsonb_array_elements(p_ov) e), 280);
  end if;
  select count(*) into n from stories where author_id = me and deleted_at is null and expires_at > now();
  if n >= 15 then raise exception 'Has llegado al máximo de 15 stories activas'; end if;
  select count(*) into n from stories where author_id = me and created_at > now() - interval '1 day';
  if n >= 40 then raise exception 'Has publicado demasiadas stories hoy'; end if;
  insert into stories (author_kind, author_id, group_id, scope, kind, body, bg, path, dur, ov)
  values (case when v_scope = 'nexum' then 'admin' else w->>'kind' end, me, grp, v_scope, p_kind, v_body,
          case when p_kind = 'text' then coalesce(nullif(p_bg, ''), 'c1') else null end,
          case when p_kind = 'text' then null else p_path end, case when p_kind = 'video' then p_dur end, p_ov)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.story_view(p_u text, p_p text, p_ids uuid[])
returns void language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid;
begin
  if w is null then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid;
  insert into story_views (story_id, viewer_kind, viewer_id)
  select s.id, w->>'kind', me from stories s
  where s.id = any (p_ids[1:60]) and s.author_id <> me and public.nx_story_vis(s, w)
  on conflict do nothing;
end $$;

-- Quién la ha visto: el autor, el entrenador del grupo y el administrador
create or replace function public.story_viewers(p_u text, p_p text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid; s stories;
begin
  if w is null then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid;
  select * into s from stories where id = p_id;
  if not found then return '[]'::jsonb; end if;
  if not (s.author_id = me or coalesce((w->>'admin')::boolean, false) or (w->>'kind' = 'coach' and s.group_id = me)) then raise exception 'No permitido'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', coalesce((select c.name from clients c where c.id = v.viewer_id),
                                                           (select btrim(coalesce(k.nombre, '') || ' ' || coalesce(k.apellidos, '')) from coaches k where k.id = v.viewer_id), '—'),
                                         'at', v.viewed_at) order by v.viewed_at desc)
    from (select * from story_views where story_id = p_id order by viewed_at desc limit 200) v), '[]'::jsonb);
end $$;

-- Borrar: el autor, el entrenador del grupo (moderación) y el administrador
create or replace function public.story_delete(p_u text, p_p text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid; s stories;
begin
  if w is null then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid;
  select * into s from stories where id = p_id;
  if not found then return false; end if;
  if not (s.author_id = me or coalesce((w->>'admin')::boolean, false) or (w->>'kind' = 'coach' and s.group_id = me)) then raise exception 'No permitido'; end if;
  update stories set deleted_at = coalesce(deleted_at, now()) where id = p_id;
  return true;
end $$;

-- (v68) Foto de perfil de quien publica (para el círculo)
-- Devuelve la foto SOLO de personas con una story que quien pregunta puede ver (las de «Nexum (oficial)» no llevan foto).
create or replace function public.story_photos(p_u text default null, p_p text default null, p_ids uuid[] default '{}')
returns table(id uuid, photo text) language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p);
begin
  if w is null then raise exception 'No permitido'; end if;
  return query
    select a.aid, a.f
      from (select v.aid,
                   case when exists (select 1 from clients c where c.id = v.aid)
                        then (select c2.data->'prof'->>'photo' from clients c2 where c2.id = v.aid)
                        else (select k.foto from coaches k where k.id = v.aid) end as f
              from (select distinct s.author_id as aid from stories s
                     where s.author_id = any (p_ids[1:40]) and s.scope <> 'nexum' and public.nx_story_vis(s, w)) v) a
     where a.f is not null and length(a.f) <= 250000 and a.f ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$';
end $$;

create or replace function public.nx_story_notify(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare v_mail text; v_body jsonb;
begin
  select value->>'email' into v_mail from app_config where key = 'nexum_fiscal';
  v_body := public.nx_mail(v_mail, 'Nexum', 'Nueva denuncia de una story', p_text, 'Abrir Nexum');
  if v_body is not null then
    begin perform public.email_post(jsonb_build_array(v_body)); exception when others then null; end;
  end if;
exception when others then null;
end $$;
revoke all on function public.nx_story_notify(text) from public, anon, authenticated;

create or replace function public.story_report(p_u text, p_p text, p_id uuid, p_reason text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb := public.nx_story_who(p_u, p_p); me uuid; s stories; nm text;
begin
  if w is null then raise exception 'No permitido'; end if;
  me := (w->>'id')::uuid;
  select * into s from stories where id = p_id;
  if not found or not public.nx_story_vis(s, w) then raise exception 'No permitido'; end if;
  if s.author_id = me then raise exception 'No puedes denunciar tu propia story'; end if;
  insert into story_reports (story_id, reporter_kind, reporter_id, reason)
  values (p_id, w->>'kind', me, left(nullif(btrim(coalesce(p_reason, '')), ''), 300))
  on conflict do nothing;
  if found then
    perform public.nx_story_notify((w->>'name') || ' ha denunciado una story. Revísala en Administración → Ajustes → Denuncias de stories.');
  end if;
  return true;
end $$;

-- Administración: denuncias pendientes y resolución
create or replace function public.admin_story_reports()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'story_id', r.story_id, 'reason', r.reason, 'created_at', r.created_at,
      'kind', s.kind, 'text', s.body, 'scope', s.scope, 'media', s.path is not null, 'gone', (s.deleted_at is not null or s.expires_at <= now()),
      'author', coalesce((select c.name from clients c where c.id = s.author_id), (select btrim(coalesce(k.nombre, '') || ' ' || coalesce(k.apellidos, '')) from coaches k where k.id = s.author_id), '—'),
      'reporter', coalesce((select c.name from clients c where c.id = r.reporter_id), (select btrim(coalesce(k.nombre, '') || ' ' || coalesce(k.apellidos, '')) from coaches k where k.id = r.reporter_id), '—'))
      order by r.created_at desc)
    from story_reports r join stories s on s.id = r.story_id where r.status = 'pendiente'), '[]'::jsonb);
end $$;

create or replace function public.admin_story_resolve(p_id bigint, p_remove boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_story uuid;
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  select story_id into v_story from story_reports where id = p_id;
  if v_story is null then return false; end if;
  if coalesce(p_remove, false) then update stories set deleted_at = coalesce(deleted_at, now()) where id = v_story; end if;
  update story_reports set status = 'resuelta' where story_id = v_story and status = 'pendiente';
  insert into admin_log (admin, action, target, detail)
  values ((select auth.uid()), 'story_report', v_story::text, jsonb_build_object('remove', coalesce(p_remove, false)));
  return true;
end $$;

-- Limpieza: filas de stories ya purgadas con más de 7 días y sin denuncias pendientes
create or replace function public.story_cleanup()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from stories s
   where s.created_at < now() - interval '7 days' and s.path is null
     and not exists (select 1 from story_reports r where r.story_id = s.id and r.status = 'pendiente');
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.story_cleanup() from public, anon, authenticated;

-- Archivos subidos que nunca llegaron a publicarse (la subida fue bien y «story_add» falló): la función «story-files» los borra
create or replace function public.story_orphans()
returns text[] language sql security definer set search_path = public, storage as $$
  select coalesce(array_agg(o.name), '{}') from (
    select name from storage.objects
     where bucket_id = 'stories' and created_at < now() - interval '1 day'
       and name not in (select path from public.stories where path is not null)
     limit 200) o
$$;
revoke all on function public.story_orphans() from public, anon, authenticated;
grant execute on function public.story_orphans() to service_role;

-- ---------- 5. Permisos ----------
-- Atletas (sin sesión: usan usuario y contraseña) y entrenadores (con sesión) usan las mismas funciones
revoke all on function public.story_me(text, text), public.story_feed(text, text), public.story_add(text, text, text, text, text, text, integer, text, jsonb), public.story_photos(text, text, uuid[]),
  public.story_view(text, text, uuid[]), public.story_viewers(text, text, uuid), public.story_delete(text, text, uuid), public.story_report(text, text, uuid, text) from public;
grant execute on function public.story_me(text, text), public.story_feed(text, text), public.story_add(text, text, text, text, text, text, integer, text, jsonb), public.story_photos(text, text, uuid[]),
  public.story_view(text, text, uuid[]), public.story_viewers(text, text, uuid), public.story_delete(text, text, uuid), public.story_report(text, text, uuid, text)
  to anon, authenticated, service_role;
revoke all on function public.admin_story_reports(), public.admin_story_resolve(bigint, boolean) from public, anon;
grant execute on function public.admin_story_reports(), public.admin_story_resolve(bigint, boolean) to authenticated, service_role;

-- ---------- 6. Tareas programadas ----------
-- Cada hora: la función «story-files» borra del almacenamiento los archivos caducados o borrados.
-- Cada día: se eliminan las filas antiguas.
do $$
declare v_url text;
begin
  select v into v_url from push_cfg where k = 'fn_url';
  if v_url is not null then
    perform cron.unschedule(jobid) from cron.job where jobname in ('story-purge', 'story-cleanup');
    perform cron.schedule('story-purge', '17 * * * *',
      format($f$select net.http_post(url := %L, body := '{"action":"purge"}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 20000)$f$, v_url || '/story-files'));
    perform cron.schedule('story-cleanup', '40 3 * * *', 'select public.story_cleanup()');
  end if;
end $$;

-- ---------- 7. Versión de los textos legales ----------
-- Las stories añaden un tratamiento nuevo (publicar contenido, visibilidad, denuncias): los textos suben de versión
-- y se vuelve a pedir la aceptación. Debe coincidir con LEGAL_V del archivo index.html.
create or replace function public.nx_legal_version() returns text language sql immutable as $$ select '2026-11-13'::text $$;
