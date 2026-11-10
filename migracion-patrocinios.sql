-- =====================================================================
-- Nexum · Patrocinios y anuncios
-- Solo el administrador crea, edita y borra. Atletas y entrenadores
-- solo pueden leer los activos (y sumar contadores de vistas/clics).
-- Idempotente: se puede ejecutar más de una vez.
-- =====================================================================

-- 1. Tablas ----------------------------------------------------------
create table if not exists public.sponsors(
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null check (char_length(btrim(nombre)) between 1 and 80),
  categoria   text not null default '' check (char_length(categoria) <= 40),
  descripcion text not null default '' check (char_length(descripcion) <= 1200),
  web         text not null default '' check (web = '' or web ~* '^https://[^[:space:]]+$'),
  logo        text not null default '' check (char_length(logo) <= 200000
                and (logo = '' or logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$')),
  portada     text not null default '' check (char_length(portada) <= 450000
                and (portada = '' or portada ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$')),
  aud         text not null default 'todos' check (aud in ('todos','atletas','entrenadores')),
  activo      boolean not null default true,
  orden       int  not null default 0,
  vistas      int  not null default 0,
  clics       int  not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.sponsor_ads(
  id          uuid primary key default gen_random_uuid(),
  sponsor_id  uuid not null references public.sponsors(id) on delete cascade,
  titulo      text not null check (char_length(btrim(titulo)) between 1 and 90),
  texto       text not null default '' check (char_length(texto) <= 600),
  descuento   text not null default '' check (char_length(descuento) <= 40),
  codigo      text not null default '' check (char_length(codigo) <= 40),
  enlace      text not null default '' check (enlace = '' or enlace ~* '^https://[^[:space:]]+$'),
  condiciones text not null default '' check (char_length(condiciones) <= 300),
  desde       date,
  hasta       date,
  activo      boolean not null default true,
  orden       int  not null default 0,
  vistas      int  not null default 0,
  clics       int  not null default 0,
  copias      int  not null default 0,
  created_at  timestamptz not null default now(),
  check (hasta is null or desde is null or hasta >= desde)
);
create index if not exists sponsor_ads_sponsor_idx on public.sponsor_ads(sponsor_id);

-- RLS activada y SIN políticas: nadie lee ni escribe directamente.
-- Todo pasa por las funciones de abajo (security definer).
alter table public.sponsors    enable row level security;
alter table public.sponsor_ads enable row level security;
revoke all on public.sponsors, public.sponsor_ads from anon, authenticated;

-- 2. Quién mira ------------------------------------------------------
-- Atleta (usuario y contraseña, como squad_ranking) o usuario con sesión
-- (entrenador, nutricionista, administrador). Devuelve su audiencia.
create or replace function public.sponsor_viewer(p_u text, p_p text)
returns text
language plpgsql stable security definer
set search_path = public, extensions
as $$
begin
  if p_u is not null then
    if exists (select 1 from public.clients c where c.usr = lower(p_u) and c.pwd = crypt(p_p, c.pwd)) then
      return 'atletas';
    end if;
    raise exception 'No autorizado' using errcode = '42501';
  elsif auth.uid() is not null then
    return 'entrenadores';
  end if;
  raise exception 'No autorizado' using errcode = '42501';
end $$;
revoke all on function public.sponsor_viewer(text, text) from public, anon, authenticated;

-- 3. Lectura para atletas y entrenadores -----------------------------
create or replace function public.sponsors_list(p_u text default null, p_p text default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_aud text := public.sponsor_viewer(p_u, p_p);
        v_hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'nombre', s.nombre, 'categoria', s.categoria, 'descripcion', s.descripcion,
      'web', s.web, 'logo', s.logo, 'portada', s.portada,
      'ads', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', a.id, 'titulo', a.titulo, 'texto', a.texto, 'descuento', a.descuento,
          'codigo', a.codigo, 'enlace', a.enlace, 'condiciones', a.condiciones, 'hasta', a.hasta
        ) order by a.orden, a.created_at)
        from public.sponsor_ads a
        where a.sponsor_id = s.id and a.activo
          and (a.desde is null or a.desde <= v_hoy)
          and (a.hasta is null or a.hasta >= v_hoy)
      ), '[]'::jsonb)
    ) order by s.orden, s.nombre)
    from public.sponsors s
    where s.activo and s.aud in ('todos', v_aud)
  ), '[]'::jsonb);
end $$;
grant execute on function public.sponsors_list(text, text) to anon, authenticated;

-- 4. Contadores (vistas, clics, códigos copiados) --------------------
-- p_kind: 's' patrocinador · 'a' anuncio ; p_ev: 'v' vista · 'c' clic · 'k' código copiado
create or replace function public.sponsor_track(p_u text, p_p text, p_kind text, p_ids uuid[], p_ev text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare v_aud text := public.sponsor_viewer(p_u, p_p);
        v_ids uuid[];
begin
  if p_ev not in ('v','c','k') or p_kind not in ('s','a') or p_ids is null then return; end if;
  v_ids := p_ids[1:50];
  if p_kind = 's' then
    update public.sponsors
       set vistas = vistas + (p_ev = 'v')::int, clics = clics + (p_ev = 'c')::int
     where id = any(v_ids) and activo and aud in ('todos', v_aud);
  else
    update public.sponsor_ads a
       set vistas = a.vistas + (p_ev = 'v')::int, clics = a.clics + (p_ev = 'c')::int, copias = a.copias + (p_ev = 'k')::int
      from public.sponsors s
     where a.id = any(v_ids) and a.activo and s.id = a.sponsor_id and s.activo and s.aud in ('todos', v_aud);
  end if;
end $$;
grant execute on function public.sponsor_track(text, text, text, uuid[], text) to anon, authenticated;

-- 5. Administración (solo is_admin()) --------------------------------
create or replace function public.admin_sponsors_list()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(s) || jsonb_build_object('ads', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.orden, a.created_at)
      from public.sponsor_ads a where a.sponsor_id = s.id
    ), '[]'::jsonb)) order by s.orden, s.nombre)
    from public.sponsors s
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_sponsor_save(p jsonb)
returns uuid
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  if btrim(coalesce(p->>'nombre', '')) = '' then raise exception 'Falta el nombre del patrocinador'; end if;
  if v_id is null then
    insert into public.sponsors(nombre, categoria, descripcion, web, logo, portada, aud, activo, orden)
    values (btrim(p->>'nombre'), btrim(coalesce(p->>'categoria','')), btrim(coalesce(p->>'descripcion','')),
            btrim(coalesce(p->>'web','')), coalesce(p->>'logo',''), coalesce(p->>'portada',''),
            coalesce(nullif(p->>'aud',''), 'todos'), coalesce((p->>'activo')::boolean, true),
            coalesce((p->>'orden')::int, 0))
    returning id into v_id;
  else
    update public.sponsors set
      nombre      = btrim(p->>'nombre'),
      categoria   = case when p ? 'categoria'   then btrim(coalesce(p->>'categoria',''))   else categoria end,
      descripcion = case when p ? 'descripcion' then btrim(coalesce(p->>'descripcion','')) else descripcion end,
      web         = case when p ? 'web'         then btrim(coalesce(p->>'web',''))         else web end,
      logo        = case when p ? 'logo'        then coalesce(p->>'logo','')               else logo end,
      portada     = case when p ? 'portada'     then coalesce(p->>'portada','')            else portada end,
      aud         = case when p ? 'aud'         then coalesce(nullif(p->>'aud',''),'todos') else aud end,
      activo      = case when p ? 'activo'      then coalesce((p->>'activo')::boolean, activo) else activo end,
      orden       = case when p ? 'orden'       then coalesce((p->>'orden')::int, orden)   else orden end
    where id = v_id;
    if not found then raise exception 'Patrocinador no encontrado'; end if;
  end if;
  return v_id;
exception when check_violation then
  raise exception 'Datos no válidos: los enlaces deben empezar por https:// y las imágenes no pueden ser demasiado grandes.';
end $$;

create or replace function public.admin_sponsor_del(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  delete from public.sponsors where id = p_id;
end $$;

create or replace function public.admin_ad_save(p jsonb)
returns uuid
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
        v_sp uuid := nullif(p->>'sponsor_id', '')::uuid;
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  if btrim(coalesce(p->>'titulo', '')) = '' then raise exception 'Falta el título del anuncio'; end if;
  if v_id is null then
    if v_sp is null or not exists (select 1 from public.sponsors where id = v_sp) then
      raise exception 'Patrocinador no encontrado';
    end if;
    insert into public.sponsor_ads(sponsor_id, titulo, texto, descuento, codigo, enlace, condiciones, desde, hasta, activo, orden)
    values (v_sp, btrim(p->>'titulo'), btrim(coalesce(p->>'texto','')), btrim(coalesce(p->>'descuento','')),
            btrim(coalesce(p->>'codigo','')), btrim(coalesce(p->>'enlace','')), btrim(coalesce(p->>'condiciones','')),
            nullif(p->>'desde','')::date, nullif(p->>'hasta','')::date,
            coalesce((p->>'activo')::boolean, true), coalesce((p->>'orden')::int, 0))
    returning id into v_id;
  else
    update public.sponsor_ads set
      titulo      = btrim(p->>'titulo'),
      texto       = case when p ? 'texto'       then btrim(coalesce(p->>'texto',''))       else texto end,
      descuento   = case when p ? 'descuento'   then btrim(coalesce(p->>'descuento',''))   else descuento end,
      codigo      = case when p ? 'codigo'      then btrim(coalesce(p->>'codigo',''))      else codigo end,
      enlace      = case when p ? 'enlace'      then btrim(coalesce(p->>'enlace',''))      else enlace end,
      condiciones = case when p ? 'condiciones' then btrim(coalesce(p->>'condiciones','')) else condiciones end,
      desde       = case when p ? 'desde'       then nullif(p->>'desde','')::date          else desde end,
      hasta       = case when p ? 'hasta'       then nullif(p->>'hasta','')::date          else hasta end,
      activo      = case when p ? 'activo'      then coalesce((p->>'activo')::boolean, activo) else activo end,
      orden       = case when p ? 'orden'       then coalesce((p->>'orden')::int, orden)   else orden end
    where id = v_id;
    if not found then raise exception 'Anuncio no encontrado'; end if;
  end if;
  return v_id;
exception when check_violation then
  raise exception 'Datos no válidos: el enlace debe empezar por https:// y la fecha de fin no puede ser anterior a la de inicio.';
end $$;

create or replace function public.admin_ad_del(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  delete from public.sponsor_ads where id = p_id;
end $$;

-- Las funciones de administración solo las puede llamar un usuario con sesión
-- (y además comprueban is_admin() por dentro).
revoke all on function public.admin_sponsors_list()          from public, anon;
revoke all on function public.admin_sponsor_save(jsonb)      from public, anon;
revoke all on function public.admin_sponsor_del(uuid)        from public, anon;
revoke all on function public.admin_ad_save(jsonb)           from public, anon;
revoke all on function public.admin_ad_del(uuid)             from public, anon;
grant execute on function public.admin_sponsors_list()       to authenticated;
grant execute on function public.admin_sponsor_save(jsonb)   to authenticated;
grant execute on function public.admin_sponsor_del(uuid)     to authenticated;
grant execute on function public.admin_ad_save(jsonb)        to authenticated;
grant execute on function public.admin_ad_del(uuid)          to authenticated;
