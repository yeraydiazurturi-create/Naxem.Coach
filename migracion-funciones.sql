-- Nexum v42 · Interruptores de funciones (solo administración)
-- Guarda en app_config la clave "funciones" = {"lab":true,"rnk":false,...}. Si una función no aparece, está activa.
-- app_config_get() ya la entrega a todos los roles; solo cambia la lista de ajustes que admin_do acepta.
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
    if v_key not in ('trial_dias','comision','aviso','video_coach','video_atleta','video_plan_3','video_plan_6','video_plan_9','stripe_pk','nexum_fiscal','nexum_iva','nutri_pct','nutri_fijo','ref_bono','coach_cuota_6','coach_cuota_12','coach_cuota_24','funciones') then
      raise exception 'Ajuste desconocido'; end if;
    if v_key = 'funciones' and jsonb_typeof(p_arg->'value') is distinct from 'object' then
      raise exception 'Valor no válido'; end if;
    insert into app_config(key, value) values (v_key, p_arg->'value')
    on conflict (key) do update set value = excluded.value;
  else raise exception 'Acción desconocida'; end if;
  insert into admin_log(admin, action, target, detail)
  values ((select auth.uid()), p_action, coalesce(p_kind,'') || ':' || coalesce(p_id::text,''), p_arg);
  return jsonb_build_object('ok', true);
end $function$;
