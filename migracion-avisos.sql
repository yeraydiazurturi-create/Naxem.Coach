-- ============================================================================
-- Nexum · Centro de avisos y notificaciones (v62)
-- Ya aplicado en el proyecto. Se guarda aquí como copia para poder reproducirlo.
-- Requiere migracion-notificaciones.sql. Orden: parte A, B, C y permisos.
-- Interruptores de emergencia (SQL editor):
--   update push_cfg set v='off' where k='avisos';       -- apaga TODOS los avisos nuevos
--   update push_cfg set v='off' where k='avisos_mail';  -- apaga solo los correos
-- Para volver a encender: v='on'.
-- Correo: hace falta definir en Supabase › Edge Functions › Secrets GMAIL_USER + GMAIL_APP_PASSWORD (o RESEND_API_KEY) y desplegar send-email.ts.
-- ============================================================================

-- ===== Nexum · avisos (parte A): tablas, centro de avisos, despachador con tope =====
-- Requiere migracion-notificaciones.sql (push_cfg, push_subs, push_log, push_who, push_post, email_post).

-- Interruptores: push_cfg('avisos') = 'off' apaga todos los avisos nuevos; push_cfg('avisos_mail') = 'off' apaga solo los correos.
insert into public.push_cfg(k,v) values ('avisos','on'),('avisos_mail','on') on conflict(k) do nothing;
create or replace function public.avisos_flag(p_k text) returns boolean language sql stable security definer set search_path=public as
$$ select coalesce((select v from push_cfg where k=p_k),'on')<>'off' $$;

alter table public.coaches add column if not exists avisos_mail boolean not null default true;

-- Centro de avisos (la campana). Sin políticas: solo se lee y escribe mediante las funciones de abajo.
create table if not exists public.notifs(
 id bigserial primary key,
 owner uuid not null,
 kind text not null default 'staff' check (kind in ('client','staff')),
 type text not null default 'sistema',
 title text not null,
 body text not null default '',
 url text not null default './',
 prio smallint not null default 1,
 want_push boolean not null default false,
 pushed_at timestamptz,
 created_at timestamptz not null default now(),
 read_at timestamptz);
create index if not exists notifs_owner_id on public.notifs(owner,id desc);
create index if not exists notifs_pend on public.notifs(owner) where want_push and pushed_at is null and read_at is null;
alter table public.notifs enable row level security;

-- Utilidades sobre los datos del atleta
create or replace function public.jarr(j jsonb) returns jsonb language sql immutable as
$$ select case when jsonb_typeof(j)='array' then j else '[]'::jsonb end $$;

create or replace function public.cl_done(d jsonb) returns int language sql immutable as
$$ select count(*)::int from jsonb_array_elements(public.jarr(d->'sessions')) s where s->>'done'='true' $$;

create or replace function public.cl_last(d jsonb) returns text language sql immutable as
$$ select max(s->>'date') from jsonb_array_elements(public.jarr(d->'sessions')) s where s->>'done'='true' and coalesce(s->>'date','')<>'' $$;

-- Entrenos de un día que siguen sin hacer (fechados y semanales; dow: 0 = lunes … 6 = domingo)
create or replace function public.cl_pend(d jsonb, dd date) returns text[] language sql stable as
$$ select coalesce(array_agg(coalesce(nullif(s->>'name',''),'Entreno')),'{}'::text[]) from jsonb_array_elements(public.jarr(d->'sessions')) s
 where coalesce(s->>'done','false')<>'true' and (
  (coalesce(s->>'rec','false')<>'true' and s->>'date'=to_char(dd,'YYYY-MM-DD'))
  or (s->>'rec'='true' and jsonb_typeof(s->'dow')='array' and (s->'dow') @> to_jsonb(extract(isodow from dd)::int-1)
      and coalesce(nullif(s->>'start',''),'0000-00-00')<=to_char(dd,'YYYY-MM-DD')
      and not exists(select 1 from jsonb_array_elements(public.jarr(d->'sessions')) c where c->>'from'=s->>'id' and c->>'date'=to_char(dd,'YYYY-MM-DD') and c->>'done'='true'))) $$;

-- Constructores de avisos y de correos
create or replace function public.nx_item(p_owner uuid,p_kind text,p_type text,p_title text,p_body text,p_url text default './',p_prio int default 1,
  p_once text default null,p_ever text default null,p_mail jsonb default null,p_push boolean default true,p_bell boolean default true) returns jsonb language sql immutable as
$$ select jsonb_strip_nulls(jsonb_build_object('owner',p_owner,'kind',p_kind,'type',p_type,'title',p_title,'body',p_body,'url',p_url,'prio',p_prio,
   'once',p_once,'ever',p_ever,'mail',p_mail,'push',p_push,'bell',p_bell)) $$;

create or replace function public.nx_mail(p_to text,p_name text,p_title text,p_body text,p_cta text default 'Abrir Nexum') returns jsonb language sql immutable as
$$ select case when coalesce(p_to,'')~'^[^@\s]+@[^@\s]+\.[^@\s]+$' then jsonb_build_object('template','aviso','to',p_to,'data',jsonb_build_object('name',p_name,'title',p_title,'body',p_body,'cta',p_cta)) end $$;

-- Despachador único: guarda el aviso en la campana, lo envía por push (tope de 2 al día, de 9:00 a 21:00; lo que no cabe espera a la mañana siguiente)
-- y, si lleva correo, lo envía por email.
--  once = no repetir el mismo aviso el mismo día · ever = no repetirlo nunca · bell=false = solo correo · prio 2 = ignora el tope
create or replace function public.notify(p_items jsonb) returns void language plpgsql security definer set search_path=public,extensions as $$
declare r record; pu jsonb:='[]'; ma jsonb:='[]';
 v_h int:=extract(hour from (now() at time zone 'Europe/Madrid'))::int;
 v_dd date:=(now() at time zone 'Europe/Madrid')::date;
 v_d0 timestamptz:=(((now() at time zone 'Europe/Madrid')::date)::timestamp) at time zone 'Europe/Madrid';
 nid bigint; npush int; okp boolean; subs boolean; kd text; mail_on boolean:=avisos_flag('avisos_mail');
begin
 if not avisos_flag('avisos') or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then return; end if;
 for r in select * from jsonb_to_recordset(p_items) as x(owner uuid,kind text,type text,title text,body text,url text,prio int,once text,ever text,mail jsonb,push boolean,bell boolean) loop
  continue when r.owner is null;
  if r.ever is not null then
   insert into push_log(owner,tag,day) values(r.owner,left(r.ever,120),date '2000-01-01') on conflict do nothing;
   continue when not found;
  elsif r.once is not null then
   insert into push_log(owner,tag,day) values(r.owner,left(r.once,120),v_dd) on conflict do nothing;
   continue when not found;
  end if;
  if mail_on and r.mail is not null then ma:=ma||jsonb_build_array(r.mail); end if;
  if coalesce(r.bell,true)=false or coalesce(btrim(r.title),'')='' then continue; end if;
  kd:=coalesce(r.kind,case when exists(select 1 from clients where id=r.owner) then 'client' else 'staff' end);
  subs:=exists(select 1 from push_subs where owner=r.owner);
  insert into notifs(owner,kind,type,title,body,url,prio,want_push)
   values(r.owner,kd,coalesce(r.type,'sistema'),left(r.title,120),left(coalesce(r.body,''),300),coalesce(r.url,'./'),coalesce(r.prio,1),coalesce(r.push,true) and subs)
   returning id into nid;
  okp:=false;
  if coalesce(r.push,true) and subs and v_h>=9 and v_h<21 then
   select count(distinct pushed_at) into npush from notifs where owner=r.owner and pushed_at>=v_d0;
   okp:=coalesce(r.prio,1)>=2 or npush<2;
  end if;
  if okp then
   update notifs set pushed_at=clock_timestamp() where id=nid;
   pu:=pu||jsonb_build_array(jsonb_build_object('owner',r.owner,'kind',coalesce(r.type,'sistema'),'title',left(r.title,80),'body',left(coalesce(r.body,''),180),'url',coalesce(r.url,'./'),'tag','nx-'||nid));
  end if;
 end loop;
 perform push_post(pu);
 perform email_post(ma);
end $$;

-- Envío diferido: de 9:00 a 21:00, avisos que no pudieron enviarse (de noche o por el tope). Si hay varios, un solo push resumen.
create or replace function public.avisos_flush() returns void language plpgsql security definer set search_path=public,extensions as $$
declare r record; pu jsonb:='[]'; npush int; ts timestamptz;
 v_h int:=extract(hour from (now() at time zone 'Europe/Madrid'))::int;
 v_d0 timestamptz:=(((now() at time zone 'Europe/Madrid')::date)::timestamp) at time zone 'Europe/Madrid';
begin
 if v_h<9 or v_h>=21 or not avisos_flag('avisos') then return; end if;
 for r in select owner,count(*) n,max(prio) mp,(array_agg(title order by id desc))[1] t1,(array_agg(body order by id desc))[1] b1,
     (array_agg(url order by id desc))[1] u1,(array_agg(type order by id desc))[1] ty
    from notifs where want_push and pushed_at is null and read_at is null and created_at>now()-interval '20 hours' group by owner loop
  select count(distinct pushed_at) into npush from notifs where owner=r.owner and pushed_at>=v_d0;
  continue when npush>=2 and r.mp<2;
  ts:=clock_timestamp();
  update notifs set pushed_at=ts where owner=r.owner and want_push and pushed_at is null and read_at is null and created_at>now()-interval '20 hours';
  pu:=pu||jsonb_build_array(jsonb_build_object('owner',r.owner,'kind',case when r.n=1 then r.ty else 'avisos' end,
    'title',case when r.n=1 then r.t1 else 'Tienes '||r.n||' avisos nuevos' end,
    'body',case when r.n=1 then r.b1 else r.t1||' y '||(r.n-1)||' más' end,
    'url',case when r.n=1 then r.u1 else './#avisos' end,'tag','nx-flush'));
 end loop;
 perform push_post(pu);
end $$;

-- Lectura desde la app (atleta con usuario+clave, o personal con sesión)
create or replace function public.notif_list(p_u text,p_p text,p_limit int default 40) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare w record; begin select * into w from push_who(p_u,p_p);
 return jsonb_build_object('unread',(select count(*) from notifs where owner=w.o and read_at is null),
  'items',coalesce((select jsonb_agg(x) from (select id,type,title,body,url,prio,created_at,read_at from notifs where owner=w.o order by id desc limit least(greatest(coalesce(p_limit,40),1),100)) x),'[]'::jsonb)); end $$;

create or replace function public.notif_unread(p_u text,p_p text) returns int language plpgsql security definer set search_path=public,extensions as $$
declare w record; begin select * into w from push_who(p_u,p_p);
 return (select count(*)::int from notifs where owner=w.o and read_at is null); end $$;

create or replace function public.notif_read(p_u text,p_p text,p_ids bigint[] default null) returns void language plpgsql security definer set search_path=public,extensions as $$
declare w record; begin select * into w from push_who(p_u,p_p);
 update notifs set read_at=now() where owner=w.o and read_at is null and (p_ids is null or id=any(p_ids)); end $$;

revoke all on function public.notify(jsonb), public.avisos_flush() from public, anon, authenticated;
grant execute on function public.notif_list(text,text,int), public.notif_unread(text,text), public.notif_read(text,text,bigint[]) to anon, authenticated;


-- ===== Nexum · avisos (parte B): avisos por eventos (triggers) =====

-- Nuevo atleta: bienvenida al atleta, aviso al entrenador y al administrador
create or replace function public.trg_av_cl_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; n int; a record; cn text;
begin
 it:=it||nx_item(NEW.id,'client','prueba','Bienvenido a Nexum 👋','Empieza por tu cuestionario y tu primer entreno. Tu entrenador lo verá al instante.','./#ent',1,null,'welcome',null,false);
 if NEW.coach is not null then
  select count(*) into n from clients where coach=NEW.coach and not coalesce(suspendido,false);
  it:=it||nx_item(NEW.coach,'staff','actividad','🎉 Nuevo atleta: '||coalesce(NEW.name,''),
    case when n=1 then '¡Es tu primer atleta! Prográmale su primera sesión.' else 'Ya son '||n||' atletas en tu equipo. Prográmale su primera sesión.' end,'./#cli',1,null,'newcl-'||NEW.id);
  select nombre into cn from coaches where id=NEW.coach;
 end if;
 for a in select user_id from admins loop
  it:=it||nx_item(a.user_id,'staff','admin','Nuevo atleta en Nexum',coalesce(NEW.name,'')||case when NEW.coach is null then ' · sin entrenador (prueba de 7 días)' else ' · con '||coalesce(cn,'un entrenador') end,'./#adm',1,null,'adm-newcl-'||NEW.id);
 end loop;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_cl_ins on public.clients;
create trigger av_cl_ins after insert on public.clients for each row execute function public.trg_av_cl_ins();

-- Atleta: entreno completado, hitos, plan actualizado, pago, primer email
create or replace function public.trg_av_cl_upd() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; n0 int; n1 int; v_id text; v_nm text; a record; nm text:=coalesce(nullif(NEW.name,''),'Un atleta'); ttl text; bdy text; em text; solo boolean;
begin
 if OLD.data is not distinct from NEW.data and OLD.pago_estado is not distinct from NEW.pago_estado then return NEW; end if;
 solo:=NEW.coach is null and NEW.coach_id is null;
 n0:=cl_done(OLD.data); n1:=cl_done(NEW.data);
 if n1>n0 then
  select s->>'id',coalesce(nullif(s->>'name',''),'su entreno') into v_id,v_nm from jsonb_array_elements(jarr(NEW.data->'sessions')) s
   where s->>'done'='true' and not exists(select 1 from jsonb_array_elements(jarr(OLD.data->'sessions')) o where o->>'id'=s->>'id' and o->>'done'='true')
   order by s->>'date' desc nulls last limit 1;
  if NEW.coach is not null then
   it:=it||nx_item(NEW.coach,'staff','actividad','💪 '||nm||' ha entrenado','«'||coalesce(v_nm,'su entreno')||'» completado.','./#cli',1,null,'done-'||NEW.id||'-'||coalesce(v_id,n1::text));
  end if;
  if n1 in (1,3,5,10,25,50,100,200) then
   select t,b into ttl,bdy from (values
     (1,'🔥 ¡Primer entreno completado!','Así se empieza. Tu constancia arranca hoy.'),
     (3,'⚡ 3 entrenos completados','Ya estás cogiendo ritmo. ¡Sigue así!'),
     (5,'💪 5 entrenos completados','Esto ya es un hábito en construcción.'),
     (10,'🏆 10 entrenos completados','Doble dígito. Tu yo de hace un mes estaría orgulloso.'),
     (25,'🏅 25 entrenos completados','Un cuarto de centenar. La constancia gana.'),
     (50,'🥇 50 entrenos completados','Medio centenar. Eres de los que no fallan.'),
     (100,'👑 100 entrenos completados','Cien sesiones. Esto ya es otro nivel.'),
     (200,'🚀 200 entrenos completados','Doscientas. Leyenda.')) v(n,t,b) where v.n=n1;
   it:=it||nx_item(NEW.id,'client','logro',ttl,bdy,'./#pro',1,null,'logro-'||n1);
  end if;
 end if;
 if coalesce(NEW.data->>'pu','')<>coalesce(OLD.data->>'pu','') and NEW.coach is not null then
  it:=it||nx_item(NEW.id,'client','plan','🗓️ Tu entrenador ha actualizado tu plan','Hay cambios en tus entrenos. Échales un vistazo.','./#ent',1,'plan');
 end if;
 if NEW.pago_estado='pagado' and OLD.pago_estado is distinct from 'pagado' then
  it:=it||nx_item(NEW.id,'client','pago','Pago recibido ✅','Ya tienes acceso completo a tu plan. ¡A por ello!','./',1,'paid');
  if NEW.coach is not null then
   it:=it||nx_item(NEW.coach,'staff','pago','💶 '||nm||' ha pagado','Su plan está activo y ya puede entrenar.','./#cli',2,'paid-'||NEW.id);
  end if;
  for a in select user_id from admins loop
   it:=it||nx_item(a.user_id,'staff','admin','💶 Atleta de pago: '||nm,'Ha activado su plan.','./#adm',1,'adm-paid-'||NEW.id);
  end loop;
 end if;
 em:=NEW.data->'prof'->>'email';
 if coalesce(OLD.data->'prof'->>'email','')='' and coalesce(em,'')<>'' and (NEW.data->'prof'->>'maila') is distinct from 'false' then
  it:=it||nx_item(NEW.id,'client','prueba','','',  './',1,null,'welcome-mail',
    nx_mail(em,nm,'Bienvenido a Nexum',
      case when solo then 'Tu cuenta está lista y tienes 7 días de prueba gratis.' else 'Tu entrenador te ha dado de alta en Nexum.' end
      ||E'\nPara empezar: 1) completa tu cuestionario inicial (unos 8 minutos), 2) haz tu primer entreno, 3) cuéntale cómo estás en tu primer check-in.'
      ||E'\nConsejo: abre Nexum desde el móvil y elige «Añadir a pantalla de inicio» para usarla como una app y recibir avisos.','Entrar en Nexum'),false,false);
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_cl_upd on public.clients;
create trigger av_cl_upd after update on public.clients for each row execute function public.trg_av_cl_upd();

-- Entrenador: bienvenida, correo de bienvenida, aviso al administrador, suscripción, impago, baja, Stripe conectado
create or replace function public.trg_av_co_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; a record; nm text:=coalesce(nullif(NEW.nombre,''),'entrenador'); lbl text:=trim(coalesce(NEW.nombre,'')||' '||coalesce(NEW.apellidos,''));
begin
 it:=it||nx_item(NEW.id,'staff','prueba','Bienvenido a Nexum 🚀','Tienes 7 días de prueba gratis. Configura tu cuenta y da de alta a tu primer atleta.','./#cob',1,null,'welcome',null,false);
 if coalesce(NEW.avisos_mail,true) and coalesce(NEW.email,'')<>'' then
  it:=it||nx_item(NEW.id,'staff','prueba','','','./',1,null,'welcome-mail',
   nx_mail(NEW.email,nm,'Bienvenido a Nexum',
    'Tu cuenta de entrenador ya está activa y tienes 7 días de prueba gratuita.'
    ||E'\nPara empezar: 1) completa los datos de tu empresa y tu precio, 2) da de alta a tu primer atleta, 3) prográmale su primera sesión. Se repite cada semana sin que tengas que tocarla.'
    ||E'\nCada vez que uno de tus atletas entrene, recibirás un aviso.','Configurar mi cuenta'),false,false);
 end if;
 for a in select a2.user_id,coalesce(a2.nombre,'') nom,(select u.email from auth.users u where u.id=a2.user_id) em from admins a2 loop
  it:=it||nx_item(a.user_id,'staff','admin','🚀 Nuevo entrenador en Nexum',lbl||case when coalesce(NEW.localidad,'')<>'' then ' · '||NEW.localidad else '' end||case when coalesce(NEW.email,'')<>'' then ' · '||NEW.email else '' end,'./#adm',2,null,'adm-newco-'||NEW.id,
    nx_mail(a.em,coalesce(nullif(a.nom,''),'Yeray'),'Nuevo entrenador en Nexum',lbl||' se ha registrado y está en su prueba de 7 días.'||case when coalesce(NEW.email,'')<>'' then E'\nCorreo: '||NEW.email else '' end,'Abrir el panel'));
 end loop;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_co_ins on public.coaches;
create trigger av_co_ins after insert on public.coaches for each row execute function public.trg_av_co_ins();

create or replace function public.trg_av_co_upd() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; a record; nm text:=coalesce(nullif(NEW.nombre,''),'entrenador'); lbl text:=trim(coalesce(NEW.nombre,'')||' '||coalesce(NEW.apellidos,''));
begin
 if coalesce(OLD.email,'')='' and coalesce(NEW.email,'')<>'' and coalesce(NEW.avisos_mail,true) then
  it:=it||nx_item(NEW.id,'staff','prueba','','','./',1,null,'welcome-mail',
   nx_mail(NEW.email,nm,'Bienvenido a Nexum',
    'Tu cuenta de entrenador ya está activa y tienes 7 días de prueba gratuita.'
    ||E'\nPara empezar: 1) completa los datos de tu empresa y tu precio, 2) da de alta a tu primer atleta, 3) prográmale su primera sesión.','Configurar mi cuenta'),false,false);
 end if;
 if OLD.stripe_subscription_id is null and NEW.stripe_subscription_id is not null then
  it:=it||nx_item(NEW.id,'staff','pago','Suscripción activada ✅','Gracias por confiar en Nexum. Tu cuenta sigue activa sin límites.','./#cob',2,'sub-ok');
  for a in select a2.user_id,coalesce(a2.nombre,'') nom,(select u.email from auth.users u where u.id=a2.user_id) em from admins a2 loop
   it:=it||nx_item(a.user_id,'staff','admin','💳 '||lbl||' se ha suscrito','Un entrenador más de pago en Nexum.','./#adm',2,null,'adm-sub-'||NEW.id,
     nx_mail(a.em,coalesce(nullif(a.nom,''),'Yeray'),'Nueva suscripción en Nexum',lbl||' se ha suscrito a Nexum.','Abrir el panel'));
  end loop;
 end if;
 if NEW.sub_estado='past_due' and OLD.sub_estado is distinct from 'past_due' then
  it:=it||nx_item(NEW.id,'staff','pago','⚠️ No hemos podido cobrar tu suscripción','Actualiza tu método de pago para no perder el acceso de tus atletas.','./#cob',2,'pastdue',null,
    nx_mail(NEW.email,nm,'No hemos podido cobrar tu suscripción','El último cobro de tu suscripción de Nexum ha fallado. Actualiza tu método de pago para que tus atletas no pierdan el acceso.','Actualizar el pago'));
  for a in select user_id from admins loop
   it:=it||nx_item(a.user_id,'staff','admin','⚠️ Cobro fallido: '||lbl,'Su suscripción está en impago.','./#adm',1,'adm-pd-'||NEW.id);
  end loop;
 end if;
 if NEW.sub_estado='canceled' and OLD.sub_estado is distinct from 'canceled' then
  it:=it||nx_item(NEW.id,'staff','pago','Suscripción cancelada','Tus datos siguen guardados. Puedes reactivar tu plan cuando quieras.','./#cob',1,'sub-cancel');
  for a in select user_id from admins loop
   it:=it||nx_item(a.user_id,'staff','admin','Baja de suscripción: '||lbl,'Ha cancelado su plan.','./#adm',1,'adm-cancel-'||NEW.id);
  end loop;
 end if;
 if NEW.stripe_charges_enabled and not coalesce(OLD.stripe_charges_enabled,false) then
  it:=it||nx_item(NEW.id,'staff','pago','Stripe conectado ✅','Ya puedes cobrar a tus atletas desde Nexum.','./#cob',1,null,'stripe-ok');
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_co_upd on public.coaches;
create trigger av_co_upd after update on public.coaches for each row execute function public.trg_av_co_upd();

-- Agenda: cita o videollamada nueva
create or replace function public.trg_av_ev_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; c record; ttl text; bdy text;
begin
 ttl:=(case when NEW.kind='call' then '📹 Videollamada: ' else '📅 Nueva cita: ' end)||NEW.title;
 bdy:=to_char(NEW.day,'DD/MM')||case when coalesce(NEW.hora,'')<>'' then ' a las '||NEW.hora else '' end;
 if NEW.scope='client' then
  for c in select id from clients where coach=NEW.coach_id and not coalesce(suspendido,false) and (NEW.client_id is null or id=NEW.client_id) loop
   it:=it||nx_item(c.id,'client','agenda',ttl,bdy,'./',1,null,'ev-'||NEW.id||'-'||c.id);
  end loop;
 else
  for c in select id from coaches where not coalesce(suspendido,false) and id<>NEW.owner union select user_id from admins where user_id<>NEW.owner loop
   it:=it||nx_item(c.id,'staff','agenda',ttl,bdy,'./#agd',1,null,'ev-'||NEW.id||'-'||c.id);
  end loop;
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_ev_ins on public.events;
create trigger av_ev_ins after insert on public.events for each row execute function public.trg_av_ev_ins();

-- Facturas
create or replace function public.trg_av_inv_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]';
begin
 if NEW.kind='atleta' and NEW.client_id is not null then
  it:=it||nx_item(NEW.client_id,'client','pago','🧾 Nueva factura disponible','Factura '||coalesce(NEW.numero,'')||' · '||to_char(coalesce(NEW.total,0),'FM999990.00')||' €. La tienes en tu cuenta.','./#acc',1,null,'inv-'||NEW.id);
 elsif NEW.kind='nexum' and NEW.coach_id is not null then
  it:=it||nx_item(NEW.coach_id,'staff','pago','🧾 Factura de Nexum','Factura '||coalesce(NEW.numero,'')||' · '||to_char(coalesce(NEW.total,0),'FM999990.00')||' €.','./#cob',1,null,'inv-'||NEW.id);
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_inv_ins on public.invoices;
create trigger av_inv_ins after insert on public.invoices for each row execute function public.trg_av_inv_ins();

-- Nutricionista asignado
create or replace function public.trg_av_nc_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; nm text;
begin
 select name into nm from clients where id=NEW.client_id;
 it:=it||nx_item(NEW.nutri_id,'staff','actividad','🥗 Nuevo atleta asignado: '||coalesce(nm,''),'Ya puedes ver su plan y escribirle por el chat.','./',1,null,'nc-'||NEW.client_id||'-'||NEW.nutri_id);
 it:=it||nx_item(NEW.client_id,'client','plan','🥗 Ya tienes nutricionista','Puede ver tu plan y escribirte por el chat.','./#chat',1,null,'nc-cl-'||NEW.nutri_id);
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_nc_ins on public.nutri_clients;
create trigger av_nc_ins after insert on public.nutri_clients for each row execute function public.trg_av_nc_ins();

-- Chat del equipo (entrenadores) y mensajes directos entre entrenadores: solo push (como el resto del chat)
create or replace function public.trg_av_staff_chat() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; pv text; c record;
begin
 pv:=push_prev(NEW.kind,NEW.body);
 if TG_TABLE_NAME='chat_staff' then
  for c in select id from coaches where not coalesce(suspendido,false) and id<>NEW.author_id union select user_id from admins where user_id<>NEW.author_id union select user_id from nutricionistas where user_id<>NEW.author_id loop
   it:=it||jsonb_build_array(jsonb_build_object('owner',c.id,'kind','chat','title','Chat del equipo · '||coalesce(NEW.author,''),'body',pv,'url','./#chat','tag','staff'));
  end loop;
 else
  it:=jsonb_build_array(jsonb_build_object('owner',case when NEW.author_id=NEW.a then NEW.b else NEW.a end,'kind','chat','title','Mensaje de '||coalesce(NEW.author,'un compañero'),'body',pv,'url','./#chat','tag','cdm-'||NEW.author_id));
 end if;
 perform push_post(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_staff_chat on public.chat_staff;
create trigger av_staff_chat after insert on public.chat_staff for each row execute function public.trg_av_staff_chat();
drop trigger if exists av_cdm_chat on public.chat_cdm;
create trigger av_cdm_chat after insert on public.chat_cdm for each row execute function public.trg_av_staff_chat();

-- Ofertas de patrocinadores: solo campana, sin push
create or replace function public.trg_av_ad_ins() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; sp record; c record;
begin
 if not coalesce(NEW.activo,true) then return NEW; end if;
 select nombre,aud into sp from sponsors where id=NEW.sponsor_id;
 if sp.nombre is null then return NEW; end if;
 if sp.aud in ('todos','atletas') then
  for c in select id from clients where not coalesce(suspendido,false) loop
   it:=it||nx_item(c.id,'client','sistema','🎁 Nueva oferta: '||NEW.titulo,sp.nombre||case when coalesce(NEW.descuento,'')<>'' then ' · '||NEW.descuento else '' end,'./',0,null,'ad-'||NEW.id,null,false);
  end loop;
 end if;
 if sp.aud in ('todos','entrenadores') then
  for c in select id from coaches where not coalesce(suspendido,false) loop
   it:=it||nx_item(c.id,'staff','sistema','🎁 Nueva oferta: '||NEW.titulo,sp.nombre||case when coalesce(NEW.descuento,'')<>'' then ' · '||NEW.descuento else '' end,'./',0,null,'ad-'||NEW.id,null,false);
  end loop;
 end if;
 perform notify(it);
 return NEW;
exception when others then return NEW; end $$;
drop trigger if exists av_ad_ins on public.sponsor_ads;
create trigger av_ad_ins after insert on public.sponsor_ads for each row execute function public.trg_av_ad_ins();


-- ===== Nexum · avisos (parte C): secuencias de la prueba, recordatorios, agenda, difusión y programación =====

-- notify() con envíos por lotes (push de 100 en 100, correos de 20 en 20)
create or replace function public.notify(p_items jsonb) returns void language plpgsql security definer set search_path=public,extensions as $$
declare r record; pu jsonb:='[]'; ma jsonb:='[]'; i int;
 v_h int:=extract(hour from (now() at time zone 'Europe/Madrid'))::int;
 v_dd date:=(now() at time zone 'Europe/Madrid')::date;
 v_d0 timestamptz:=(((now() at time zone 'Europe/Madrid')::date)::timestamp) at time zone 'Europe/Madrid';
 nid bigint; npush int; okp boolean; subs boolean; kd text; mail_on boolean:=avisos_flag('avisos_mail');
begin
 if not avisos_flag('avisos') or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then return; end if;
 for r in select * from jsonb_to_recordset(p_items) as x(owner uuid,kind text,type text,title text,body text,url text,prio int,once text,ever text,mail jsonb,push boolean,bell boolean) loop
  continue when r.owner is null;
  if r.ever is not null then
   insert into push_log(owner,tag,day) values(r.owner,left(r.ever,120),date '2000-01-01') on conflict do nothing;
   continue when not found;
  elsif r.once is not null then
   insert into push_log(owner,tag,day) values(r.owner,left(r.once,120),v_dd) on conflict do nothing;
   continue when not found;
  end if;
  if mail_on and r.mail is not null then ma:=ma||jsonb_build_array(r.mail); end if;
  if coalesce(r.bell,true)=false or coalesce(btrim(r.title),'')='' then continue; end if;
  kd:=coalesce(r.kind,case when exists(select 1 from clients where id=r.owner) then 'client' else 'staff' end);
  subs:=exists(select 1 from push_subs where owner=r.owner);
  insert into notifs(owner,kind,type,title,body,url,prio,want_push)
   values(r.owner,kd,coalesce(r.type,'sistema'),left(r.title,120),left(coalesce(r.body,''),300),coalesce(r.url,'./'),coalesce(r.prio,1),coalesce(r.push,true) and subs)
   returning id into nid;
  okp:=false;
  if coalesce(r.push,true) and subs and v_h>=9 and v_h<21 then
   select count(distinct pushed_at) into npush from notifs where owner=r.owner and pushed_at>=v_d0;
   okp:=coalesce(r.prio,1)>=2 or npush<2;
  end if;
  if okp then
   update notifs set pushed_at=clock_timestamp() where id=nid;
   pu:=pu||jsonb_build_array(jsonb_build_object('owner',r.owner,'kind',coalesce(r.type,'sistema'),'title',left(r.title,80),'body',left(coalesce(r.body,''),180),'url',coalesce(r.url,'./'),'tag','nx-'||nid));
  end if;
 end loop;
 for i in 0..greatest((jsonb_array_length(pu)-1)/100,0) loop
  perform push_post((select jsonb_agg(q.v) from (select t.value v from jsonb_array_elements(pu) with ordinality t(value,ord) where t.ord>i*100 and t.ord<=(i+1)*100) q));
 end loop;
 for i in 0..greatest((jsonb_array_length(ma)-1)/20,0) loop
  perform email_post((select jsonb_agg(q.v) from (select t.value v from jsonb_array_elements(ma) with ordinality t(value,ord) where t.ord>i*20 and t.ord<=(i+1)*20) q));
 end loop;
end $$;

-- Secuencias de la prueba gratuita (entrenadores y atletas sin entrenador), bienvenida guiada, inactividad. Se ejecuta una vez al día a las 10:00.
create or replace function public.avisos_daily() returns void language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; r record; v_dd date:=(now() at time zone 'Europe/Madrid')::date;
 dsu int; dlf int; dex int; sent boolean; nm text; ml text; nb int; ndays int; acc boolean; lst text;
begin
 -- ===== ENTRENADORES en prueba =====
 for r in
  select co.id,co.nombre,co.email,co.ref_code,coalesce(co.avisos_mail,true) am,co.prueba_hasta,
   (co.created_at at time zone 'Europe/Madrid')::date ini,(co.prueba_hasta at time zone 'Europe/Madrid')::date fin,
   (coalesce(co.empresa_nombre,'')<>'' and coalesce(co.nif,'')<>'' and coalesce(co.iban_fin,'')<>'' and coalesce(co.precio,0)>0) rdy,
   (select count(*) from clients c where c.coach=co.id and not coalesce(c.suspendido,false)) ncl,
   (select count(*) from clients c where c.coach=co.id and not coalesce(c.suspendido,false) and jsonb_array_length(jarr(c.data->'sessions'))>0) nprog,
   (select count(*) from clients c where c.coach=co.id and cl_done(c.data)>0) ndone
  from coaches co
  where not coalesce(co.suspendido,false) and co.prueba_hasta is not null and not coalesce(co.stripe_charges_enabled,false) and not coalesce(co.cobra_directo,false)
   and co.stripe_subscription_id is null and coalesce(co.sub_estado,'') not in ('active','trialing')
   and not exists(select 1 from admins a where a.user_id=co.id)
 loop
  begin
   dsu:=v_dd-r.ini; dlf:=r.fin-v_dd; nm:=coalesce(nullif(r.nombre,''),'entrenador'); ml:=case when r.am then r.email else null end;
   if now()>=r.prueba_hasta then
    dex:=v_dd-r.fin;
    if dex between 0 and 1 then
     it:=it||nx_item(r.id,'staff','prueba','Tu prueba gratuita ha terminado','Tus atletas ya no pueden acceder. Elige tu plan y lo recuperas todo al momento.','./#cob',2,null,'co-e0',
       nx_mail(ml,nm,'Tu prueba gratuita ha terminado','Tu prueba de Nexum ha terminado y tus atletas ya no pueden acceder a su seguimiento.'||E'\nElige tu plan y lo recuperas todo al momento: atletas, entrenos y biblioteca se conservan.','Elegir mi plan'));
    elsif dex between 3 and 4 then
     it:=it||nx_item(r.id,'staff','prueba','Tus atletas te esperan','Todo sigue como lo dejaste. Reactiva tu cuenta cuando quieras y retoman donde lo dejaron.','./#cob',1,null,'co-e3',
       nx_mail(ml,nm,'Tus atletas te esperan','Todo sigue como lo dejaste: tus atletas, sus entrenos y tu biblioteca.'||E'\nReactiva tu cuenta cuando quieras y retoman donde lo dejaron.','Reactivar mi cuenta'));
    elsif dex between 7 and 8 then
     it:=it||nx_item(r.id,'staff','prueba','Tu cuenta sigue guardada','Tus atletas, entrenos y biblioteca están intactos. Si quieres seguir, elige tu plan en un minuto.','./#cob',1,null,'co-e7',
       nx_mail(ml,nm,'Tu cuenta de Nexum sigue guardada','Tus atletas, entrenos y biblioteca están intactos.'||E'\nSi quieres seguir, elige tu plan en un minuto y vuelves a estar al día.','Elegir mi plan'));
    end if;
   elsif dlf=0 then
    it:=it||nx_item(r.id,'staff','prueba','Hoy termina tu prueba','Elige tu plan ahora para que tus atletas no pierdan el acceso a su seguimiento.','./#cob',2,null,'co-l0',
      nx_mail(ml,nm,'Hoy termina tu prueba gratuita','Tu prueba de Nexum termina hoy.'||E'\nElige tu plan ahora para que tus atletas no pierdan el acceso a su seguimiento. Todo lo que has creado se conserva.','Elegir mi plan'));
   elsif dlf=1 then
    it:=it||nx_item(r.id,'staff','prueba','Mañana termina tu prueba','Elige tu plan hoy y sigue sin interrupciones. Tus atletas y tus datos se conservan.','./#cob',2,null,'co-l1',
      nx_mail(ml,nm,'Mañana termina tu prueba gratuita','Tu prueba de Nexum acaba mañana.'||E'\nConecta Stripe y elige tu plan para seguir con tus atletas sin interrupciones. Todo lo que has creado (atletas, entrenos, biblioteca) se conserva.','Elegir mi plan'));
   elsif dlf=2 then
    it:=it||nx_item(r.id,'staff','prueba','Te quedan 2 días de prueba','Conecta Stripe y elige tu plan para seguir con tus atletas sin cortes. Todo lo que has creado se conserva.','./#cob',1,null,'co-l2');
   elsif dsu=1 then
    if not r.rdy then
     it:=it||nx_item(r.id,'staff','prueba','Termina de configurar tu cuenta','Añade los datos de tu empresa y tu precio: sin ellos no puedes dar de alta atletas. Son 3 minutos.','./#cob',1,null,'co-d1');
    elsif r.ncl=0 then
     it:=it||nx_item(r.id,'staff','prueba','Da de alta a tu primer atleta','En 1 minuto lo tienes dentro y puedes asignarle su primera sesión. Tu prueba gratuita ya está corriendo.','./#cli',1,null,'co-d1');
    elsif r.nprog=0 then
     it:=it||nx_item(r.id,'staff','prueba','Programa su primera sesión','Tus atletas ya están dentro. Crea un entreno una sola vez y se repite cada semana sin que tengas que tocarlo.','./#cli',1,null,'co-d1');
    else
     it:=it||nx_item(r.id,'staff','prueba','Tus atletas ya tienen plan 💪','Entra y mira cómo van: verás sus entrenos, check-ins y quién necesita un empujón.','./#cli',1,null,'co-d1');
    end if;
   elsif dsu=2 then
    if r.ncl>0 and r.ndone=0 then
     it:=it||nx_item(r.id,'staff','prueba','Aún no han entrenado','Mándales un mensaje desde el chat: el primer entreno es el más difícil de arrancar.','./#chat',1,null,'co-d2');
    else
     it:=it||nx_item(r.id,'staff','prueba','Tu biblioteca de ejercicios','Tienes cientos de ejercicios con vídeo y puedes guardar los tuyos para reutilizarlos en cada plan.','./#lib',1,null,'co-d2');
    end if;
   elsif dsu=3 and coalesce(r.ref_code,'')<>'' then
    it:=it||nx_item(r.id,'staff','prueba','Invita a otro entrenador','Comparte tu código '||r.ref_code||': tu compañero paga un 5 % menos durante 3 meses y tú ganas un bono cada mes mientras siga activo.','./#acc',1,null,'co-d3');
   elsif dsu=4 then
    if r.ncl>0 then
     it:=it||nx_item(r.id,'staff','prueba','Tu equipo, de un vistazo','En tu panel ves quién entrena, quién falla y quién necesita atención. Así no se te escapa nadie.','./#cli',1,null,'co-d4');
    else
     it:=it||nx_item(r.id,'staff','prueba','Un atleta basta para verlo funcionar','Dalo de alta a un amigo o a ti mismo: en 2 minutos ves el seguimiento completo.','./#cli',1,null,'co-d4');
    end if;
   end if;
  exception when others then raise warning 'avisos_daily coach %: %',r.id,sqlerrm;
  end;
 end loop;

 -- ===== ATLETAS =====
 for r in
  select c.id,c.name,c.coach,c.prueba_hasta,(c.coach is null and c.coach_id is null) solo,
   (c.pago_estado='pagado' and c.pagado_hasta is not null and c.pagado_hasta>now()) paid,
   (c.prueba_hasta at time zone 'Europe/Madrid')::date-7 ini,(c.prueba_hasta at time zone 'Europe/Madrid')::date fin,
   cl_done(c.data) nd,case when cl_last(c.data)~'^\d{4}-\d{2}-\d{2}$' then cl_last(c.data)::date end lastd,
   c.data->'prof'->>'email' em,((c.data->'prof'->>'maila') is distinct from 'false') am,
   coalesce(c.data->'q'->>'done','') qd,
   exists(select 1 from jsonb_each(case when jsonb_typeof(c.data->'rec')='object' then c.data->'rec' else '{}'::jsonb end) kv where kv.value->>'saved' is not null) ci
  from clients c where not coalesce(c.suspendido,false) and c.prueba_hasta is not null
 loop
  begin
   dsu:=v_dd-r.ini; dlf:=r.fin-v_dd; dex:=v_dd-r.fin; nm:=coalesce(nullif(r.name,''),'atleta'); ml:=case when r.am then r.em else null end;
   acc:=r.paid or (r.solo and now()<r.prueba_hasta); nb:=jsonb_array_length(it);
   if r.solo and not r.paid then
    if now()>=r.prueba_hasta then
     if dex between 0 and 1 then
      it:=it||nx_item(r.id,'client','prueba','Tu prueba ha terminado','Elige tu plan para volver a entrenar. Tu progreso está guardado.','./',2,null,'at-e0',
        nx_mail(ml,nm,'Tu prueba de Nexum ha terminado','Tu prueba gratuita ha terminado, pero tu progreso está guardado.'||E'\nElige tu plan para volver a entrenar justo donde lo dejaste.','Elegir mi plan'));
     elsif dex between 3 and 4 then
      it:=it||nx_item(r.id,'client','prueba','Te echamos de menos','Tu progreso sigue aquí. Vuelve cuando quieras con un plan y retoma tu rutina.','./',1,null,'at-e3',
        nx_mail(ml,nm,'Te echamos de menos en Nexum','Tu progreso, tus entrenos y tus recetas siguen guardados.'||E'\nVuelve cuando quieras con un plan y retoma tu rutina.','Volver a Nexum'));
     elsif dex between 7 and 8 then
      it:=it||nx_item(r.id,'client','prueba','Tu progreso te espera','Todo lo que has hecho sigue guardado. Elige tu plan y sigue donde lo dejaste.','./',1,null,'at-e7',
        nx_mail(ml,nm,'Tu progreso te espera','Todo lo que has hecho en Nexum sigue guardado.'||E'\nElige tu plan y sigue donde lo dejaste.','Elegir mi plan'));
     end if;
    elsif dlf=0 then
     it:=it||nx_item(r.id,'client','prueba','Hoy termina tu prueba','Elige tu plan ahora para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.','./',2,null,'at-l0',
       nx_mail(ml,nm,'Hoy termina tu prueba de Nexum','Tu prueba gratuita termina hoy.'||E'\nElige tu plan para seguir entrenando sin cortes. No pierdes nada de lo que has hecho.','Elegir mi plan'));
    elsif dlf=1 then
     it:=it||nx_item(r.id,'client','prueba','Mañana termina tu prueba','Elige tu plan hoy y sigue entrenando sin cortes. No pierdes nada de lo que has hecho.','./',2,null,'at-l1',
       nx_mail(ml,nm,'Mañana termina tu prueba de Nexum','Tu prueba gratuita acaba mañana.'||E'\nElige tu plan hoy y sigue entrenando sin cortes. Tus entrenos, tus recetas y tu progreso se conservan.','Elegir mi plan'));
    elsif dlf=2 then
     it:=it||nx_item(r.id,'client','prueba','Te quedan 2 días de prueba','Elige tu plan para conservar tus entrenos, tu progreso y tus recetas.','./',1,null,'at-l2');
    end if;
   end if;
   sent:=jsonb_array_length(it)>nb;
   if acc and not sent and dsu between 1 and 4 then
    if dsu=1 then
     if r.qd in ('','0','false') then
      it:=it||nx_item(r.id,'client','prueba','Completa tu cuestionario','Son unos 8 minutos y sirven para personalizar tu plan.','./#cue',1,null,'at-d1');
     elsif r.nd=0 then
      it:=it||nx_item(r.id,'client','prueba','Haz tu primer entreno','Aunque sea corto. Lo importante es empezar.','./#ent',1,null,'at-d1');
     else
      it:=it||nx_item(r.id,'client','prueba','Buen comienzo 👏','Ya llevas '||r.nd||case when r.nd=1 then ' entreno' else ' entrenos' end||'. Mañana, un check-in rápido.','./#rec',1,null,'at-d1');
     end if;
    elsif dsu=2 then
     if not r.ci then
      it:=it||nx_item(r.id,'client','prueba','Tu primer check-in (30 s)','Cuéntale a tu entrenador cómo estás: sueño, energía y ánimo.','./#rec',1,null,'at-d2');
     else
      it:=it||nx_item(r.id,'client','prueba','Mira tu progreso','Tus cargas y tests ya forman una gráfica. Échale un vistazo.','./#pro',1,null,'at-d2');
     end if;
    elsif dsu=3 then
     it:=it||nx_item(r.id,'client','prueba','Tu nutrición, a un toque','Tienes tus comidas y recetas en la pestaña Nutrición. Entrenar y comer bien van de la mano.','./#nut',1,null,'at-d3');
    else
     if r.nd>0 then
      it:=it||nx_item(r.id,'client','prueba','Llevas '||r.nd||case when r.nd=1 then ' entreno' else ' entrenos' end,'La constancia gana. ¿Hoy toca otro?','./#ent',1,null,'at-d4');
     else
      it:=it||nx_item(r.id,'client','prueba','Un entreno corto también cuenta','15 minutos valen más que cero. Elige uno y empieza.','./#ent',1,null,'at-d4');
     end if;
    end if;
    sent:=true;
   end if;
   if acc and not sent and r.nd>0 and r.lastd is not null then
    ndays:=v_dd-r.lastd;
    if ndays=3 then
     it:=it||nx_item(r.id,'client','entreno','Te echamos de menos 👋','Llevas 3 días sin entrenar. Una sesión corta y vuelves al ritmo.','./#ent',1,null,'inact3-'||r.lastd);
    elsif ndays=7 then
     it:=it||nx_item(r.id,'client','entreno','Una semana sin entrenar','Tu entrenador está pendiente de ti. Vuelve hoy con algo suave.','./#ent',1,null,'inact7-'||r.lastd);
    elsif ndays=14 then
     it:=it||nx_item(r.id,'client','entreno','¿Todo bien?','Cuéntale a tu entrenador qué ha pasado: el plan se puede ajustar a tu momento.','./#chat',1,null,'inact14-'||r.lastd);
    end if;
   end if;
   if not r.solo and not r.paid and r.coach is not null and dsu between 2 and 14 then
    it:=it||nx_item(r.coach,'staff','pago','💶 '||nm||' aún no ha pagado','Sin su pago no puede acceder a su seguimiento. Recuérdaselo por el chat.','./#cli',1,null,'unpaid-'||r.id);
   end if;
  exception when others then raise warning 'avisos_daily atleta %: %',r.id,sqlerrm;
  end;
 end loop;

 -- ===== ADMINISTRADOR: pruebas que acaban hoy o mañana (para seguirlas en persona) =====
 select string_agg(x.nm,', ') into lst from (
   select trim(coalesce(co.nombre,'')||' '||coalesce(co.apellidos,''))||' (entrenador)' nm from coaches co
    where not coalesce(co.suspendido,false) and co.prueba_hasta>now() and (co.prueba_hasta at time zone 'Europe/Madrid')::date-v_dd between 0 and 1
     and not coalesce(co.stripe_charges_enabled,false) and not coalesce(co.cobra_directo,false) and co.stripe_subscription_id is null and coalesce(co.sub_estado,'') not in ('active','trialing')
     and not exists(select 1 from admins a where a.user_id=co.id)
   union all
   select c.name||' (atleta)' from clients c
    where not coalesce(c.suspendido,false) and c.coach is null and c.coach_id is null and c.prueba_hasta>now() and (c.prueba_hasta at time zone 'Europe/Madrid')::date-v_dd between 0 and 1
     and not (c.pago_estado='pagado' and c.pagado_hasta is not null and c.pagado_hasta>now())) x;
 if lst is not null then
  it:=it||(select jsonb_agg(nx_item(a.user_id,'staff','admin','⏳ Pruebas a punto de acabar',left(lst,250),'./#adm',1,'adm-trial')) from admins a);
 end if;
 perform notify(it);
end $$;

-- Recordatorios diarios
create or replace function public.avisos_remind(p_job text) returns void language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; r record; v_dd date:=(now() at time zone 'Europe/Madrid')::date; td text:=to_char((now() at time zone 'Europe/Madrid')::date,'YYYY-MM-DD'); pe text[];
begin
 if p_job in ('morning','evening') then
  for r in select c.id,c.data from clients c where not coalesce(c.suspendido,false)
     and ((c.pago_estado='pagado' and c.pagado_hasta is not null and c.pagado_hasta>now()) or (c.coach is null and c.coach_id is null and c.prueba_hasta>now())) loop
   begin
    pe:=cl_pend(r.data,v_dd);
    if coalesce(array_length(pe,1),0)>0 then
     if p_job='morning' then
      it:=it||nx_item(r.id,'client','entreno','Hoy toca: '||array_to_string(pe[1:2],' · '),'Tu entrenamiento te espera. ¡A por él! 💪','./#ent',1,'entreno-am');
     else
      it:=it||nx_item(r.id,'client','entreno','Entreno de hoy pendiente','Aún estás a tiempo: «'||pe[1]||'». ¡Vamos a por ello! 💪','./#ent',1,'entreno');
     end if;
    end if;
    if p_job='evening' and (r.data->'rec'->td->>'saved') is null then
     it:=it||nx_item(r.id,'client','checkin','Check-in de hoy','Cuéntale a tu entrenador cómo estás: son 30 segundos.','./#rec',1,'checkin');
    end if;
   exception when others then raise warning 'avisos_remind % %: %',p_job,r.id,sqlerrm; end;
  end loop;
 elsif p_job='review' then
  for r in select c.id from clients c where not coalesce(c.suspendido,false) and cl_done(c.data)>0
     and ((c.pago_estado='pagado' and c.pagado_hasta is not null and c.pagado_hasta>now()) or (c.coach is null and c.coach_id is null and c.prueba_hasta>now()))
     and not exists(select 1 from jsonb_each(case when jsonb_typeof(c.data->'rev')='object' then c.data->'rev' else '{}'::jsonb end) kv where kv.value->>'saved'='true' and coalesce(kv.value->>'d','')>=to_char(v_dd-3,'YYYY-MM-DD')) loop
   it:=it||nx_item(r.id,'client','checkin','Tu revisión semanal','Peso, cómo te has sentido y fotos opcionales. Tu entrenador la recibe al momento.','./#rev',1,'review');
  end loop;
 elsif p_job='coach' then
  for r in select co.id,count(*) n from coaches co join clients c on c.coach=co.id and not coalesce(c.suspendido,false)
     where not coalesce(co.suspendido,false) and c.updated_at<now()-interval '3 days' group by co.id loop
   it:=it||nx_item(r.id,'staff','riesgo','Atletas que necesitan atención',r.n||(case when r.n=1 then ' atleta lleva' else ' atletas llevan' end)||' 3 días o más sin actividad. Un mensaje a tiempo ayuda.','./#cli',1,'riesgo');
  end loop;
 end if;
 perform notify(it);
end $$;

-- Recordatorio de citas y videollamadas (1 hora antes)
create or replace function public.avisos_events() returns void language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; r record; c record; ttl text; mins numeric;
 v_dd date:=(now() at time zone 'Europe/Madrid')::date; v_t time:=(now() at time zone 'Europe/Madrid')::time;
begin
 for r in select * from events where day=v_dd and coalesce(hora,'')~'^([01]?\d|2[0-3]):[0-5]\d$' loop
  mins:=extract(epoch from (r.hora::time-v_t))/60;
  continue when mins<30 or mins>90;
  ttl:=(case when r.kind='call' then '📹 Videollamada' else '📅 Cita' end)||' en 1 hora: '||r.title;
  if r.scope='client' then
   for c in select id from clients where coach=r.coach_id and not coalesce(suspendido,false) and (r.client_id is null or id=r.client_id) loop
    it:=it||nx_item(c.id,'client','agenda',ttl,'Hoy a las '||r.hora,'./',1,null,'evr-'||r.id||'-'||c.id);
   end loop;
   if r.coach_id is not null then it:=it||nx_item(r.coach_id,'staff','agenda',ttl,'Hoy a las '||r.hora,'./#agd',1,null,'evr-'||r.id||'-co'); end if;
  else
   for c in select id from coaches where not coalesce(suspendido,false) union select user_id from admins loop
    it:=it||nx_item(c.id,'staff','agenda',ttl,'Hoy a las '||r.hora,'./#agd',1,null,'evr-'||r.id||'-'||c.id);
   end loop;
  end if;
 end loop;
 perform notify(it);
end $$;

-- Rutina horaria (Madrid): reparto diferido, citas, y las tareas diarias por franja
create or replace function public.avisos_cron_run() returns void language plpgsql security definer set search_path=public,extensions as $$
declare h int:=extract(hour from (now() at time zone 'Europe/Madrid'))::int; dw int:=extract(isodow from (now() at time zone 'Europe/Madrid'))::int;
begin
 if not avisos_flag('avisos') then return; end if;
 begin perform avisos_flush(); exception when others then raise warning 'avisos_flush: %',sqlerrm; end;
 begin perform avisos_events(); exception when others then raise warning 'avisos_events: %',sqlerrm; end;
 if h=9 then
  begin perform avisos_remind('morning'); exception when others then raise warning 'remind morning: %',sqlerrm; end;
  begin perform avisos_remind('coach'); exception when others then raise warning 'remind coach: %',sqlerrm; end;
 end if;
 if h=10 then begin perform avisos_daily(); exception when others then raise warning 'avisos_daily: %',sqlerrm; end; end if;
 if h=11 and dw=7 then begin perform avisos_remind('review'); exception when others then raise warning 'remind review: %',sqlerrm; end; end if;
 if h=19 then begin perform avisos_remind('evening'); exception when others then raise warning 'remind evening: %',sqlerrm; end; end if;
 if h=4 then
  delete from notifs where created_at<now()-interval '60 days';
  delete from push_log where day<>date '2000-01-01' and day<(now() at time zone 'Europe/Madrid')::date-60;
 end if;
end $$;

-- La antigua rutina de push ahora delega en la nueva
create or replace function public.push_cron_run(p_job text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin perform avisos_remind(case when p_job='evening' then 'evening' else 'coach' end); end $$;

-- Difusión del administrador: aviso a todos, solo atletas, solo entrenadores o solo quien está en prueba (campana + push; correo opcional)
create or replace function public.admin_broadcast(p_title text,p_body text,p_aud text,p_url text default './',p_mail boolean default false) returns int
language plpgsql security definer set search_path=public,extensions as $$
declare it jsonb:='[]'; n int:=0; r record; k text:=to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS');
begin
 if not is_admin() then raise exception 'No permitido'; end if;
 if coalesce(btrim(p_title),'')='' then raise exception 'Escribe un título'; end if;
 if p_aud not in ('todos','atletas','entrenadores','prueba') then raise exception 'Audiencia no válida'; end if;
 if p_aud in ('todos','atletas','prueba') then
  for r in select c.id,c.name,c.data->'prof'->>'email' em,((c.data->'prof'->>'maila') is distinct from 'false') am from clients c
    where not coalesce(c.suspendido,false)
     and (p_aud<>'prueba' or (c.coach is null and c.coach_id is null and c.prueba_hasta>now() and not (c.pago_estado='pagado' and c.pagado_hasta is not null and c.pagado_hasta>now()))) loop
   it:=it||nx_item(r.id,'client','sistema',left(p_title,120),left(coalesce(p_body,''),300),coalesce(nullif(p_url,''),'./'),2,null,'bc-'||k,
     case when p_mail and r.am then nx_mail(r.em,r.name,left(p_title,120),coalesce(p_body,''),'Abrir Nexum') end);
   n:=n+1;
  end loop;
 end if;
 if p_aud in ('todos','entrenadores','prueba') then
  for r in select co.id,co.nombre,co.email,coalesce(co.avisos_mail,true) am from coaches co
    where not coalesce(co.suspendido,false)
     and (p_aud<>'prueba' or (co.prueba_hasta>now() and not coalesce(co.stripe_charges_enabled,false) and not coalesce(co.cobra_directo,false) and co.stripe_subscription_id is null and coalesce(co.sub_estado,'') not in ('active','trialing'))) loop
   it:=it||nx_item(r.id,'staff','sistema',left(p_title,120),left(coalesce(p_body,''),300),coalesce(nullif(p_url,''),'./'),2,null,'bc-'||k,
     case when p_mail and r.am then nx_mail(r.email,coalesce(nullif(r.nombre,''),'entrenador'),left(p_title,120),coalesce(p_body,''),'Abrir Nexum') end);
   n:=n+1;
  end loop;
 end if;
 perform notify(it);
 insert into admin_log(admin,action,target,detail) values(auth.uid(),'broadcast',p_aud,jsonb_build_object('title',left(p_title,120),'n',n,'mail',p_mail));
 return n;
end $$;

revoke all on function public.avisos_daily(), public.avisos_remind(text), public.avisos_events(), public.avisos_cron_run(), public.push_cron_run(text) from public, anon, authenticated;
revoke all on function public.notify(jsonb) from public, anon, authenticated;
grant execute on function public.admin_broadcast(text,text,text,text,boolean) to authenticated;

-- Programación: una rutina horaria (minuto 5) que decide según la hora de Madrid
select cron.unschedule(jobname) from cron.job where jobname in ('nx-push-evening','nx-push-coach','nx-avisos');
select cron.schedule('nx-avisos','5 * * * *',$$select public.avisos_cron_run()$$);


-- ===== Permisos: solo notif_* (atleta/personal) y admin_broadcast (solo sesión) quedan expuestos =====
revoke execute on function public.admin_broadcast(text,text,text,text,boolean) from public, anon;
grant execute on function public.admin_broadcast(text,text,text,text,boolean) to authenticated;
revoke execute on function public.avisos_flag(text) from public, anon, authenticated;
revoke execute on function public.nx_trial_days() from public, anon, authenticated;
do $$ declare f text; begin
 for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'trg\_av\_%' loop
  execute 'revoke execute on function '||f||' from public, anon, authenticated';
 end loop;
end $$;
alter function public.jarr(jsonb) set search_path = public, pg_temp;
alter function public.cl_done(jsonb) set search_path = public, pg_temp;
alter function public.cl_last(jsonb) set search_path = public, pg_temp;
alter function public.cl_pend(jsonb, date) set search_path = public, pg_temp;
alter function public.nx_item(uuid,text,text,text,text,text,int,text,text,jsonb,boolean,boolean) set search_path = public, pg_temp;
alter function public.nx_mail(text,text,text,text,text) set search_path = public, pg_temp;
