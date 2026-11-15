-- ============================================================================
-- NEXUM · Activar la nueva versión de los textos legales (2026-11-13.2)
-- Qué cambia: los textos ya mencionan la música de Spotify (el reproductor solo se
-- conecta con Spotify si la persona pulsa «Cargar reproductor») y la foto de perfil
-- en el círculo de las stories.
--
-- ⚠ EJECÚTALO SOLO CUANDO YA HAYAS SUBIDO la web nueva (index.html v69) a Netlify.
--   En cuanto lo ejecutes, a TODOS los usuarios (tú, entrenadores y atletas) se les
--   pedirá aceptar de nuevo las condiciones al entrar. Si lo ejecutas antes de subir
--   la web, verán la pantalla de aceptación con los textos antiguos.
-- Debe coincidir con LEGAL_V del archivo index.html.
-- Idempotente.
-- ============================================================================
create or replace function public.nx_legal_version() returns text language sql immutable as $$ select '2026-11-13.2'::text $$;

-- Comprobación
select public.nx_legal_version() as version_vigente;
