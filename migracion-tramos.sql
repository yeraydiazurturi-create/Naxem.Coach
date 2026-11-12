-- ============================================================================
-- v66 · Planes del entrenador por TRAMOS de clientes + preparación legal/fiscal
-- Proyecto Supabase: jkwhysytxypajunivqmc
--
-- Qué hace
--   1. Tramos: Inicio (hasta 10 clientes) · Crece (hasta 20) · Pro (21 o más), editables desde Administración
--      (config `coach_tiers`). Cada tramo tiene precio mensual y anual (sin IVA). El tope se aplica EN LA BASE DE DATOS
--      (trigger en `clients`), no solo en la pantalla.
--   2. coach_plan_options / coach_set_plan nuevos (elegir tramo y periodo, con control de bajada de plan).
--   3. Factura del plan con el nombre del tramo y el periodo.
--   4. Legal: tabla de aceptaciones versionadas (términos, privacidad, encargo de tratamiento, condiciones Premium),
--      solicitudes de derechos RGPD, exportación de datos del atleta.
--   5. Interruptores de cobro: `cobro_entrenadores` y `cobro_premium` (los dos APAGADOS hasta tu alta de autónomo).
--      Para encenderlos hace falta el NIF válido, nombre, dirección y email del titular.
--   6. nx_ready(): lista de comprobación «listo para cobrar» para el panel de Administración.
--
-- Es idempotente: se puede ejecutar más de una vez.
-- ============================================================================

-- ---------- 0. NIF/NIE/CIF (formato + letra de control de DNI y NIE) ----------
create or replace function public.nx_nif_ok(p text) returns boolean
language plpgsql immutable set search_path = public as $$
declare s text := upper(regexp_replace(coalesce(p,''), '[\s.\-]', '', 'g')); l constant text := 'TRWAGMYFPDXBNJZSQVHLCKE'; n int;
begin
  if s ~ '^[0-9]{8}[A-Z]$' then
    return substr(l, (substr(s,1,8)::int % 23) + 1, 1) = substr(s,9,1);
  elsif s ~ '^[XYZ][0-9]{7}[A-Z]$' then
    n := (translate(substr(s,1,1), 'XYZ', '012') || substr(s,2,7))::int;
    return substr(l, (n % 23) + 1, 1) = substr(s,9,1);
  elsif s ~ '^[KLM][0-9]{7}[A-Z]$' then
    return true;
  elsif s ~ '^[ABCDEFGHJNPQRSUVW][0-9]{7}[0-9A-J]$' then
    return true;  -- CIF: solo se comprueba el formato
  end if;
  return false;
end $$;

-- ---------- 1. Tramos ----------
insert into app_config(key, value) values
  ('coach_tiers', '[{"key":"inicio","nombre":"Inicio","max":10,"mensual":14.9,"anual":149},
                    {"key":"crece","nombre":"Crece","max":20,"mensual":24.9,"anual":249,"rec":true},
                    {"key":"pro","nombre":"Pro","max":null,"mensual":34.9,"anual":349}]'::jsonb),
  ('cobro_premium', 'false'::jsonb)
on conflict (key) do nothing;

create or replace function public.nx_tiers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select value from app_config where key = 'coach_tiers' and jsonb_typeof(value) = 'array' and jsonb_array_length(value) > 0),
    '[{"key":"inicio","nombre":"Inicio","max":10,"mensual":14.9,"anual":149},{"key":"crece","nombre":"Crece","max":20,"mensual":24.9,"anual":249,"rec":true},{"key":"pro","nombre":"Pro","max":null,"mensual":34.9,"anual":349}]'::jsonb)
$$;

create or replace function public.nx_tier(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select t from jsonb_array_elements(public.nx_tiers()) t where t->>'key' = p_key limit 1
$$;

create or replace function public.nx_coach_count(p_coach uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from clients where coach = p_coach or coach_id = p_coach
$$;

-- Tope de clientes del entrenador (null = sin límite). Sin plan elegido (prueba) = tope del primer tramo.
create or replace function public.nx_coach_cap(p_coach uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare k record; t jsonb;
begin
  select plan into k from coaches where id = p_coach;
  if not found then return 0; end if;
  t := case when k.plan is null then public.nx_tiers() -> 0 else public.nx_tier(k.plan) end;
  if t is null then t := public.nx_tiers() -> 0; end if;
  return nullif(t->>'max','')::int;
end $$;

-- Tope aplicado en la base de datos: ni el botón ni una llamada directa a la API pueden pasarse del plan.
create or replace function public.clients_cap() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_coach uuid := coalesce(new.coach_id, new.coach); v_max int; v_n int; v_nom text;
begin
  if v_coach is null then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.coach_id, old.coach) is not distinct from v_coach then return new; end if;
  if coalesce(auth.role(), '') = 'service_role' or coalesce(current_setting('nx.admin', true), '') = '1' then return new; end if;
  v_max := public.nx_coach_cap(v_coach);
  if v_max is null then return new; end if;
  select count(*) into v_n from clients where (coach = v_coach or coach_id = v_coach) and id <> new.id;
  if v_n >= v_max then
    select coalesce(public.nx_tier(plan)->>'nombre', public.nx_tiers()->0->>'nombre') into v_nom from coaches where id = v_coach;
    raise exception 'LIMITE_PLAN:%:%', v_max, coalesce(v_nom, '') using errcode = 'P0001';
  end if;
  return new;
end $$;

revoke all on function public.nx_coach_cap(uuid), public.nx_coach_count(uuid) from public, anon, authenticated;

drop trigger if exists clients_cap on public.clients;
create trigger clients_cap before insert or update of coach, coach_id on public.clients
  for each row execute function public.clients_cap();

-- La restricción antigua solo admitía mensual/semestral/fundador
alter table public.coaches drop constraint if exists coaches_plan_chk;
alter table public.coaches add constraint coaches_plan_chk check (plan is null or plan = any (array['inicio','crece','pro','mensual','semestral','fundador']));

-- ---------- 2. Opciones y elección de plan ----------
create or replace function public.coach_plan_options() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c record; cfg jsonb; f boolean; v_ok boolean;
begin
  select * into c from coaches where id = auth.uid();
  if not found then raise exception 'No eres entrenador'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cfg
    from app_config where key in ('nexum_iva', 'cobro_entrenadores');
  f := c.promo_code is not null and exists (select 1 from promo_codes where code = c.promo_code and plan = 'fundador' and activo);
  v_ok := exists (select 1 from legal_acceptances where subject_kind = 'coach' and subject_id = c.id and doc = 'terminos' and version = public.nx_legal_version());
  return jsonb_build_object(
    'tiers', public.nx_tiers(),
    'iva',   coalesce((cfg->>'nexum_iva')::numeric, 21),
    'cobro', coalesce((cfg->>'cobro_entrenadores')::boolean, false),
    'plan', c.plan, 'precio', c.plan_precio, 'meses', c.plan_meses, 'desde', c.plan_desde, 'hasta', c.plan_hasta,
    'estado', c.sub_estado, 'sub_hasta', c.sub_hasta,
    'clientes', public.nx_coach_count(c.id), 'cap', public.nx_coach_cap(c.id),
    'prueba_hasta', c.prueba_hasta, 'fundador', f,
    'promo_code', c.promo_code, 'promo_pct', c.promo_pct, 'promo_meses', c.promo_meses,
    'legal_ok', v_ok, 'nif_ok', public.nx_nif_ok(c.nif));
end $$;

drop function if exists public.coach_set_plan(text);
create or replace function public.coach_set_plan(p_plan text, p_per text default 'mes') returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; t jsonb; v_price numeric; v_meses int; v_n int; v_max int;
begin
  select * into c from coaches where id = auth.uid();
  if not found then raise exception 'No eres entrenador'; end if;
  t := public.nx_tier(p_plan);
  if t is null then raise exception 'Plan no válido'; end if;
  if coalesce(p_per, 'mes') not in ('mes', 'anual') then raise exception 'Periodo no válido'; end if;
  if coalesce(c.sub_estado, 'none') in ('active', 'trialing', 'past_due') then
    raise exception 'Ya tienes una suscripción en marcha. Cambia de plan desde «Cambiar de plan».';
  end if;
  v_max := nullif(t->>'max', '')::int;
  v_n := public.nx_coach_count(c.id);
  if v_max is not null and v_n > v_max then raise exception 'LIMITE_PLAN:%:%', v_max, t->>'nombre' using errcode = 'P0001'; end if;
  if coalesce(p_per, 'mes') = 'anual' then
    v_price := coalesce(nullif(t->>'anual', '')::numeric, round((t->>'mensual')::numeric * 10, 2)); v_meses := 12;
  else
    v_price := (t->>'mensual')::numeric; v_meses := 1;
  end if;
  perform set_config('nx.admin', '1', true);
  update coaches set plan = p_plan, plan_precio = v_price, plan_meses = v_meses, plan_desde = current_date, plan_hasta = null,
         contrato_meses = v_meses, contrato_inicio = current_date, contrato_firma = now()
   where id = c.id;
  return jsonb_build_object('plan', p_plan, 'precio', v_price, 'meses', v_meses, 'desde', current_date);
end $$;
grant execute on function public.coach_set_plan(text, text) to authenticated;

-- ---------- 3. Factura del plan con el nombre del tramo ----------
create or replace function public.record_coach_plan_invoice(p_stripe_invoice text, p_coach uuid, p_total_cents integer, p_tax_cents integer, p_paid_at timestamptz default now())
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare k record; v_fis jsonb; v_total numeric; v_iva numeric; v_base numeric; v_pct numeric; v_n int; v_y text; v_id bigint; v_plan text;
begin
  if p_stripe_invoice is not null and exists (select 1 from invoices where stripe_invoice_id = p_stripe_invoice) then return null; end if;
  if coalesce(p_total_cents, 0) <= 0 then return null; end if;
  select * into k from coaches where id = p_coach; if not found then return null; end if;
  select value into v_fis from app_config where key = 'nexum_fiscal';
  if v_fis is null or coalesce(v_fis->>'nombre','') = '' or coalesce(v_fis->>'nif','') = '' or coalesce(v_fis->>'direccion','') = '' then
    raise exception 'Faltan los datos fiscales de Nexum (nombre, NIF y dirección) para emitir la factura del plan'; end if;
  v_total := round(p_total_cents / 100.0, 2);
  v_iva   := round(coalesce(p_tax_cents, 0) / 100.0, 2);
  v_base  := v_total - v_iva;
  v_pct   := case when v_base > 0 then round(v_iva * 100 / v_base, 2) else 0 end;
  v_y     := to_char(coalesce(p_paid_at, now()), 'YYYY');
  v_n     := public.next_invoice_no('NX-' || v_y);
  v_plan  := coalesce(public.nx_tier(k.plan)->>'nombre',
               case k.plan when 'mensual' then 'Mensual' when 'semestral' then 'Semestral' when 'fundador' then 'Fundador' else coalesce(k.plan, '') end)
             || case when coalesce(k.plan_meses, 1) = 12 then ' (anual)' else '' end;
  insert into invoices(kind, numero, coach_id, emisor, receptor, concepto, base, iva_pct, iva, total, periodo, stripe_invoice_id, emitida)
  values ('nexum', 'NX-' || v_y || '-' || lpad(v_n::text, 4, '0'), k.id, v_fis,
    jsonb_build_object('nombre', coalesce(nullif(k.empresa_nombre,''), trim(coalesce(k.nombre,'')||' '||coalesce(k.apellidos,''))),
      'nif', k.nif, 'direccion', coalesce(nullif(k.direccion,''), k.empresa_localidad), 'email', coalesce(k.empresa_email, k.email)),
    'Suscripción a la plataforma Nexum · plan ' || v_plan || ' · ' || to_char(coalesce(p_paid_at, now()), 'MM/YYYY'),
    v_base, v_pct, v_iva, v_total, to_char(coalesce(p_paid_at, now()), 'YYYY-MM'), p_stripe_invoice, coalesce(p_paid_at, now()))
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 4. Legal: aceptaciones versionadas ----------
-- Cuando cambies un texto legal, sube esta versión (y LEGAL_V en la app): se volverá a pedir la aceptación.
create or replace function public.nx_legal_version() returns text language sql immutable as $$ select '2026-11-12'::text $$;

create table if not exists public.legal_acceptances (
  id bigserial primary key,
  subject_kind text not null check (subject_kind in ('coach', 'client')),
  subject_id uuid not null,
  doc text not null check (doc in ('terminos', 'privacidad', 'encargo', 'premium')),
  version text not null,
  accepted_at timestamptz not null default now(),
  ip text, ua text,
  unique (subject_kind, subject_id, doc, version)
);
alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from anon, authenticated;

create or replace function public.nx_req_info(out ip text, out ua text) language plpgsql stable as $$
declare h jsonb;
begin
  begin h := current_setting('request.headers', true)::jsonb; exception when others then h := null; end;
  ip := nullif(trim(split_part(coalesce(h->>'x-forwarded-for', h->>'cf-connecting-ip', ''), ',', 1)), '');
  ua := left(h->>'user-agent', 300);
end $$;

create or replace function public.coach_legal_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v text := public.nx_legal_version(); n int;
begin
  if auth.uid() is null then raise exception 'No permitido'; end if;
  select count(*) into n from legal_acceptances
   where subject_kind = 'coach' and subject_id = auth.uid() and version = v and doc in ('terminos', 'privacidad', 'encargo');
  return jsonb_build_object('version', v, 'ok', n >= 3);
end $$;

create or replace function public.coach_accept_legal() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := public.nx_legal_version(); d text; i record;
begin
  if auth.uid() is null or not exists (select 1 from coaches where id = auth.uid()) then raise exception 'No permitido'; end if;
  select * into i from public.nx_req_info();
  foreach d in array array['terminos', 'privacidad', 'encargo'] loop
    insert into legal_acceptances(subject_kind, subject_id, doc, version, ip, ua) values ('coach', auth.uid(), d, v, i.ip, i.ua)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('version', v, 'ok', true);
end $$;

-- Atleta: docs = ['terminos','privacidad'] al registrarse o al primer acceso; ['premium'] al contratar Premium
create or replace function public.client_accept_legal(p_u text, p_p text, p_docs text[] default array['terminos','privacidad']) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare cid uuid; v text := public.nx_legal_version(); d text; i record;
begin
  cid := public.client_id_by_cred(p_u, p_p)::uuid;
  if cid is null then raise exception 'credenciales'; end if;
  select * into i from public.nx_req_info();
  foreach d in array coalesce(p_docs, array[]::text[]) loop
    if d not in ('terminos', 'privacidad', 'premium') then raise exception 'Documento no válido'; end if;
    insert into legal_acceptances(subject_kind, subject_id, doc, version, ip, ua) values ('client', cid, d, v, i.ip, i.ua)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('version', v, 'ok', true);
end $$;
grant execute on function public.client_accept_legal(text, text, text[]) to anon, authenticated;

-- La puerta del atleta informa de si ya aceptó la versión vigente y de si Premium se puede cobrar
create or replace function public.client_gate(p_u text, p_p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c record; k record; ready boolean; paid boolean; trial boolean; solo boolean; susp boolean; owner boolean; prem boolean; pp numeric;
        v_cobro boolean; v_lv text := public.nx_legal_version(); v_legal boolean; v_pre boolean;
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
  select coalesce((value #>> '{}')::boolean, false) into v_cobro from app_config where key = 'cobro_premium';
  v_cobro := coalesce(v_cobro, false);
  paid  := c.pago_estado = 'pagado' and c.pagado_hasta is not null and c.pagado_hasta > now();
  -- Mientras Nexum no cobre Premium (cobro_premium = false) el atleta sin entrenador sigue con acceso gratuito de lanzamiento
  trial := not paid and solo and (not v_cobro or (c.prueba_hasta is not null and c.prueba_hasta > now()));
  prem  := solo and coalesce(c.premium,false) and paid;
  select coalesce((value #>> '{}')::numeric, 9.95) into pp from app_config where key = 'premium_precio';
  select count(*) = 2 into v_legal from legal_acceptances where subject_kind = 'client' and subject_id = c.id and version = v_lv and doc in ('terminos','privacidad');
  v_pre := exists (select 1 from legal_acceptances where subject_kind = 'client' and subject_id = c.id and version = v_lv and doc = 'premium');
  return jsonb_build_object('ok', ready and (paid or trial) and not susp, 'suspendido', susp,
    'coach_ready', ready, 'paid', paid,
    'prueba', trial, 'prueba_hasta', c.prueba_hasta, 'sin_coach', solo,
    'premium', prem, 'premium_precio', coalesce(pp, 9.95), 'quiere_entrenador', solo and coalesce(c.quiere_entrenador,false),
    'cobro_premium', v_cobro, 'lanzamiento', solo and not v_cobro and not paid,
    'legal_ok', v_legal, 'legal_version', v_lv, 'premium_ok', v_pre,
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

-- ---------- 5. Derechos RGPD ----------
create table if not exists public.privacy_requests (
  id uuid primary key default gen_random_uuid(),
  subject_kind text not null check (subject_kind in ('coach', 'client')),
  subject_id uuid not null,
  subject_name text,
  kind text not null check (kind in ('acceso', 'rectificacion', 'supresion', 'portabilidad', 'oposicion', 'limitacion')),
  nota text,
  status text not null default 'pendiente' check (status in ('pendiente', 'resuelta')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
alter table public.privacy_requests enable row level security;
revoke all on public.privacy_requests from anon, authenticated;

create or replace function public.nx_privacy_notify(p_name text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare v_mail text; v_body jsonb;
begin
  select value->>'email' into v_mail from app_config where key = 'nexum_fiscal';
  v_body := public.nx_mail(v_mail, 'Nexum', 'Nueva solicitud de derechos RGPD',
    p_name || ' ha solicitado: ' || p_kind || '. Tienes 1 mes para responder (Administración → Ajustes → Legal).', 'Abrir Nexum');
  if v_body is not null then
    begin perform public.email_post(jsonb_build_array(v_body)); exception when others then null; end;
  end if;
exception when others then null;
end $$;

create or replace function public.client_privacy_request(p_u text, p_p text, p_kind text, p_nota text default null) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare cid uuid; nm text; r uuid;
begin
  cid := public.client_id_by_cred(p_u, p_p)::uuid;
  if cid is null then raise exception 'credenciales'; end if;
  if p_kind not in ('acceso','rectificacion','supresion','portabilidad','oposicion','limitacion') then raise exception 'Solicitud no válida'; end if;
  if exists (select 1 from privacy_requests where subject_id = cid and kind = p_kind and status = 'pendiente') then
    raise exception 'Ya tienes una solicitud igual en curso'; end if;
  select name into nm from clients where id = cid;
  insert into privacy_requests(subject_kind, subject_id, subject_name, kind, nota) values ('client', cid, nm, p_kind, left(p_nota, 500)) returning id into r;
  perform public.nx_privacy_notify(coalesce(nm, 'Un atleta'), p_kind);
  return r;
end $$;
grant execute on function public.client_privacy_request(text, text, text, text) to anon, authenticated;

create or replace function public.coach_privacy_request(p_kind text, p_nota text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare nm text; r uuid;
begin
  if auth.uid() is null or not exists (select 1 from coaches where id = auth.uid()) then raise exception 'No permitido'; end if;
  if p_kind not in ('acceso','rectificacion','supresion','portabilidad','oposicion','limitacion') then raise exception 'Solicitud no válida'; end if;
  if exists (select 1 from privacy_requests where subject_id = auth.uid() and kind = p_kind and status = 'pendiente') then
    raise exception 'Ya tienes una solicitud igual en curso'; end if;
  select trim(coalesce(nombre,'') || ' ' || coalesce(apellidos,'')) into nm from coaches where id = auth.uid();
  insert into privacy_requests(subject_kind, subject_id, subject_name, kind, nota) values ('coach', auth.uid(), nm, p_kind, left(p_nota, 500)) returning id into r;
  perform public.nx_privacy_notify(coalesce(nullif(nm,''), 'Un entrenador'), p_kind);
  return r;
end $$;

create or replace function public.admin_privacy_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) order by (r.status = 'pendiente') desc, r.created_at desc) from (select * from privacy_requests order by created_at desc limit 100) r), '[]'::jsonb);
end $$;

-- Portabilidad / acceso inmediato: el atleta descarga sus datos
create or replace function public.client_export(p_u text, p_p text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare cid uuid; r jsonb;
begin
  cid := public.client_id_by_cred(p_u, p_p)::uuid;
  if cid is null then raise exception 'credenciales'; end if;
  select jsonb_build_object(
    'generado', now(), 'formato', 'Nexum · exportación de datos personales',
    'cuenta', (select to_jsonb(c) - 'pwd' - 'pwd_plain' - 'token' - 'stripe_customer_id' - 'stripe_subscription_id' - 'premium_sub_id' from clients c where c.id = cid),
    'informes_salud', coalesce((select jsonb_agg(jsonb_build_object('tipo', h.tipo, 'titulo', h.titulo, 'fecha', h.fecha, 'profesional', h.profesional, 'cuestionario', h.form, 'archivo', h.file_name, 'subido', h.created_at)) from health_docs h where h.client_id = cid), '[]'::jsonb),
    'aceptaciones_legales', coalesce((select jsonb_agg(jsonb_build_object('documento', a.doc, 'version', a.version, 'fecha', a.accepted_at)) from legal_acceptances a where a.subject_kind = 'client' and a.subject_id = cid), '[]'::jsonb))
  into r;
  return r;
end $$;
grant execute on function public.client_export(text, text) to anon, authenticated;

-- ---------- 6. Lista «listo para cobrar» ----------
create or replace function public.nx_ready() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f jsonb; fi jsonb; items jsonb := '[]'::jsonb; cobro_e boolean; cobro_p boolean; modo text;
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  select value into f  from app_config where key = 'nexum_fiscal';
  select value into fi from app_config where key = 'fiscal';
  f := coalesce(f, '{}'::jsonb); modo := coalesce(fi->>'modo', 'off');
  select coalesce((value #>> '{}')::boolean, false) into cobro_e from app_config where key = 'cobro_entrenadores';
  select coalesce((value #>> '{}')::boolean, false) into cobro_p from app_config where key = 'cobro_premium';
  items := items
    || jsonb_build_object('k','nombre',  'ok', coalesce(f->>'nombre','')    <> '', 'req', true)
    || jsonb_build_object('k','nif',     'ok', public.nx_nif_ok(f->>'nif'),         'req', true)
    || jsonb_build_object('k','direccion','ok', coalesce(f->>'direccion','') <> '', 'req', true)
    || jsonb_build_object('k','email',   'ok', coalesce(f->>'email','') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'req', true)
    || jsonb_build_object('k','territorio','ok', coalesce(f->>'territorio','') <> '', 'req', true)
    || jsonb_build_object('k','ticketbai','ok', modo = 'real', 'req', false, 'modo', modo)
    || jsonb_build_object('k','cobro_entrenadores','on', coalesce(cobro_e,false))
    || jsonb_build_object('k','cobro_premium','on', coalesce(cobro_p,false));
  return jsonb_build_object('items', items, 'legal_version', public.nx_legal_version(),
    'pendientes_rgpd', (select count(*) from privacy_requests where status = 'pendiente'),
    'listo', coalesce(f->>'nombre','') <> '' and public.nx_nif_ok(f->>'nif') and coalesce(f->>'direccion','') <> ''
             and coalesce(f->>'email','') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
end $$;

-- ---------- 7. admin_do: tramos, interruptor Premium y marcar solicitudes RGPD ----------
create or replace function public.admin_do(p_action text, p_kind text, p_id uuid, p_arg jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_days int; v_n int; v_key text; v_fis jsonb; t jsonb; v_prev numeric; v_i int;
begin
  if not public.is_admin() then raise exception 'No permitido'; end if;
  perform set_config('nx.admin', '1', true);
  if p_action = 'suspend' then
    if p_kind = 'coach' then update coaches set suspendido = coalesce((p_arg->>'on')::boolean, true) where id = p_id;
    else update clients set suspendido = coalesce((p_arg->>'on')::boolean, true) where id = p_id; end if;
  elsif p_action = 'trial' then
    v_days := greatest(-365, least(365, coalesce((p_arg->>'days')::int, 7)));
    if p_kind = 'coach' then
      update coaches set prueba_hasta = greatest(now(), coalesce(prueba_hasta, now())) + make_interval(days => v_days) where id = p_id;
    else
      update clients set prueba_hasta = greatest(now(), coalesce(prueba_hasta, now())) + make_interval(days => v_days) where id = p_id;
    end if;
  elsif p_action = 'reassign' then
    update clients set coach_id = nullif(p_arg->>'coach','')::uuid, coach = nullif(p_arg->>'coach','')::uuid where id = p_id;
  elsif p_action = 'want' then
    update clients set quiere_entrenador = coalesce((p_arg->>'on')::boolean, false), entrenador_pedido_at = case when coalesce((p_arg->>'on')::boolean, false) then now() end,
      pedido_nota = case when coalesce((p_arg->>'on')::boolean, false) then pedido_nota end where id = p_id and coach_id is null and coach is null;
  elsif p_action = 'resetpwd' then
    if length(coalesce(p_arg->>'pwd','')) < 6 then raise exception 'La contraseña debe tener 6 o más caracteres'; end if;
    update clients set pwd = crypt(p_arg->>'pwd', gen_salt('bf')), pwd_plain = null where id = p_id;
  elsif p_action = 'delete' then
    if p_kind = 'coach' then
      select count(*) into v_n from clients where coach_id = p_id or coach = p_id;
      if v_n > 0 then raise exception 'Este entrenador tiene % atletas. Reasígnalos antes de borrarlo', v_n; end if;
      delete from library where coach = p_id; delete from chat where coach = p_id;
      delete from events where owner = p_id or coach_id = p_id; delete from coach_review where coach_id = p_id;
      delete from coaches where id = p_id;
    else
      delete from chat where client_id = p_id; delete from events where client_id = p_id; delete from clients where id = p_id;
    end if;
  elsif p_action = 'review' then
    insert into coach_review(coach_id, revisada, nota, updated_at)
    values (p_id, coalesce((p_arg->>'revisada')::boolean, true), coalesce(p_arg->>'nota',''), now())
    on conflict (coach_id) do update set revisada = excluded.revisada, nota = excluded.nota, updated_at = now();
  elsif p_action = 'privacy_done' then
    update privacy_requests set status = 'resuelta', resolved_at = now() where id = p_id;
  elsif p_action = 'config' then
    v_key := p_arg->>'key';
    if v_key not in ('trial_dias','comision','aviso','video_coach','video_atleta','video_plan_3','video_plan_6','video_plan_9','stripe_pk','nexum_fiscal','nexum_iva','nutri_pct','nutri_fijo','ref_bono','coach_cuota_6','coach_cuota_12','coach_cuota_24','funciones','plan_mensual','plan_semestral','plan_fundador','cobro_entrenadores','cobro_premium','coach_tiers','fiscal') then
      raise exception 'Ajuste desconocido'; end if;
    if v_key = 'funciones' and jsonb_typeof(p_arg->'value') is distinct from 'object' then
      raise exception 'Valor no válido'; end if;
    if v_key like 'plan\_%' escape '\' and (jsonb_typeof(p_arg->'value') is distinct from 'number'
        or (p_arg->>'value')::numeric <= 0 or (p_arg->>'value')::numeric > 1000) then
      raise exception 'El precio debe estar entre 0 y 1000 €'; end if;
    if v_key = 'coach_tiers' then
      if jsonb_typeof(p_arg->'value') is distinct from 'array' or jsonb_array_length(p_arg->'value') <> 3 then
        raise exception 'Debe haber exactamente 3 tramos'; end if;
      v_prev := 0; v_i := 0;
      for t in select * from jsonb_array_elements(p_arg->'value') loop
        v_i := v_i + 1;
        if coalesce(t->>'key','') <> (array['inicio','crece','pro'])[v_i] then raise exception 'Tramos no válidos'; end if;
        if coalesce(t->>'nombre','') = '' or length(t->>'nombre') > 20 then raise exception 'Nombre de tramo no válido'; end if;
        if jsonb_typeof(t->'mensual') is distinct from 'number' or (t->>'mensual')::numeric <= 0 or (t->>'mensual')::numeric > 1000 then
          raise exception 'El precio mensual debe estar entre 0 y 1000 €'; end if;
        if t->'anual' is not null and t->'anual' <> 'null'::jsonb and (jsonb_typeof(t->'anual') is distinct from 'number' or (t->>'anual')::numeric <= 0 or (t->>'anual')::numeric > 10000) then
          raise exception 'El precio anual no es válido'; end if;
        if v_i < 3 then
          if jsonb_typeof(t->'max') is distinct from 'number' or (t->>'max')::int < 1 or (t->>'max')::int <= v_prev then
            raise exception 'Los topes de clientes deben ir en orden creciente'; end if;
          v_prev := (t->>'max')::int;
        elsif t->'max' is not null and t->'max' <> 'null'::jsonb then
          raise exception 'El último tramo no tiene tope'; end if;
      end loop;
    end if;
    if v_key in ('cobro_entrenadores', 'cobro_premium') and jsonb_typeof(p_arg->'value') is distinct from 'boolean' then
      raise exception 'Valor no válido'; end if;
    if v_key in ('cobro_entrenadores', 'cobro_premium') and (p_arg->'value') = 'true'::jsonb then
      select value into v_fis from app_config where key = 'nexum_fiscal';
      if v_fis is null or coalesce(v_fis->>'nombre','') = '' or coalesce(v_fis->>'direccion','') = ''
         or coalesce(v_fis->>'email','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or not public.nx_nif_ok(v_fis->>'nif') then
        raise exception 'Antes de cobrar rellena los datos del titular (nombre, NIF válido, dirección y email) en Administración → Facturas'; end if;
    end if;
    if v_key = 'fiscal' and (jsonb_typeof(p_arg->'value') is distinct from 'object'
        or coalesce(p_arg->'value'->>'modo','') not in ('off','simulado','real')
        or coalesce(p_arg->'value'->>'proveedor','invopop') not in ('invopop')) then
      raise exception 'Valor no válido'; end if;
    if v_key = 'nexum_fiscal' and coalesce(p_arg->'value'->>'territorio','araba') not in ('araba','bizkaia','gipuzkoa','navarra','comun') then
      raise exception 'Territorio no válido'; end if;
    if v_key = 'nexum_fiscal' and coalesce(p_arg->'value'->>'nif','') <> '' and not public.nx_nif_ok(p_arg->'value'->>'nif') then
      raise exception 'El NIF/NIE no es válido (revisa los números y la letra)'; end if;
    insert into app_config(key, value) values (v_key, p_arg->'value')
    on conflict (key) do update set value = excluded.value;
  else raise exception 'Acción desconocida'; end if;
  insert into admin_log(admin, action, target, detail)
  values ((select auth.uid()), p_action, coalesce(p_kind,'') || ':' || coalesce(p_id::text,''), p_arg);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 8. Planes antiguos de prueba (Mensual/Semestral/Fundador) → vuelven a «sin plan» ----------
do $$ begin
  perform set_config('nx.admin', '1', true);
  update coaches set plan = null, plan_precio = null, plan_meses = null, plan_desde = null, plan_hasta = null
   where plan in ('mensual', 'semestral', 'fundador') and stripe_subscription_id is null;
end $$;

-- ---------- 9. Permisos: las funciones del entrenador/administración no se pueden llamar sin sesión ----------
alter function public.nx_legal_version() set search_path = public;
alter function public.nx_req_info() set search_path = public;
revoke all on function public.clients_cap() from public, anon, authenticated;
revoke all on function public.coach_set_plan(text, text), public.coach_plan_options(), public.coach_legal_status(), public.coach_accept_legal(),
  public.coach_privacy_request(text, text), public.nx_ready(), public.admin_privacy_list() from public, anon;
grant execute on function public.coach_set_plan(text, text), public.coach_plan_options(), public.coach_legal_status(), public.coach_accept_legal(),
  public.coach_privacy_request(text, text), public.nx_ready(), public.admin_privacy_list() to authenticated;

-- ---------- 10. Más permisos: administración, nutricionistas y cobros manuales, solo con sesión ----------
-- Cada función ya comprueba el rol por dentro; esto impide además llamarlas sin sesión.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as f
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname in ('admin_do','admin_gen_nexum','admin_interviews','admin_log_list','admin_nutri_assign','admin_nutri_pay','admin_nutri_remove','admin_nutris',
                        'coach_set_paid','nutri_client_get','nutri_client_rev','nutri_client_save','nutri_clients_list','nutri_gen_invoice','nutri_set_photo','nutri_set_profile',
                        'staff_get_name','staff_set_name')
  loop
    execute format('revoke execute on function %s from public, anon', r.f);
    execute format('grant execute on function %s to authenticated, service_role', r.f);
  end loop;
end $$;
