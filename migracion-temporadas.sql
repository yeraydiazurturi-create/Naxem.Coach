-- v89 · Diseños de temporada (Navidad y Reyes · Halloween · Fiestas de La Blanca)
-- Añade el ajuste global «temporada» a Administración → Ajustes. Valores: '' (normal), 'navidad', 'halloween', 'blanca'.
-- Se aplica de forma aditiva sobre admin_do: no toca ninguna otra acción ni ajuste.
do $mig$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p
   where p.proname = 'admin_do' and p.pronamespace = 'public'::regnamespace;
  if d is null then raise exception 'admin_do no existe'; end if;
  if position('''temporada''' in d) > 0 then return; end if;          -- ya aplicado
  if position('''coach_tiers'',''fiscal'') then' in d) = 0 then raise exception 'No encuentro la lista de ajustes permitidos'; end if;
  if position('raise exception ''Ajuste desconocido''; end if;' in d) = 0 then raise exception 'No encuentro el aviso de ajuste desconocido'; end if;
  d := replace(d, '''coach_tiers'',''fiscal'') then', '''coach_tiers'',''fiscal'',''temporada'') then');
  d := replace(d, 'raise exception ''Ajuste desconocido''; end if;',
    'raise exception ''Ajuste desconocido''; end if;' || chr(10) ||
    '    if v_key = ''temporada'' and (jsonb_typeof(p_arg->''value'') is distinct from ''string'' or (p_arg->>''value'') not in ('''',''navidad'',''halloween'',''blanca'')) then' || chr(10) ||
    '      raise exception ''Temporada no válida''; end if;');
  execute d;
end $mig$;

insert into public.app_config(key, value) values ('temporada', '""'::jsonb) on conflict (key) do nothing;
