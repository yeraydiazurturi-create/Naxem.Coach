-- ===== Nexum · Premium sin entrenador, solicitud de entrenador y chat Premium por solicitud (parte A) =====
-- Requiere migracion-sin-entrenador.sql y migracion-avisos.sql.

alter table public.clients
  add column if not exists quiere_entrenador boolean not null default false,
  add column if not exists entrenador_pedido_at timestamptz,
  add column if not exists pedido_nota text,
  add column if not exists premium boolean not null default false,
  add column if not exists premium_sub_id text;

-- Precio mensual del Premium (IVA incluido). Se cambia desde SQL: update app_config set value = to_jsonb(9.95::numeric) where key = 'premium_precio';
insert into public.app_config(key, value) values ('premium_precio', to_jsonb(9.95::numeric)) on conflict (key) do nothing;

-- Premium activo = atleta sin entrenador, marcado como Premium y con el pago vigente
create or replace function public.pm_activo(c public.clients) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(c.premium,false) and c.coach is null and c.coach_id is null and c.pago_estado = 'pagado'
          and c.pagado_hasta is not null and c.pagado_hasta > now() and not coalesce(c.suspendido,false) $$;

-- Solicitudes de chat entre atletas Premium
create table if not exists public.chat_dm_req(
  id bigserial primary key,
  from_id uuid not null references public.clients(id) on delete cascade,
  to_id uuid not null references public.clients(id) on delete cascade,
  estado text not null default 'pendiente' check (estado in ('pendiente','aceptada','rechazada','bloqueada')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (from_id, to_id));
create index if not exists chat_dm_req_to on public.chat_dm_req(to_id, estado);
create index if not exists chat_dm_req_from on public.chat_dm_req(from_id, created_at);
alter table public.chat_dm_req enable row level security;
alter table public.chat_dm alter column coach drop not null;

-- ¿Pueden hablar a y b? Mismo entrenador, o los dos Premium con la solicitud aceptada
create or replace function public.pm_ok(a uuid, b uuid) returns boolean language sql stable security definer set search_path = public as
$$ select a <> b and exists(
     select 1 from clients x join clients y on y.id = b
      where x.id = a and not coalesce(x.suspendido,false) and not coalesce(y.suspendido,false)
        and ((x.coach is not null and x.coach = y.coach)
          or (pm_activo(x) and pm_activo(y) and exists(select 1 from chat_dm_req r where r.estado = 'aceptada'
                and ((r.from_id = a and r.to_id = b) or (r.from_id = b and r.to_id = a)))))) $$;

-- ===== Chat directo: ahora también entre Premium con solicitud aceptada =====
create or replace function public.dm_contacts(p_u text, p_p text)
returns table(id uuid, nombre text, last_body text, last_kind text, last_at timestamptz, unread bigint, ph text, dm boolean)
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; begin me := dm_me(p_u, p_p);
 return query select c.id, c.name,
   (select case m.kind when 'text' then left(m.body,80) when 'image' then '📷 Foto' else m.kind end from chat_dm m where (m.from_id=me.id and m.to_id=c.id) or (m.from_id=c.id and m.to_id=me.id) order by m.id desc limit 1),
   (select m.kind from chat_dm m where (m.from_id=me.id and m.to_id=c.id) or (m.from_id=c.id and m.to_id=me.id) order by m.id desc limit 1),
   (select max(m.created_at) from chat_dm m where (m.from_id=me.id and m.to_id=c.id) or (m.from_id=c.id and m.to_id=me.id)),
   (select count(*) from chat_dm m where m.from_id=c.id and m.to_id=me.id and m.id>coalesce((select r.seen_id from chat_dm_read r where r.client_id=me.id and r.other_id=c.id),0)),
   case when coalesce(c.data->'prof'->>'photo','')<>'' then md5(c.data->'prof'->>'photo') end,
   coalesce(c.data->'prof'->>'dm','')<>'false'
  from clients c where c.id<>me.id and not coalesce(c.suspendido,false)
   and ((me.coach is not null and c.coach = me.coach)
     or (me.coach is null and pm_activo(me) and pm_activo(c) and exists(select 1 from chat_dm_req r where r.estado='aceptada' and ((r.from_id=me.id and r.to_id=c.id) or (r.from_id=c.id and r.to_id=me.id)))))
  order by 5 desc nulls last, 2; end $$;

create or replace function public.dm_send(p_u text, p_p text, p_other uuid, p_body text, p_kind text default 'text', p_url text default '')
returns void language plpgsql security definer set search_path = public, extensions as $$
declare me clients; o clients; begin me := dm_me(p_u, p_p);
 select * into o from clients where clients.id = p_other and pm_ok(me.id, p_other);
 if not found or coalesce(o.data->'prof'->>'dm','') = 'false' then raise exception 'No permitido'; end if;
 if p_kind not in ('text','image') then raise exception 'Datos no válidos'; end if;
 if length(trim(coalesce(p_body,''))) = 0 and coalesce(p_url,'') = '' then return; end if;
 if (select count(*) from chat_dm where from_id = me.id and created_at > now() - interval '1 minute') >= 20 then raise exception 'Demasiados mensajes seguidos'; end if;
 insert into chat_dm(coach, from_id, to_id, author, body, kind, url) values (me.coach, me.id, p_other, me.name, left(trim(coalesce(p_body,'')),1000), p_kind, coalesce(p_url,'')); end $$;

create or replace function public.dm_list(p_u text, p_p text, p_other uuid)
returns table(id bigint, mine boolean, body text, kind text, url text, created_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; o clients; mx bigint; begin me := dm_me(p_u, p_p);
 select * into o from clients where clients.id = p_other and pm_ok(me.id, p_other); if not found then raise exception 'No permitido'; end if;
 select max(m.id) into mx from chat_dm m where m.from_id = p_other and m.to_id = me.id;
 if mx is not null then insert into chat_dm_read(client_id, other_id, seen_id) values (me.id, p_other, mx) on conflict (client_id, other_id) do update set seen_id = greatest(chat_dm_read.seen_id, excluded.seen_id); end if;
 return query select * from (select m.id, (m.from_id = me.id), m.body, m.kind, m.url, m.created_at from chat_dm m where (m.from_id = me.id and m.to_id = p_other) or (m.from_id = p_other and m.to_id = me.id) order by m.id desc limit 200) x order by 1; end $$;

create or replace function public.dm_profile(p_u text, p_p text, p_other uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; o clients; hide boolean; pr jsonb; begin me := dm_me(p_u, p_p);
 select * into o from clients c where c.id = p_other and not coalesce(c.suspendido,false)
   and (pm_ok(me.id, c.id) or (pm_activo(me) and pm_activo(c) and not exists(select 1 from chat_dm_req r where r.estado='bloqueada' and ((r.from_id=me.id and r.to_id=c.id) or (r.from_id=c.id and r.to_id=me.id)))));
 if not found then raise exception 'No permitido'; end if;
 pr := coalesce(o.data->'prof','{}'::jsonb); hide := coalesce(pr->>'fh','') = 'true';
 return jsonb_build_object('id', o.id, 'name', o.name, 'photo', nullif(pr->>'photo',''), 'hide', hide,
   'bio', case when hide then null else nullif(left(pr->>'bio',140),'') end,
   'pub', case when hide then null else pr->'pub' end,
   'dm', coalesce(pr->>'dm','') <> 'false'); end $$;

create or replace function public.dm_photos(p_u text, p_p text, p_ids uuid[])
returns table(id uuid, photo text) language plpgsql security definer set search_path = public, extensions as $$
declare me clients; begin me := dm_me(p_u, p_p);
 return query select c.id, c.data->'prof'->>'photo' from clients c
   where c.id = any(p_ids) and coalesce(c.data->'prof'->>'photo','') <> ''
     and ((me.coach is not null and c.coach = me.coach) or (pm_activo(me) and pm_activo(c)
          and not exists(select 1 from chat_dm_req r where r.estado='bloqueada' and ((r.from_id=me.id and r.to_id=c.id) or (r.from_id=c.id and r.to_id=me.id)))))
   limit 40; end $$;

-- ===== Comunidad Premium: directorio, solicitudes, aceptar, rechazar y bloquear =====
create or replace function public.pm_dir(p_u text, p_p text)
returns table(id uuid, nombre text, ph text, bio text, rel text) language plpgsql security definer set search_path = public, extensions as $$
declare me clients; begin me := dm_me(p_u, p_p);
 if not pm_activo(me) then raise exception 'Solo para Premium'; end if;
 return query select c.id, c.name,
   case when coalesce(c.data->'prof'->>'photo','')<>'' then md5(c.data->'prof'->>'photo') end,
   case when coalesce(c.data->'prof'->>'fh','')='true' then null else nullif(left(c.data->'prof'->>'bio',140),'') end,
   coalesce((select case r.estado when 'aceptada' then 'aceptada'
        when 'pendiente' then case when r.from_id = me.id then 'enviada' else 'recibida' end
        when 'rechazada' then case when r.from_id = me.id and r.updated_at > now() - interval '30 days' then 'rechazada' else 'none' end
        else 'none' end
      from chat_dm_req r where (r.from_id = me.id and r.to_id = c.id) or (r.from_id = c.id and r.to_id = me.id) order by r.updated_at desc limit 1), 'none')
  from clients c where c.id <> me.id and pm_activo(c) and coalesce(c.data->'prof'->>'dm','') <> 'false'
   and not exists(select 1 from chat_dm_req r where r.estado = 'bloqueada' and ((r.from_id = me.id and r.to_id = c.id) or (r.from_id = c.id and r.to_id = me.id)))
  order by c.name limit 300; end $$;

create or replace function public.pm_req(p_u text, p_p text, p_other uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; o clients; r chat_dm_req; rv chat_dm_req; begin me := dm_me(p_u, p_p);
 if not pm_activo(me) then raise exception 'Solo para Premium'; end if;
 select * into o from clients c where c.id = p_other and c.id <> me.id and pm_activo(c) and coalesce(c.data->'prof'->>'dm','') <> 'false';
 if not found then raise exception 'Este atleta no está disponible'; end if;
 if exists(select 1 from chat_dm_req x where x.estado = 'bloqueada' and ((x.from_id = me.id and x.to_id = o.id) or (x.from_id = o.id and x.to_id = me.id))) then raise exception 'Este atleta no está disponible'; end if;
 if (select count(*) from chat_dm_req x where x.from_id = me.id and x.created_at > now() - interval '24 hours') >= 15 then raise exception 'Has enviado muchas solicitudes hoy. Prueba mañana.'; end if;
 if exists(select 1 from chat_dm_req x where x.estado = 'aceptada' and ((x.from_id = me.id and x.to_id = o.id) or (x.from_id = o.id and x.to_id = me.id))) then return 'aceptada'; end if;
 select * into rv from chat_dm_req x where x.from_id = o.id and x.to_id = me.id and x.estado = 'pendiente';
 if found then
  update chat_dm_req set estado = 'aceptada', updated_at = now() where id = rv.id;
  perform notify(jsonb_build_array(nx_item(o.id, 'client', 'chat', '✅ ' || me.name || ' ha aceptado tu solicitud', 'Ya podéis hablar por el chat.', './#chat', 1, null, 'pmok-' || rv.id || '-' || extract(epoch from now())::bigint)));
  return 'aceptada'; end if;
 select * into r from chat_dm_req x where x.from_id = me.id and x.to_id = o.id;
 if found then
  if r.estado = 'pendiente' then return 'enviada'; end if;
  if r.estado = 'rechazada' and r.updated_at > now() - interval '30 days' then raise exception 'Este atleta no está disponible'; end if;
  update chat_dm_req set estado = 'pendiente', created_at = now(), updated_at = now() where id = r.id;
 else
  insert into chat_dm_req(from_id, to_id) values (me.id, o.id) returning * into r;
 end if;
 perform notify(jsonb_build_array(nx_item(o.id, 'client', 'chat', '💬 ' || me.name || ' quiere chatear contigo', 'Acepta la solicitud en Chat para empezar a hablar.', './#chat', 1, 'pmreq-' || me.id, null)));
 return 'enviada'; end $$;

create or replace function public.pm_inbox(p_u text, p_p text)
returns table(id bigint, from_id uuid, nombre text, ph text, bio text, created_at timestamptz) language plpgsql security definer set search_path = public, extensions as $$
declare me clients; begin me := dm_me(p_u, p_p);
 if not pm_activo(me) then return; end if;
 return query select r.id, c.id, c.name,
   case when coalesce(c.data->'prof'->>'photo','')<>'' then md5(c.data->'prof'->>'photo') end,
   case when coalesce(c.data->'prof'->>'fh','')='true' then null else nullif(left(c.data->'prof'->>'bio',140),'') end, r.created_at
  from chat_dm_req r join clients c on c.id = r.from_id
  where r.to_id = me.id and r.estado = 'pendiente' and pm_activo(c) order by r.created_at desc limit 50; end $$;

create or replace function public.pm_answer(p_u text, p_p text, p_from uuid, p_accept boolean, p_block boolean default false) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; r chat_dm_req; e text; begin me := dm_me(p_u, p_p);
 select * into r from chat_dm_req x where x.from_id = p_from and x.to_id = me.id and x.estado = 'pendiente';
 if not found then return 'none'; end if;
 e := case when coalesce(p_block,false) then 'bloqueada' when coalesce(p_accept,false) then 'aceptada' else 'rechazada' end;
 update chat_dm_req set estado = e, updated_at = now() where id = r.id;
 if e = 'aceptada' then
  perform notify(jsonb_build_array(nx_item(p_from, 'client', 'chat', '✅ ' || me.name || ' ha aceptado tu solicitud', 'Ya podéis hablar por el chat.', './#chat', 1, null, 'pmok-' || r.id || '-' || extract(epoch from now())::bigint)));
 end if;
 return e; end $$;

create or replace function public.pm_block(p_u text, p_p text, p_other uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me clients; begin me := dm_me(p_u, p_p);
 if p_other is null or p_other = me.id then return; end if;
 update chat_dm_req set estado = 'bloqueada', updated_at = now() where (from_id = me.id and to_id = p_other) or (from_id = p_other and to_id = me.id);
 if not found then insert into chat_dm_req(from_id, to_id, estado) values (me.id, p_other, 'bloqueada'); end if; end $$;

revoke all on function public.pm_activo(public.clients), public.pm_ok(uuid, uuid) from public, anon, authenticated;
revoke all on function public.pm_dir(text,text), public.pm_req(text,text,uuid), public.pm_inbox(text,text), public.pm_answer(text,text,uuid,boolean,boolean), public.pm_block(text,text,uuid) from public;
grant execute on function public.pm_dir(text,text), public.pm_req(text,text,uuid), public.pm_inbox(text,text), public.pm_answer(text,text,uuid,boolean,boolean), public.pm_block(text,text,uuid) to anon, authenticated;

-- ===== Alta de atletas: con o sin solicitud de entrenador =====
drop function if exists public.client_signup(text, text, text);
create or replace function public.client_signup(p_name text, p_usr text, p_pwd text, p_quiere boolean default false, p_nota text default null)
returns text language plpgsql security definer set search_path to 'public','extensions' as $$
declare u text := lower(trim(coalesce(p_usr,''))); n text := left(trim(coalesce(p_name,'')), 60); q boolean := coalesce(p_quiere,false);
begin
  if length(n) < 2 then raise exception 'Escribe tu nombre'; end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuario no válido: 3-30 caracteres, sin espacios ni @'; end if;
  if length(coalesce(p_pwd,'')) < 6 then raise exception 'La contraseña debe tener 6 o más caracteres'; end if;
  if exists (select 1 from clients where usr = u) then raise exception 'Ese usuario ya existe, elige otro'; end if;
  insert into clients(name, usr, pwd, coach, coach_id, prueba_hasta, quiere_entrenador, entrenador_pedido_at, pedido_nota)
  values (n, u, crypt(p_pwd, gen_salt('bf')), null, null, now() + interval '7 days', q, case when q then now() end,
          case when q then nullif(left(trim(coalesce(p_nota,'')), 300), '') end);
  return n;
end $$;
grant execute on function public.client_signup(text, text, text, boolean, text) to anon, authenticated;

-- Un atleta sin entrenador pide (o retira la petición de) uno desde la app
create or replace function public.client_want_coach(p_u text, p_p text, p_quiere boolean default true, p_nota text default null) returns boolean
language plpgsql security definer set search_path to 'public','extensions' as $$
declare c record; q boolean := coalesce(p_quiere, true);
begin
  select * into c from clients where lower(usr) = lower(p_u) and pwd = crypt(p_p, pwd) limit 1;
  if not found then raise exception 'No permitido'; end if;
  if c.coach is not null or c.coach_id is not null then raise exception 'Ya tienes entrenador'; end if;
  update clients set quiere_entrenador = q, entrenador_pedido_at = case when q then now() end,
    pedido_nota = case when q then nullif(left(trim(coalesce(p_nota,'')), 300), '') end where id = c.id;
  return q;
end $$;
grant execute on function public.client_want_coach(text, text, boolean, text) to anon, authenticated;

-- ===== Acceso: añade Premium y solicitud de entrenador =====
create or replace function public.client_gate(p_u text, p_p text)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare c record; k record; ready boolean; paid boolean; trial boolean; solo boolean; susp boolean; owner boolean; prem boolean; pp numeric;
begin
  select * into c from public.clients where lower(usr) = lower(p_u) and pwd = crypt(p_p, pwd) limit 1;
  if not found then return null; end if;
  solo := c.coach_id is null and c.coach is null;
  select * into k from public.coaches where id = c.coach_id;
  owner := k.id is not null and coalesce(k.cobra_directo,false);
  susp := coalesce(c.suspendido,false) or coalesce(k.suspendido,false);
  ready := solo or (k.id is not null and coalesce(k.empresa_nombre,'') <> '' and coalesce(k.nif,'') <> ''
           and coalesce(k.iban_fin,'') <> ''
           and coalesce(k.precio_3,0) > 0 and coalesce(k.precio_6,0) > 0 and coalesce(k.precio_9,0) > 0
           and (owner or coalesce(k.stripe_charges_enabled,false) or coalesce(k.prueba_hasta, now() + interval '1 day') > now()));
  paid  := c.pago_estado = 'pagado' and c.pagado_hasta is not null and c.pagado_hasta > now();
  trial := not paid and solo and c.prueba_hasta is not null and c.prueba_hasta > now();
  prem  := solo and coalesce(c.premium,false) and paid;
  select coalesce((value #>> '{}')::numeric, 9.95) into pp from app_config where key = 'premium_precio';
  return jsonb_build_object('ok', ready and (paid or trial) and not susp, 'suspendido', susp,
    'coach_ready', ready, 'paid', paid,
    'prueba', trial, 'prueba_hasta', c.prueba_hasta, 'sin_coach', solo,
    'premium', prem, 'premium_precio', coalesce(pp, 9.95), 'quiere_entrenador', solo and coalesce(c.quiere_entrenador,false),
    'precio', coalesce(k.precio,0),
    'planes', jsonb_build_object('3', k.precio_3, '6', k.precio_6, '9', k.precio_9),
    'plan_meses', c.plan_meses,
    'coach', trim(coalesce(k.nombre,'') || ' ' || coalesce(k.apellidos,'')),
    'pay_url', k.pay_url, 'hasta', c.pagado_hasta,
    'stripe', owner or coalesce(k.stripe_charges_enabled,false),
    'suscrito', c.stripe_subscription_id is not null,
    'cuest', k.cuestionario,
    'coach_pres', case when k.presentacion is null then null else
       jsonb_build_object('video', k.presentacion->'video', 'bio', k.presentacion->'bio', 'redes', k.presentacion->'redes') end,
    'nutri', (select nz.nombre from nutri_clients nc join nutricionistas nz on nz.user_id = nc.nutri_id where nc.client_id = c.id limit 1));
end $$;
grant execute on function public.client_gate(text, text) to anon, authenticated;
notify pgrst, 'reload schema';


-- ===== Nexum · Premium sin entrenador (parte B): avisos, asignación de entrenador, facturas y panel de administración =====
-- Requiere la parte A (migracion-premium.sql).

create or replace function public.pm_precio_txt() returns text language sql stable security definer set search_path = public as
$$ select replace(to_char(coalesce((select (value #>> '{}')::numeric from app_config where key = 'premium_precio'), 9.95), 'FM990.00'), '.', ',') || ' €' $$;

-- Llama a la función `premium-cancel` para dar de baja la suscripción Premium en Stripe (no bloquea si falla)
create or replace function public.premium_cancel_post(p_sub text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u text; s text; begin
 if coalesce(p_sub,'') = '' then return; end if;
 select v into u from push_cfg where k = 'fn_url'; select v into s from push_cfg where k = 'secret';
 if u is null or s is null then return; end if;
 perform net.http_post(url := u || '/premium-cancel', body := jsonb_build_object('sub', p_sub),
   headers := jsonb_build_object('Content-Type','application/json','x-push-secret', s), timeout_milliseconds := 15000);
exception when others then null; end $$;

-- Al asignar entrenador a un atleta sin entrenador: se cierra su solicitud y, si era Premium, se cancela la suscripción
create or replace function public.trg_pm_before() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
 if OLD.coach is null and OLD.coach_id is null and (NEW.coach is not null or NEW.coach_id is not null) then
  NEW.quiere_entrenador := false; NEW.entrenador_pedido_at := null; NEW.pedido_nota := null;
  if coalesce(OLD.premium, false) then
   perform premium_cancel_post(coalesce(OLD.premium_sub_id, OLD.stripe_subscription_id));
   NEW.premium := false; NEW.premium_sub_id := null; NEW.stripe_subscription_id := null;
   NEW.pago_estado := 'pendiente'; NEW.pagado_hasta := null;
  end if;
 end if;
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists pm_before on public.clients;
create trigger pm_before before update on public.clients for each row execute function public.trg_pm_before();

-- Avisos: solicitud de entrenador, Premium activado, entrenador asignado
create or replace function public.trg_pm_after() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare it jsonb := '[]'; a record; nm text := coalesce(nullif(NEW.name,''), 'Un atleta'); cn text; cid uuid; ts text; pedido boolean;
begin
 if tg_op = 'INSERT' then pedido := NEW.quiere_entrenador; else pedido := NEW.quiere_entrenador and not OLD.quiere_entrenador; end if;
 if pedido then
  ts := extract(epoch from coalesce(NEW.entrenador_pedido_at, now()))::bigint::text;
  for a in select user_id from admins loop
   it := it || nx_item(a.user_id, 'staff', 'admin', '🙋 ' || nm || ' pide entrenador',
     coalesce(nullif(NEW.pedido_nota,''), 'Asígnale uno desde Atletas › Pide entrenador.'), './#adm', 2, null, 'adm-want-' || NEW.id || '-' || ts);
  end loop;
  it := it || nx_item(NEW.id, 'client', 'prueba', 'Solicitud enviada ✅', 'Estamos buscándote entrenador. Mientras tanto, disfruta de tu prueba de 7 días.', './', 1, null, 'want-' || NEW.id || '-' || ts);
 end if;
 if tg_op = 'UPDATE' then
  if NEW.premium and not OLD.premium then
   it := it || nx_item(NEW.id, 'client', 'pago', 'Bienvenido a Premium ⭐', 'Ya tienes todo Nexum y el chat con otros atletas Premium. Entra en Chat para conectar.', './#chat', 1, null, 'prem-' || NEW.id || '-' || extract(epoch from now())::bigint);
   for a in select user_id from admins loop
    it := it || nx_item(a.user_id, 'staff', 'admin', '⭐ Nuevo Premium: ' || nm, 'Suscripción Premium activa.', './#adm', 1, null, 'adm-prem-' || NEW.id || '-' || extract(epoch from now())::bigint);
   end loop;
  end if;
  if OLD.coach is null and OLD.coach_id is null and (NEW.coach is not null or NEW.coach_id is not null) then
   cid := coalesce(NEW.coach_id, NEW.coach);
   select trim(coalesce(nombre,'') || ' ' || coalesce(apellidos,'')) into cn from coaches where id = cid;
   it := it || nx_item(NEW.id, 'client', 'prueba', '🎉 Ya tienes entrenador',
     coalesce(nullif(cn,''), 'Tu entrenador') || ' es ahora tu entrenador en Nexum.' ||
     case when OLD.premium then ' Hemos cancelado tu suscripción Premium para que no se te cobre dos veces.' else '' end || ' Entra para continuar.',
     './', 2, null, 'assign-' || NEW.id || '-' || cid);
   it := it || nx_item(cid, 'staff', 'actividad', '🎉 Nuevo atleta: ' || nm, 'Te lo ha asignado Nexum. Prográmale su primera sesión.', './#cli', 1, null, 'assign-co-' || NEW.id || '-' || cid);
   if OLD.premium then
    for a in select user_id from admins loop
     it := it || nx_item(a.user_id, 'staff', 'admin', 'Premium cancelado: ' || nm, 'Se canceló su suscripción al asignarle entrenador. Si quieres, reembolsa el mes en Stripe.', './#adm', 1, null, 'adm-premx-' || NEW.id || '-' || cid);
    end loop;
   end if;
  end if;
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists pm_after_ins on public.clients;
drop trigger if exists pm_after_upd on public.clients;
create trigger pm_after_ins after insert on public.clients for each row execute function public.trg_pm_after();
create trigger pm_after_upd after update on public.clients for each row execute function public.trg_pm_after();

-- ===== Panel de administración =====
drop function if exists public.admin_clients();
create or replace function public.admin_clients()
returns table(id uuid, name text, usr text, coach_id uuid, coach_nombre text, prueba_hasta timestamptz, pago_estado text, pagado_hasta timestamptz,
              suspendido boolean, actualizado timestamptz, quiere_entrenador boolean, entrenador_pedido_at timestamptz, pedido_nota text, premium boolean)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  return query
  select c.id, c.name, c.usr, c.coach_id, nullif(trim(coalesce(co.nombre,'') || ' ' || coalesce(co.apellidos,'')), ''),
         c.prueba_hasta, c.pago_estado, c.pagado_hasta, c.suspendido, c.updated_at,
         (c.coach_id is null and c.coach is null and c.quiere_entrenador), c.entrenador_pedido_at, c.pedido_nota, public.pm_activo(c)
  from clients c left join coaches co on co.id = c.coach_id
  order by (c.coach_id is null and c.coach is null and c.quiere_entrenador) desc, c.updated_at desc nulls last;
end $$;
revoke all on function public.admin_clients() from public, anon;
grant execute on function public.admin_clients() to authenticated;

create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  select jsonb_build_object(
    'entrenadores', (select count(*) from coaches),
    'entrenadores_stripe', (select count(*) from coaches where stripe_charges_enabled),
    'entrenadores_prueba', (select count(*) from coaches where not coalesce(stripe_charges_enabled,false) and prueba_hasta > now()),
    'entrenadores_pagando', (select count(*) from coaches where sub_estado = 'active'),
    'mrr_entrenadores', coalesce((select sum(plan_precio) from coaches where sub_estado = 'active'), 0),
    'atletas', (select count(*) from clients),
    'atletas_sin_entrenador', (select count(*) from clients where coach_id is null and coach is null),
    'atletas_prueba', (select count(*) from clients where not (pago_estado = 'pagado' and pagado_hasta > now()) and prueba_hasta > now()),
    'atletas_pagando', (select count(*) from clients where pago_estado = 'pagado' and pagado_hasta > now()),
    'suspendidos', (select count(*) from clients where suspendido) + (select count(*) from coaches where suspendido),
    'entrenadores_7d', (select count(*) from coaches where created_at > now() - interval '7 days'),
    'bruto_mes', coalesce((select sum(co.precio) from clients c join coaches co on co.id = c.coach_id
                           where c.pago_estado = 'pagado' and c.pagado_hasta > now()), 0),
    'comision', coalesce((select (value #>> '{}')::numeric from app_config where key = 'comision'), 0),
    'atletas_premium', (select count(*) from clients c where public.pm_activo(c)),
    'solicitudes_entrenador', (select count(*) from clients where coach_id is null and coach is null and quiere_entrenador),
    'mrr_premium', coalesce((select count(*) from clients c where public.pm_activo(c)), 0)
                   * coalesce((select (value #>> '{}')::numeric from app_config where key = 'premium_precio'), 9.95)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;

-- Descartar una solicitud de entrenador desde el panel
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'admin_do';
  if (length(d) - length(replace(d, 'elsif p_action = ''resetpwd'' then', ''))) / length('elsif p_action = ''resetpwd'' then') <> 1 then raise exception 'admin_do: ancla no encontrada'; end if;
  d := replace(d, 'elsif p_action = ''resetpwd'' then',
    'elsif p_action = ''want'' then' || E'\n' ||
    '    update clients set quiere_entrenador = coalesce((p_arg->>''on'')::boolean, false), entrenador_pedido_at = case when coalesce((p_arg->>''on'')::boolean, false) then now() end,' || E'\n' ||
    '      pedido_nota = case when coalesce((p_arg->>''on'')::boolean, false) then pedido_nota end where id = p_id and coach_id is null and coach is null;' || E'\n' ||
    '  elsif p_action = ''resetpwd'' then');
  execute d;
end $$;

-- ===== Facturas del Premium (recibo a nombre de Nexum, IVA incluido) =====
create or replace function public.record_premium_invoice(p_stripe_invoice text, p_client uuid, p_total_cents integer, p_tax_cents integer, p_paid_at timestamptz default now())
returns bigint language plpgsql security definer set search_path to 'public','extensions' as $$
declare c record; v_fis jsonb; v_total numeric; v_iva numeric; v_base numeric; v_pct numeric; v_n int; v_y text; v_id bigint;
begin
  if p_stripe_invoice is not null and exists (select 1 from invoices where stripe_invoice_id = p_stripe_invoice) then return null; end if;
  if coalesce(p_total_cents, 0) <= 0 then return null; end if;
  select * into c from clients where id = p_client; if not found then return null; end if;
  select value into v_fis from app_config where key = 'nexum_fiscal';
  -- Sin los datos fiscales de Nexum no se numera ninguna factura: el atleta conserva el recibo de Stripe
  if v_fis is null or coalesce(v_fis->>'nombre','') = '' or coalesce(v_fis->>'nif','') = '' or coalesce(v_fis->>'direccion','') = '' then return null; end if;
  v_total := round(p_total_cents / 100.0, 2);
  v_iva   := round(coalesce(p_tax_cents, 0) / 100.0, 2);
  if v_iva <= 0 then v_iva := round(v_total - v_total / 1.21, 2); end if;
  v_base  := v_total - v_iva;
  v_pct   := case when v_base > 0 then round(v_iva * 100 / v_base, 2) else 0 end;
  if v_pct between 20.8 and 21.2 then v_pct := 21; end if;
  v_y     := to_char(coalesce(p_paid_at, now()), 'YYYY');
  v_n     := public.next_invoice_no('NX-' || v_y);
  insert into invoices(kind, numero, coach_id, client_id, emisor, receptor, concepto, base, iva_pct, iva, total, periodo, stripe_invoice_id, emitida)
  values ('nexum', 'NX-' || v_y || '-' || lpad(v_n::text, 4, '0'), null, c.id, v_fis,
    jsonb_build_object('nombre', c.name, 'nif', '', 'email', c.data->'prof'->>'email'),
    'Suscripción Nexum Premium · ' || to_char(coalesce(p_paid_at, now()), 'MM/YYYY'),
    v_base, v_pct, v_iva, v_total, to_char(coalesce(p_paid_at, now()), 'YYYY-MM'), p_stripe_invoice, coalesce(p_paid_at, now()))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.record_premium_invoice(text, uuid, integer, integer, timestamptz) from public, anon, authenticated;

create or replace function public.client_invoices(p_u text, p_p text)
returns jsonb language sql stable security definer set search_path to 'public','extensions' as $$
  select coalesce(jsonb_agg(to_jsonb(i) - 'comision_eur' - 'facturada_nexum' - 'stripe_invoice_id' - 'fiscal_ref' - 'fiscal_datos'
                            - 'fiscal_error' - 'fiscal_intentos' order by i.emitida desc), '[]'::jsonb)
  from public.clients c join public.invoices i on i.client_id = c.id and i.kind in ('atleta','nexum')
  where lower(c.usr) = lower(p_u) and c.pwd = crypt(p_p, c.pwd);
$$;

create or replace function public.trg_av_inv_ins()
returns trigger language plpgsql security definer set search_path to 'public','extensions' as $$
declare it jsonb:='[]';
begin
 if NEW.kind='atleta' and NEW.client_id is not null then
  it:=it||nx_item(NEW.client_id,'client','pago','🧾 Nueva factura disponible','Factura '||coalesce(NEW.numero,'')||' · '||to_char(coalesce(NEW.total,0),'FM999990.00')||' €. La tienes en tu cuenta.','./#acc',1,null,'inv-'||NEW.id);
 elsif NEW.kind='nexum' and NEW.client_id is not null then
  it:=it||nx_item(NEW.client_id,'client','pago','🧾 Factura de Nexum Premium','Factura '||coalesce(NEW.numero,'')||' · '||to_char(coalesce(NEW.total,0),'FM999990.00')||' €. La tienes en tu cuenta.','./#acc',1,null,'inv-'||NEW.id);
 elsif NEW.kind='nexum' and NEW.coach_id is not null then
  it:=it||nx_item(NEW.coach_id,'staff','pago','🧾 Factura de Nexum','Factura '||coalesce(NEW.numero,'')||' · '||to_char(coalesce(NEW.total,0),'FM999990.00')||' €.','./#cob',1,null,'inv-'||NEW.id);
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;

-- Recibos Premium: factura simplificada (F2) como las de los atletas con entrenador
do $$
declare d text; k text := 'if tipo = ''F1'' and p_kind = ''atleta'' and';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'fiscal_calc';
  if (length(d) - length(replace(d, k, ''))) / length(k) <> 1 then raise exception 'fiscal_calc: ancla no encontrada'; end if;
  d := replace(d, k, 'if tipo = ''F1'' and (p_kind = ''atleta'' or (p_kind = ''nexum'' and p_coach is null)) and');
  execute d;
end $$;

-- ===== Textos de los avisos diarios para atletas sin entrenador: ahora ofrecen Premium o entrenador =====
create or replace function pg_temp.rep(d text, o text, n text, c int default 1) returns text language plpgsql as $f$
declare k int; begin
  k := (length(d) - length(replace(d, o, ''))) / greatest(length(o), 1);
  if k <> c then raise exception 'avisos_daily: ancla % veces (esperado %): %', k, c, left(o, 70); end if;
  return replace(d, o, n); end $f$;

do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'avisos_daily';
  d := pg_temp.rep(d, 'Elige tu plan para volver a entrenar. Tu progreso está guardado.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador y vuelve a entrenar. Tu progreso está guardado.');
  d := pg_temp.rep(d, 'Elige tu plan para volver a entrenar justo donde lo dejaste.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador y vuelve a entrenar justo donde lo dejaste.');
  d := pg_temp.rep(d, 'Vuelve cuando quieras con un plan y retoma tu rutina.', 'Vuelve cuando quieras con Premium o con un entrenador y retoma tu rutina.', 2);
  d := pg_temp.rep(d, 'Elige tu plan y sigue donde lo dejaste.', 'Hazte Premium o pide un entrenador y sigue donde lo dejaste.', 2);
  d := pg_temp.rep(d, 'Elige tu plan ahora para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.');
  d := pg_temp.rep(d, 'Elige tu plan para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.');
  d := pg_temp.rep(d, 'Elige tu plan hoy y sigue entrenando sin cortes. No pierdes nada de lo que has hecho.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador hoy y sigue entrenando sin cortes. No pierdes nada de lo que has hecho.');
  d := pg_temp.rep(d, 'Elige tu plan hoy y sigue entrenando sin cortes. Tus entrenos, tus recetas y tu progreso se conservan.', 'Pásate a Premium ('' || pm_precio_txt() || ''/mes) o pide un entrenador hoy y sigue entrenando sin cortes. Tus entrenos, tus recetas y tu progreso se conservan.');
  d := pg_temp.rep(d, 'Elige tu plan para conservar tus entrenos, tu progreso y tus recetas.', 'Con Premium ('' || pm_precio_txt() || ''/mes) o con un entrenador conservas tus entrenos, tu progreso y tus recetas.');
  d := pg_temp.rep(d, '''Tu entrenador está pendiente de ti. Vuelve hoy con algo suave.''',
    'case when r.solo then ''Vuelve hoy con algo suave: una sesión corta basta para retomar el ritmo.'' else ''Tu entrenador está pendiente de ti. Vuelve hoy con algo suave.'' end');
  d := pg_temp.rep(d, '''Cuéntale a tu entrenador qué ha pasado: el plan se puede ajustar a tu momento.'',''./#chat''',
    'case when r.solo then ''Retoma con una sesión corta: lo importante es volver a empezar.'' else ''Cuéntale a tu entrenador qué ha pasado: el plan se puede ajustar a tu momento.'' end,case when r.solo then ''./#ent'' else ''./#chat'' end');
  d := pg_temp.rep(d, '''Cuéntale a tu entrenador cómo estás: sueño, energía y ánimo.''',
    'case when r.solo then ''Anota cómo estás: sueño, energía y ánimo. Te ayuda a ver tu evolución.'' else ''Cuéntale a tu entrenador cómo estás: sueño, energía y ánimo.'' end');
  execute d;
end $$;

revoke all on function public.pm_precio_txt(), public.premium_cancel_post(text), public.trg_pm_before(), public.trg_pm_after() from public, anon, authenticated;
notify pgrst, 'reload schema';
