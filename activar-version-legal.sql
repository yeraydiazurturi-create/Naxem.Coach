-- ============================================================================
-- NEXUM · Activar la nueva versión de los textos legales (2026-11-15) y el archivo privado de stories
-- Qué cambia en los textos:
--   · Música de Spotify en las stories (el reproductor solo se conecta con Spotify si la persona pulsa
--     «Cargar reproductor») y foto de perfil en el círculo de las stories.
--   · HISTORIAL PRIVADO: las stories que se comparten con el GRUPO se conservan, solo para su autor,
--     hasta 12 meses y un máximo de 100 (ya no «desaparecen» del todo a las 24 h). Las que se comparten con
--     toda la comunidad (o como «Nexum») siguen borrándose a las 24 h.
--   · Buscador de canciones de Spotify en el creador de stories (v73; necesita los secretos SPOTIFY_CLIENT_ID y
--     SPOTIFY_CLIENT_SECRET en Supabase; sin ellos el creador sigue admitiendo el enlace de la canción).
--   · Logros (récords, rachas, constancia, nivel, evaluaciones) y hitos del entrenador; los atletas del grupo ven,
--     si no ocultan su resumen, hasta 4 logros recientes sin cifras.
--
-- ⚠ EJECÚTALO SOLO CUANDO YA HAYAS SUBIDO la web nueva (index.html v73) a Netlify.
--   · En cuanto lo ejecutes, a TODOS los usuarios (tú, entrenadores y atletas) se les pedirá aceptar de nuevo las
--     condiciones al entrar. Si lo ejecutas antes de subir la web, verán la pantalla de aceptación con los textos antiguos.
--   · Además ENCIENDE el archivo privado: desde ese momento las stories de grupo dejan de borrarse a las 24 h
--     (se conservan en el historial de su autor). Antes de este paso NADA se conserva, así que lo que ya estaba
--     publicado no contradice los textos legales vigentes.
-- Debe coincidir con LEGAL_V del archivo index.html.
-- Idempotente.
--
-- Para DESHACER el archivo (sin tocar la versión legal):
--   update app_config set value = 'false'::jsonb where key = 'story_archive';
--   (en la siguiente purga horaria se borran los archivos caducados; las filas, a los 7 días)
-- ============================================================================
create or replace function public.nx_legal_version() returns text language sql immutable as $$ select '2026-11-15'::text $$;

insert into public.app_config (key, value) values ('story_archive', 'true'::jsonb)
on conflict (key) do update set value = 'true'::jsonb;

-- Comprobación
select public.nx_legal_version() as version_vigente,
       (select value from public.app_config where key = 'story_archive') as archivo_privado;
