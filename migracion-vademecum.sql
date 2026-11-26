-- ============================================================================
-- Nexum · Vademécum en Salud: medicación que añade el cliente (v91)
-- Solo la ven el atleta y su entrenador, igual que los informes de Salud:
--   · tabla con RLS activado y SIN políticas ni permisos para anon/authenticated
--   · todo el acceso pasa por funciones security definer
-- Es aditiva: no toca ninguna tabla ni función existente.
-- ============================================================================

create table if not exists public.health_meds (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients(id) on delete cascade,
  nombre     text not null check (char_length(nombre) between 2 and 80),
  nota       text check (nota is null or char_length(nota) <= 200),
  consent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists health_meds_client_idx on public.health_meds (client_id, created_at desc);
alter table public.health_meds enable row level security;
revoke all on public.health_meds from public, anon, authenticated;

-- ---- el atleta lista su medicación ----------------------------------------
create or replace function public.health_med_list(p_u text, p_p text)
returns table(id uuid, nombre text, nota text, created_at timestamptz)
language plpgsql stable security definer set search_path to 'public','extensions' as $$
declare cid uuid;
begin
  cid := public.client_id_by_cred(p_u, p_p);
  if cid is null then raise exception 'credenciales'; end if;
  return query select m.id, m.nombre, m.nota, m.created_at
    from public.health_meds m where m.client_id = cid
    order by m.created_at desc limit 100;
end $$;

-- ---- su entrenador la lista (mismo control de acceso que health_list_coach) --
create or replace function public.health_med_list_coach(p_client uuid)
returns table(id uuid, nombre text, nota text, created_at timestamptz)
language plpgsql stable security definer set search_path to 'public','extensions' as $$
declare me uuid := auth.uid();
begin
  if me is null or not exists (select 1 from public.clients c where c.id = p_client and (c.coach = me or c.coach_id = me)) then
    raise exception 'sin acceso';
  end if;
  return query select m.id, m.nombre, m.nota, m.created_at
    from public.health_meds m where m.client_id = p_client
    order by m.created_at desc limit 100;
end $$;

-- ---- el atleta añade un medicamento (con consentimiento) ---------------------
create or replace function public.health_med_add(p_u text, p_p text, p_name text, p_note text, p_consent boolean)
returns uuid
language plpgsql security definer set search_path to 'public','extensions' as $$
declare cid uuid; nm text; nt text; nid uuid;
begin
  cid := public.client_id_by_cred(p_u, p_p);
  if cid is null then raise exception 'credenciales'; end if;
  if coalesce(p_consent, false) is not true then raise exception 'Falta tu consentimiento'; end if;
  nm := left(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), 80);
  if char_length(nm) < 2 then raise exception 'Escribe el nombre del medicamento'; end if;
  nt := left(nullif(btrim(regexp_replace(coalesce(p_note, ''), '\s+', ' ', 'g')), ''), 200);
  if (select count(*) from public.health_meds where client_id = cid) >= 30 then
    raise exception 'Has llegado al máximo de 30 medicamentos';
  end if;
  if exists (select 1 from public.health_meds where client_id = cid and lower(nombre) = lower(nm)) then
    raise exception 'Ya tienes ese medicamento en tu lista';
  end if;
  insert into public.health_meds (client_id, nombre, nota) values (cid, nm, nt) returning id into nid;
  return nid;
end $$;

-- ---- el atleta elimina uno de los suyos ---------------------------------------
create or replace function public.health_med_del(p_u text, p_p text, p_id uuid)
returns boolean
language plpgsql security definer set search_path to 'public','extensions' as $$
declare cid uuid; n int;
begin
  cid := public.client_id_by_cred(p_u, p_p);
  if cid is null then raise exception 'credenciales'; end if;
  delete from public.health_meds where id = p_id and client_id = cid;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ---- aviso al entrenador (sin el contenido), igual que con los informes --------
create or replace function public.health_med_after_ins()
returns trigger
language plpgsql security definer set search_path to 'public','extensions' as $$
declare cid uuid; nm text; it jsonb := '[]'::jsonb;
begin
  select coalesce(c.coach_id, c.coach), c.name into cid, nm from public.clients c where c.id = NEW.client_id;
  if cid is not null then
    it := it || nx_item(cid, 'staff', 'actividad', '💊 Medicación actualizada',
      coalesce(nm, 'Un atleta') || ' ha añadido un medicamento en Salud. Solo tú y el atleta podéis verlo.',
      './#cli', 1, null, 'hm-' || NEW.id);
    perform notify(it);
  end if;
  return NEW;
exception when others then return NEW; end $$;

drop trigger if exists trg_health_med_after_ins on public.health_meds;
create trigger trg_health_med_after_ins after insert on public.health_meds
  for each row execute function public.health_med_after_ins();

-- ---- permisos: solo por las funciones --------------------------------------------
revoke all on function public.health_med_list(text, text)                      from public;
revoke all on function public.health_med_list_coach(uuid)                      from public;
revoke all on function public.health_med_add(text, text, text, text, boolean)  from public;
revoke all on function public.health_med_del(text, text, uuid)                 from public;
revoke all on function public.health_med_after_ins()                           from public, anon, authenticated;
grant execute on function public.health_med_list(text, text)                      to anon, authenticated, service_role;
grant execute on function public.health_med_list_coach(uuid)                      to authenticated, service_role;
grant execute on function public.health_med_add(text, text, text, text, boolean)  to anon, authenticated, service_role;
grant execute on function public.health_med_del(text, text, uuid)                 to anon, authenticated, service_role;
-- las funciones nuevas heredan permisos por defecto de Supabase: se quita el acceso anónimo a la del entrenador
revoke execute on function public.health_med_list_coach(uuid) from anon;
