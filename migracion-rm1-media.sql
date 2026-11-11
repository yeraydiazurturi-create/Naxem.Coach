-- =====================================================================
-- Nexum · 1RM estimado = media de 6 fórmulas
-- Epley, Brzycki, Lombardi, O'Connor, Mayhew y Wathan.
-- Con 1 repetición (o menos) el 1RM es el propio peso.
-- Brzycki se excluye de la media si hay 37 o más repeticiones (división por cero).
-- Misma lógica que rm1() en index.html. Idempotente.
-- =====================================================================

create or replace function public.rm1_est(w numeric, r numeric)
returns numeric
language sql immutable parallel safe
set search_path = public
as $$
  select case
    when w is null or w <= 0 then null
    when r is null or r <= 1 then w
    else (select avg(x) from unnest(array[
      w * (1 + r / 30),                                       -- Epley
      case when r < 37 then w * 36 / (37 - r) end,            -- Brzycki
      w * power(r, 0.10),                                     -- Lombardi
      w * (1 + 0.025 * r),                                    -- O'Connor
      w * 100 / (52.2 + 41.9 * exp(-0.055 * r)),             -- Mayhew
      w * 100 / (48.8 + 53.8 * exp(-0.075 * r))              -- Wathan
    ]) as x)
  end
$$;

-- Ranking de la plantilla: la fuerza relativa usa ahora la misma estimación que la app.
create or replace function public.squad_ranking(p_u text default null::text, p_p text default null::text)
 returns table(id uuid, nombre text, yo boolean, best jsonb)
 language sql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
  with a as (select c.id, coalesce(c.coach_id,c.coach) co from public.clients c where p_u is not null and c.usr=lower(p_u) and c.pwd=crypt(p_p,c.pwd)),
  s as (select null::uuid id, auth.uid() co from public.coaches where id=auth.uid()),
  me as (select id, co, false staff from a union all select id, co, true from s where not exists(select 1 from a) limit 1)
  select c.id,
    initcap(split_part(trim(coalesce(nullif(c.data->'prof'->>'n',''),c.name)),' ',1))||coalesce(' '||left(nullif(split_part(trim(coalesce(nullif(c.data->'prof'->>'n',''),c.name)),' ',2),''),1)||'.',''),
    (c.id=me.id),
    coalesce((
      select jsonb_object_agg(x.k,x.val) from (
        select t.k,
          case when t.k in ('pb','ss','doml','pmh','hip') then
                 (select max(public.rm1_est((e->>'v')::numeric, coalesce((e->>'r')::numeric,1))) from jsonb_array_elements(t.v) e)/nullif(w.peso,0)
               when t.k in ('s10','s40','t5105','r2','r5') then (select min((e->>'v')::numeric) from jsonb_array_elements(t.v) e)
               else (select max((e->>'v')::numeric) from jsonb_array_elements(t.v) e) end val
        from jsonb_each(coalesce(c.data->'tests','{}'::jsonb)) t(k,v)
        left join lateral (select (e->>'v')::numeric peso from jsonb_array_elements(coalesce(c.data->'tests'->'pes','[]'::jsonb)) e order by e->>'d' desc limit 1) w on true
        where t.k in ('s10','s40','t5105','sj','cmj','cmja','dj','depj','pb','ss','dom','doml','pmh','hip','r2','r5','pi','coo','mo1','mo2','mo3','csq','cpi','cel','csd','chm')
          and jsonb_typeof(t.v)='array'
      ) x where x.val is not null),'{}'::jsonb)
  from public.clients c, me
  where coalesce(c.coach_id,c.coach)=me.co and (me.staff or c.id=me.id or (c.data->'prof'->>'rk') in ('true','1'));
$function$;
