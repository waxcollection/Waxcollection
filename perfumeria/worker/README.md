# Cloudflare Worker

API TypeScript para lectura pública del catálogo, creación de pedidos, cálculo de precios y seguimiento limitado. Nunca publicar claves de servicio en el frontend.

## Despliegue Cloudflare
El Worker debe compilar desde `desarrollo-perfumeria`, con directorio raíz `perfumeria/worker` y comando `npx wrangler deploy`.
