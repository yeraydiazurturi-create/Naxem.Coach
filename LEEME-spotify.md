# Buscador de canciones de Spotify · Nexum

En el creador de stories, al añadir música, hay un campo **«Busca una canción o artista»** (y debajo, «o pega el enlace»). La búsqueda **no se hace desde el móvil**: la hace la función `story-files` de Supabase con una app de Spotify de Nexum. Así Spotify no recibe la IP ni los datos de quien busca, y no se carga ningún script de Spotify.

**Estado actual:** la función ya está desplegada (versión 4), pero **el buscador no funciona hasta que guardes dos claves** (abajo). Mientras tanto la app avisa «El buscador de canciones aún no está activado» y se puede pegar el enlace de la canción como antes.

## Activarlo (10 minutos, una sola vez)

1. Entra en **developer.spotify.com/dashboard** con tu cuenta de Spotify. Desde 2026 Spotify exige que la cuenta que crea una app en modo desarrollo tenga **Premium**.
2. **Create app** → nombre «Nexum», una descripción corta, y en *Redirect URI* pon `https://getnaxem.netlify.app` (es obligatorio rellenarlo pero no se usa). En *APIs used* marca **Web API**. Acepta las condiciones.
3. Dentro de la app: **Settings** → copia el **Client ID** y pulsa «View client secret» para copiar el **Client secret**.
4. En **Supabase → Edge Functions → Secrets** (proyecto `jkwhysytxypajunivqmc`) crea estos dos secretos:
   - `SPOTIFY_CLIENT_ID` = el Client ID
   - `SPOTIFY_CLIENT_SECRET` = el Client secret
   (No hace falta volver a desplegar nada.)
5. Prueba: crea una story → «Música de Spotify» → escribe un título. Deben salir hasta 10 canciones; al tocar una, se añade con «Título — Artista».

## Qué guarda y qué no

- De cada story con música solo se guarda el identificador de la canción y su nombre («Título — Artista»), igual que antes.
- No se muestran carátulas (cargarlas desde los servidores de Spotify enviaría la IP de la persona). Si más adelante las quieres, hay que decirlo en la política de privacidad.
- El reproductor de Spotify sigue cargándose **solo si quien ve la story pulsa «Cargar reproductor»**.
- La búsqueda solo está disponible para quien puede publicar stories (la función lo comprueba en el servidor).

## Límites y avisos

- Spotify limita cada búsqueda a **10 resultados**.
- Si Spotify responde con demasiadas peticiones, el creador lo dice y se puede reintentar en unos segundos.
- En modo desarrollo Spotify limita la app (Premium del titular y 5 usuarios autorizados). La búsqueda de Nexum **no usa cuentas de usuario**, y la documentación no aclara si ese tope le afecta. Si un día falla con muchos usuarios, el enlace pegado sigue funcionando y habría que pedir a Spotify el modo ampliado.
- Guarda el Client secret solo en Supabase; no lo pegues en el código ni en la web.
