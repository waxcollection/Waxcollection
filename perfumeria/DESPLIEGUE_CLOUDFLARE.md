# Despliegue Cloudflare — Perfumería

## Estado del proyecto
Primera versión **para pruebas**, no publicar comercialmente todavía.
Incluye catálogo responsive, filtros acumulables, ficha con fotografías y presentaciones, carrito en localStorage, registro de pedidos y seguimiento por código + últimos 4 del teléfono.

**Pendiente antes de operar:** completar confirmación de pedidos en Streamlit (transacción que descuente existencias), caducidad de pedidos, protección anti-abuso/rate limiting y pruebas integrales de compra.

## 1. Base de datos
En Supabase > SQL Editor ejecuta el archivo `perfumeria/database/003_public_store.sql` luego del 001 y 002.

La migración crea 3 funciones públicas limitadas: `tienda_catalogo`, `tienda_crear_pedido`, `tienda_seguimiento`. No abre políticas de consulta de tablas ni publica datos completos de clientes.

## 2. Crear Cloudflare Worker (API)
1. Cloudflare Dashboard → **Workers & Pages → Create application → conectar GitHub**.
2. Repositorio: `waxcollection/Waxcollection`.
3. Rama: `desarrollo-perfumeria`.
4. Root directory: `perfumeria/worker`.
5. Nombre de Worker: **perfumeria-api** (debe coincidir con `wrangler.toml`).
6. Si solicita comando de despliegue: `npx wrangler deploy`.
7. En **Settings → Variables and Secrets** configurar:
   - `SUPABASE_URL` = `https://...supabase.co`
   - `SUPABASE_ANON_KEY` = **legacy anon JWT** (no service_role)
   - `FRONTEND_ORIGIN` = URL exacta del sitio Pages, por ejemplo `https://mi-perfumeria.pages.dev`
8. Guardar y desplegar el Worker. URL habitual: `https://perfumeria-api.<tu-subdominio>.workers.dev`.

La primera visita a Worker antes de configurar sus variables puede dar error; es normal hasta introducirlas. No uses secretos privados de Supabase en Workers.

## 3. Crear Cloudflare Pages (frontend)
1. Cloudflare → Workers & Pages → Create application → **Pages** → Connect to Git.
2. Elige el mismo repositorio y rama `desarrollo-perfumeria` como producción.
3. Framework preset: **None**.
4. **Root directory (advanced):** `perfumeria/frontend`.
5. Build command: `exit 0` (o dejar vacío).
6. Output directory: `.`.
7. Deploy.

Cloudflare entregará una URL `https://<nombre>.pages.dev`. Reemplaza en Worker `FRONTEND_ORIGIN` por esta URL exacta sin barra final y vuelve a desplegar.

## 4. Ajustar frontend/config.js
En `perfumeria/frontend/config.js` reemplaza:
- `API_BASE` → URL final de tu Worker, sin barra final.
- `BRAND_NAME` → nombre comercial.
- `WHATSAPP_NUMBER` → número propio para recibir pedidos en formato `506XXXXXXXX` sin "+".

Al guardar y hacer commit en GitHub, Pages publicará la actualización en la rama conectada.

**Advertencia:** este archivo es público y no debe contener contraseñas ni service_role. El WhatsApp comercial será visible a los visitantes.

## 5. Pruebas básicas
1. En Streamlit agrega marca, perfume, presentación de botella y de decant, foto y existencias.
2. Visita Pages: deben aparecer perfumes, fotos y filtros.
3. Agrega varias presentaciones al carrito; cierra y regresa al sitio para comprobar persistencia.
4. Prueba compra con un teléfono controlado: debe registrar un pedido pendiente y abrir WhatsApp.
5. Consulta el seguimiento con código y últimos cuatro del teléfono.
6. Comprueba que un número de seguimiento incorrecto no devuelva información.

## Limitaciones conocidas
- `pendiente_pago` **no reserva inventario**. Antes de confirmar habrá que revalidarlo.
- La transición de estados y descuento de inventario al confirmar aún **no están implementados**.
- Los pedidos no se marcan abandonados automáticamente todavía.
- No hay pasarela de pago: WhatsApp solo prepara el mensaje; el cliente debe pulsar Enviar.
- Para un sitio accesible públicamente es importante habilitar limitación de solicitudes y protección antibots antes de publicar las rutas de pedido/seguimiento.
- Faltan pruebas de integración reales contra Supabase.
