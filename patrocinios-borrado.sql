-- Nexum · Patrocinios: funciones de BORRADO (solo administrador).
-- Pégalo en Supabase → SQL Editor y ejecútalo una vez. Es idempotente.
-- (El resto de la migración, migracion-patrocinios.sql, ya está aplicada;
--  sin esto, «Pausar» funciona pero el botón ✕ de borrar muestra un aviso.)

create or replace function public.admin_sponsor_del(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  delete from public.sponsors where id = p_id;   -- sus anuncios se borran en cascada
end $$;

create or replace function public.admin_ad_del(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  delete from public.sponsor_ads where id = p_id;
end $$;

revoke all on function public.admin_sponsor_del(uuid) from public, anon;
revoke all on function public.admin_ad_del(uuid)      from public, anon;
grant execute on function public.admin_sponsor_del(uuid) to authenticated;
grant execute on function public.admin_ad_del(uuid)      to authenticated;
