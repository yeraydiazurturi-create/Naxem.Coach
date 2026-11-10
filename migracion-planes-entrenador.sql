-- ============================================================================
-- Nexum · Planes del entrenador: Mensual · Semestral · Fundador (v47)
-- YA APLICADO en el proyecto jkwhysytxypajunivqmc el 2026-11-10
-- (migraciones planes_entrenador_columnas, _funciones y _admin).
-- Se guarda aquí como copia y documentación. Es idempotente: se puede volver a ejecutar.
--
-- Qué hace:
--   · Cada entrenador elige plan al registrarse (paso 3 de 3) o más tarde desde Inicio.
--       Mensual ....... 59 €/mes sin permanencia
--       Semestral ..... 49 €/mes, compromiso de 6 meses (cobro mensual)
--       Fundador ...... 39 €/mes, 24 meses a precio fijo (solo con un código de fundador)
--   · Los precios salen de app_config (editables en Administración → Planes) y el
--     precio que elige cada entrenador queda fijado en coaches.plan_precio.
--   · El entrenador NO puede escribir plan, precio ni estado de la suscripción:
--     lo protege el trigger coaches_protect_stripe. Solo coach_set_plan (precio de
--     la base de datos), el webhook de Stripe y el administrador los cambian.
--   · cobro_entrenadores = false → se elige plan pero no se cobra ni se bloquea a nadie.
--     Al ponerlo en true (Administración → Planes), al acabar la prueba hace falta
--     un plan activo (o código gratis) para añadir atletas.
-- ============================================================================

-- 1) Columnas
alter table public.coaches add column if not exists plan text;
alter table public.coaches add column if not exists plan_precio numeric;
alter table public.coaches add column if not exists plan_meses integer;
alter table public.coaches add column if not exists plan_desde date;
alter table public.coaches add column if not exists plan_hasta date;
alter table public.coaches add column if not exists sub_estado text;            -- trialing · active · past_due · canceled · gratis
alter table public.coaches add column if not exists sub_hasta timestamptz;
alter table public.coaches add column if not exists stripe_customer_id text;
alter table public.coaches add column if not exists stripe_subscription_id text;
alter table public.promo_codes add column if not exists plan text;              -- 'fundador' desbloquea el plan Fundador

-- 2) Precios y cobro (editables en Administración → Planes)
insert into public.app_config(key, value) values
  ('plan_mensual',       '59'::jsonb),
  ('plan_semestral',     '49'::jsonb),
  ('plan_fundador',      '39'::jsonb),
  ('cobro_entrenadores', 'false'::jsonb)
on conflict (key) do nothing;

-- 3) El entrenador no puede tocar su plan, su precio ni su suscripción desde el navegador
create or replace function public.coaches_protect_stripe()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if coalesce(auth.role(),'') <> 'service_role' and coalesce(current_setting('nx.admin', true),'') <> '1' then
    if tg_op = 'INSERT' then
      new.stripe_account_id := null; new.stripe_charges_enabled := false; new.cobra_directo := false;
      new.prueba_hasta := now() + public.nx_trial_days(); new.suspendido := false; new.ref_code := null; new.referido_por := null; new.promo_code := null; new.promo_pct := null; new.promo_meses := null; new.promo_inicio := null;
      new.plan := null; new.plan_precio := null; new.plan_meses := null; new.plan_desde := null; new.plan_hasta := null;
      new.sub_estado := null; new.sub_hasta := null; new.stripe_customer_id := null; new.stripe_subscription_id := null;
    else
      new.stripe_account_id := old.stripe_account_id; new.stripe_charges_enabled := old.stripe_charges_enabled;
      new.cobra_directo := old.cobra_directo;
      new.prueba_hasta := old.prueba_hasta; new.suspendido := old.suspendido; new.ref_code := old.ref_code; new.referido_por := old.referido_por; new.promo_code := old.promo_code; new.promo_pct := old.promo_pct; new.promo_meses := old.promo_meses; new.promo_inicio := old.promo_inicio;
      new.plan := old.plan; new.plan_precio := old.plan_precio; new.plan_meses := old.plan_meses; new.plan_desde := old.plan_desde; new.plan_hasta := old.plan_hasta;
      new.sub_estado := old.sub_estado; new.sub_hasta := old.sub_hasta; new.stripe_customer_id := old.stripe_customer_id; new.stripe_subscription_id := old.stripe_subscription_id;
    end if;
  end if;
  return new;
end $function$;

-- 4) Qué planes ve el entrenador (el Fundador solo si su código es de fundador)
create or replace function public.coach_plan_options()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare c record; cfg jsonb; f boolean;
begin
  select * into c from coaches where id = auth.uid();
  if not found then raise exception 'No eres entrenador'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cfg
    from app_config where key in ('plan_mensual','plan_semestral','plan_fundador','nexum_iva','cobro_entrenadores');
  f := c.promo_code is not null and exists (select 1 from promo_codes where code = c.promo_code and plan = 'fundador' and activo);
  return jsonb_build_object(
    'mensual',   coalesce((cfg->>'plan_mensual')::numeric, 59),
    'semestral', coalesce((cfg->>'plan_semestral')::numeric, 49),
    'fundador',  case when f then coalesce((cfg->>'plan_fundador')::numeric, 39) else null end,
    'iva',       coalesce((cfg->>'nexum_iva')::numeric, 21),
    'cobro',     coalesce((cfg->>'cobro_entrenadores')::boolean, false),
    'plan', c.plan, 'precio', c.plan_precio, 'meses', c.plan_meses, 'desde', c.plan_desde, 'hasta', c.plan_hasta,
    'estado', c.sub_estado, 'sub_hasta', c.sub_hasta);
end $function$;

-- 5) Elegir plan: el precio lo pone el servidor, nunca el navegador
create or replace function public.coach_set_plan(p_plan text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare c record; v_price numeric; v_meses int; v_hasta date;
begin
  select * into c from coaches where id = auth.uid();
  if not found then raise exception 'No eres entrenador'; end if;
  if p_plan is null or p_plan not in ('mensual','semestral','fundador') then raise exception 'Plan no válido'; end if;
  if coalesce(c.sub_estado, 'none') in ('active','trialing','past_due') then
    raise exception 'Ya tienes una suscripción en marcha. Para cambiar de plan, habla con el administrador.';
  end if;
  if p_plan = 'fundador' and not (c.promo_code is not null and exists (select 1 from promo_codes where code = c.promo_code and plan = 'fundador' and activo)) then
    raise exception 'El plan fundador necesita un código de fundador';
  end if;
  select (value #>> '{}')::numeric into v_price from app_config where key = 'plan_' || p_plan;
  v_price := coalesce(v_price, case p_plan when 'mensual' then 59 when 'semestral' then 49 else 39 end);
  v_meses := case p_plan when 'mensual' then 1 when 'semestral' then 6 else 24 end;
  v_hasta := case when p_plan = 'mensual' then null else (current_date + make_interval(months => v_meses))::date end;
  perform set_config('nx.admin', '1', true);
  update coaches set plan = p_plan, plan_precio = v_price, plan_meses = v_meses, plan_desde = current_date, plan_hasta = v_hasta,
         contrato_meses = v_meses, contrato_inicio = current_date, contrato_firma = now()
   where id = c.id;
  return jsonb_build_object('plan', p_plan, 'precio', v_price, 'meses', v_meses, 'desde', current_date, 'hasta', v_hasta);
end $function$;
grant execute on function public.coach_plan_options() to authenticated;
grant execute on function public.coach_set_plan(text) to authenticated;

-- 6) Códigos de descuento: un código puede ser «de fundador» (desbloquea el plan Fundador; admite 0 %)
create or replace function public.admin_promo_save(p_code text, p_pct integer, p_meses integer, p_activo boolean, p_nota text, p_plan text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare k text := upper(regexp_replace(trim(coalesce(p_code,'')), '[^A-Za-z0-9_-]', '', 'g'));
        v_plan text := nullif(trim(coalesce(p_plan,'')), '');
begin
  if not is_admin() then raise exception 'No permitido'; end if;
  if length(k) < 3 then raise exception 'El código necesita 3 caracteres o más'; end if;
  if v_plan is not null and v_plan <> 'fundador' then raise exception 'Plan no válido'; end if;
  if p_pct is null or p_pct < (case when v_plan = 'fundador' then 0 else 1 end) or p_pct > 100 then
    raise exception 'El descuento debe estar entre % y 100', (case when v_plan = 'fundador' then 0 else 1 end); end if;
  insert into promo_codes(code, kind, pct, meses, activo, nota, plan)
  values (k, 'admin', p_pct, nullif(p_meses, 0), coalesce(p_activo, true), p_nota, v_plan)
  on conflict (code) do update set pct = excluded.pct, meses = excluded.meses, activo = excluded.activo, nota = excluded.nota,
    plan = case when p_plan is null then promo_codes.plan else v_plan end;
end $function$;

create or replace function public.admin_promo_list()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin if not is_admin() then raise exception 'No permitido'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'kind',p.kind,'pct',p.pct,'meses',p.meses,'bono',p.bono,'activo',p.activo,'usos',p.usos,'nota',p.nota,'plan',p.plan,'owner',trim(coalesce(c.nombre,'')||' '||coalesce(c.apellidos,''))) order by p.created_at desc) from promo_codes p left join coaches c on c.id=p.owner),'[]'::jsonb); end $function$;

-- 7) Administración: nuevas claves permitidas en app_config (precios 1-1000 €, cobro true/false)
create or replace function public.admin_do(p_action text, p_kind text, p_id uuid, p_arg jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_days int; v_n int; v_key text;
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
  elsif p_action = 'config' then
    v_key := p_arg->>'key';
    if v_key not in ('trial_dias','comision','aviso','video_coach','video_atleta','video_plan_3','video_plan_6','video_plan_9','stripe_pk','nexum_fiscal','nexum_iva','nutri_pct','nutri_fijo','ref_bono','coach_cuota_6','coach_cuota_12','coach_cuota_24','funciones','plan_mensual','plan_semestral','plan_fundador','cobro_entrenadores') then
      raise exception 'Ajuste desconocido'; end if;
    if v_key = 'funciones' and jsonb_typeof(p_arg->'value') is distinct from 'object' then
      raise exception 'Valor no válido'; end if;
    if v_key like 'plan\_%' escape '\' and (jsonb_typeof(p_arg->'value') is distinct from 'number'
        or (p_arg->>'value')::numeric <= 0 or (p_arg->>'value')::numeric > 1000) then
      raise exception 'El precio debe estar entre 0 y 1000 €'; end if;
    if v_key = 'cobro_entrenadores' and jsonb_typeof(p_arg->'value') is distinct from 'boolean' then
      raise exception 'Valor no válido'; end if;
    insert into app_config(key, value) values (v_key, p_arg->'value')
    on conflict (key) do update set value = excluded.value;
  else raise exception 'Acción desconocida'; end if;
  insert into admin_log(admin, action, target, detail)
  values ((select auth.uid()), p_action, coalesce(p_kind,'') || ':' || coalesce(p_id::text,''), p_arg);
  return jsonb_build_object('ok', true);
end $function$;
grant execute on function public.admin_do(text, text, uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Pasos que NO son SQL (ya hechos en el proyecto):
--   · Edge Function coach-billing (coach-billing.ts), Verify JWT: ON.
--   · stripe-webhook actualizado (stripe-webhook.ts): reconoce la suscripción del entrenador.
--     Eventos necesarios en Stripe: checkout.session.completed, invoice.paid,
--     invoice.payment_failed, customer.subscription.deleted.
--   · Secretos: STRIPE_SECRET_KEY, SITE_URL, STRIPE_WEBHOOK_SECRET.
--   · Para el plan Fundador: Administración → Códigos → crea un código y marca
--     «código de fundador» (el descuento puede ser 0 %).
-- ---------------------------------------------------------------------------
