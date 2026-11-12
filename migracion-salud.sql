-- =====================================================================================
-- NEXUM · v65 · SALUD (informes médicos, de fisioterapia, nutrición…)
-- Solo los ven el atleta y SU entrenador. Ni el administrador ni otros entrenadores.
--  · Tabla health_docs: RLS activado y SIN políticas ni permisos directos (anon/authenticated).
--    Todo el acceso pasa por funciones SECURITY DEFINER que comprueban quién eres.
--  · Bucket privado «health» (solo PDF, 10 MB): sin políticas en storage.objects; los
--    archivos solo se tocan desde la Edge Function health-files (service role).
-- =====================================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('health', 'health', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];

create table if not exists public.health_docs (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  tipo text not null check (tipo in ('medico','fisio','nutri','psico','otro')),
  titulo text check (titulo is null or char_length(titulo) <= 120),
  fecha date,
  profesional text check (profesional is null or char_length(profesional) <= 120),
  form jsonb not null default '{}'::jsonb,
  file_path text unique,
  file_name text,
  file_size integer,
  consent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists health_docs_client_idx on public.health_docs (client_id, created_at desc);
alter table public.health_docs enable row level security;
revoke all on public.health_docs from anon, authenticated;
comment on table public.health_docs is 'Informes de salud del atleta. Sin políticas RLS a propósito: solo accesible mediante las funciones health_* (SECURITY DEFINER).';

create or replace function public.health_tipo_txt(t text) returns text language sql immutable set search_path = public as $$
  select case t when 'medico' then 'informe médico' when 'fisio' then 'informe de fisioterapia' when 'nutri' then 'informe de nutrición'
                when 'psico' then 'informe de psicología' else 'informe' end $$;

-- ---------- Atleta: listar ----------
create or replace function public.health_list(p_u text, p_p text)
returns table (id uuid, tipo text, titulo text, fecha date, profesional text, form jsonb, file_name text, file_size integer, created_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
declare cid uuid;
begin
  cid := public.client_id_by_cred(p_u, p_p);
  if cid is null then raise exception 'credenciales'; end if;
  return query
    select d.id, d.tipo, d.titulo, d.fecha, d.profesional, d.form, d.file_name, d.file_size, d.created_at
    from public.health_docs d where d.client_id = cid
    order by coalesce(d.fecha, d.created_at::date) desc, d.created_at desc limit 200;
end $$;

-- ---------- Entrenador: listar los de SU atleta ----------
create or replace function public.health_list_coach(p_client uuid)
returns table (id uuid, tipo text, titulo text, fecha date, profesional text, form jsonb, file_name text, file_size integer, created_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
declare me uuid := auth.uid();
begin
  if me is null or not exists (select 1 from public.clients c where c.id = p_client and (c.coach = me or c.coach_id = me)) then
    raise exception 'sin acceso';
  end if;
  return query
    select d.id, d.tipo, d.titulo, d.fecha, d.profesional, d.form, d.file_name, d.file_size, d.created_at
    from public.health_docs d where d.client_id = p_client
    order by coalesce(d.fecha, d.created_at::date) desc, d.created_at desc limit 200;
end $$;
revoke execute on function public.health_list_coach(uuid) from anon, public;
grant execute on function public.health_list_coach(uuid) to authenticated;

-- ---------- Atleta: añadir (cuestionario y/o PDF ya subido) ----------
create or replace function public.health_add(p_u text, p_p text, p_doc jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  cid uuid; f jsonb := '{}'::jsonb; k text; v text; vp text; vn int; fn text; tp text; ft date; nid uuid;
begin
  cid := public.client_id_by_cred(p_u, p_p);
  if cid is null then raise exception 'credenciales'; end if;
  if p_doc is null or jsonb_typeof(p_doc) <> 'object' then raise exception 'datos no válidos'; end if;
  if coalesce((p_doc->>'consent')::boolean, false) is not true then raise exception 'Falta tu consentimiento'; end if;
  tp := p_doc->>'tipo';
  if tp is null or tp not in ('medico','fisio','nutri','psico','otro') then raise exception 'Tipo de informe no válido'; end if;
  if (select count(*) from public.health_docs where client_id = cid) >= 100 then raise exception 'Has llegado al máximo de 100 informes'; end if;
  begin ft := nullif(p_doc->>'fecha','')::date; exception when others then raise exception 'Fecha no válida'; end;
  foreach k in array array['motivo','tratamiento','limitaciones','medicacion','proxima','obs'] loop
    v := nullif(trim(coalesce(p_doc->'form'->>k, '')), '');
    if v is not null then f := f || jsonb_build_object(k, left(v, 2000)); end if;
  end loop;
  vp := nullif(p_doc->>'file_path', '');
  if vp is not null then
    if vp not like cid::text || '/%' or vp !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.pdf$' then raise exception 'Archivo no válido'; end if;
    select nullif(o.metadata->>'size','')::int into vn from storage.objects o where o.bucket_id = 'health' and o.name = vp;
    if not found then raise exception 'El PDF no se ha subido correctamente. Inténtalo de nuevo.'; end if;
    fn := left(nullif(trim(coalesce(p_doc->>'file_name','')), ''), 150);
  end if;
  if vp is null and f = '{}'::jsonb then raise exception 'Añade un PDF o rellena el cuestionario'; end if;
  insert into public.health_docs (client_id, tipo, titulo, fecha, profesional, form, file_path, file_name, file_size)
  values (cid, tp, left(nullif(trim(coalesce(p_doc->>'titulo','')), ''), 120), ft,
          left(nullif(trim(coalesce(p_doc->>'profesional','')), ''), 120), f, vp, coalesce(fn, case when vp is not null then 'informe.pdf' end), vn)
  returning id into nid;
  return nid;
end $$;

-- ---------- Aviso al entrenador (sin detalles médicos en la notificación) ----------
create or replace function public.health_after_ins() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare cid uuid; nm text; it jsonb := '[]'::jsonb;
begin
  select coalesce(c.coach_id, c.coach), c.name into cid, nm from public.clients c where c.id = NEW.client_id;
  if cid is not null then
    it := it || nx_item(cid, 'staff', 'actividad', '📄 Nuevo informe de salud',
      coalesce(nm, 'Un atleta') || ' ha añadido un ' || public.health_tipo_txt(NEW.tipo) || '. Solo tú y el atleta podéis verlo.',
      './#cli', 1, null, 'hd-' || NEW.id);
    perform notify(it);
  end if;
  return NEW;
exception when others then return NEW; end $$;
drop trigger if exists trg_health_after_ins on public.health_docs;
create trigger trg_health_after_ins after insert on public.health_docs for each row execute function public.health_after_ins();
revoke execute on function public.health_after_ins() from anon, authenticated, public;

