-- Nexum v41 · Videollamadas (enlace externo Meet/Zoom/Teams)
-- Aditiva: no rompe versiones anteriores de la app.

-- 1) Eventos: tipo (event|call) y enlace de la sala
alter table public.events add column if not exists link text;
alter table public.events add column if not exists kind text not null default 'event';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='events_kind_chk') then
    alter table public.events add constraint events_kind_chk check (kind in ('event','call'));
  end if;
  if not exists (select 1 from pg_constraint where conname='events_link_chk') then
    alter table public.events add constraint events_link_chk check (link is null or (link ~* '^https?://' and length(link)<=500));
  end if;
end $$;

-- 2) Enlace personal de videollamada (entrenador, nutricionista, admin)
create table if not exists public.video_links(
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  url text not null check (url ~* '^https?://' and length(url)<=500),
  updated_at timestamptz not null default now()
);
alter table public.video_links enable row level security;
drop policy if exists vl_select on public.video_links;
drop policy if exists vl_insert on public.video_links;
drop policy if exists vl_update on public.video_links;
drop policy if exists vl_delete on public.video_links;
create policy vl_select on public.video_links for select to authenticated using (user_id=(select auth.uid()));
create policy vl_insert on public.video_links for insert to authenticated with check (user_id=(select auth.uid()));
create policy vl_update on public.video_links for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy vl_delete on public.video_links for delete to authenticated using (user_id=(select auth.uid()));

-- 3) Nutricionista: ver sus propios eventos y programar videollamadas con sus atletas
drop policy if exists ev_select_nutri on public.events;
create policy ev_select_nutri on public.events for select to authenticated
  using (owner=(select auth.uid()) and (select public.is_nutri()));

create or replace function public.nutri_event_add(p_client uuid, p_title text, p_notes text, p_day date, p_hora text, p_link text)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_coach uuid; v_name text; v_id bigint;
begin
  if not public.is_nutri() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from public.nutri_clients where nutri_id=auth.uid() and client_id=p_client) then
    raise exception 'Ese atleta no está asignado a tu cuenta'; end if;
  if p_link is null or p_link !~* '^https?://' then raise exception 'Enlace no válido'; end if;
  select coach_id into v_coach from public.clients where id=p_client;
  select nombre into v_name from public.nutricionistas where user_id=auth.uid();
  insert into public.events(scope,owner,owner_name,coach_id,client_id,title,notes,day,hora,kind,link)
  values('client',auth.uid(),coalesce(v_name,'Nutricionista'),v_coach,p_client,
         left(coalesce(nullif(p_title,''),'Videollamada'),120),left(coalesce(p_notes,''),500),p_day,p_hora,'call',left(p_link,500))
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.nutri_event_add(uuid,text,text,date,text,text) from public, anon;
grant execute on function public.nutri_event_add(uuid,text,text,date,text,text) to authenticated;

-- 4) Calendario del atleta: ahora devuelve tipo, enlace y quién lo programó (coach|nutri)
create or replace function public.client_events(p_u text, p_p text)
returns jsonb language sql stable security definer set search_path=public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',e.id,'title',e.title,'notes',e.notes,'day',e.day,'hora',e.hora,'by',e.owner_name,
      'all',e.client_id is null,'kind',e.kind,'link',e.link,
      'src',case when e.owner=c.coach_id then 'coach' else 'nutri' end
    ) order by e.day, e.hora),'[]'::jsonb)
  from clients c
  join events e on e.scope='client' and e.coach_id=c.coach_id and (e.client_id is null or e.client_id=c.id)
  where lower(c.usr)=lower(p_u) and c.pwd=crypt(p_p,c.pwd) and e.day>=current_date-90
$$;
