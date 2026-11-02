# Perfumería — tienda y administración

Proyecto independiente dentro de Waxcollection, alojado en la rama `desarrollo-perfumeria`.

## Arquitectura prevista
- `frontend/`: catálogo responsive (HTML, CSS, JavaScript), carrito y seguimiento.
- `worker/`: API pública (Cloudflare Workers + TypeScript).
- `admin/`: administración privada con Streamlit/Python.
- `database/`: migraciones PostgreSQL de Supabase y funciones transaccionales.

## Reglas de negocio iniciales
- Un perfume puede tener varias fotos y presentaciones de botella o decant (2 ml y 5 ml).
- Inventario de botellas cerradas separado de los mililitros disponibles para decants.
- Las botellas se abren manualmente desde administración.
- Un pedido pendiente de pago no descuenta inventario; al confirmar se realiza una transacción atómica.
- Pedidos pendientes por más de 72 horas pueden pasar a abandonado.
- El carrito se guarda localmente y el checkout genera un pedido antes de abrir WhatsApp.
- El seguimiento público utiliza un código aleatorio y no expone datos personales completos.

## Preparación
1. Verificar el esquema ya creado en Supabase antes de generar migraciones.
2. Añadir funciones SQL seguras para inventario y pedidos.
3. Implementar el panel Streamlit.
4. Conectar el frontend y Workers.
5. Configurar las variables de entorno **fuera de GitHub**.

Este commit solo crea una estructura inicial; aún no es una aplicación ejecutable.
