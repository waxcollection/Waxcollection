# Despliegue seguro del administrador (Supabase Auth)

## 1. Ejecutar migraciones en orden
En **Supabase -> SQL Editor** ejecuta:
1. `perfumeria/database/001_admin_stock_functions.sql` (si no lo ejecutaste previamente).
2. `perfumeria/database/002_supabase_auth_admin.sql`.

La migración 002 crea `admin_usuarios`, agrega políticas RLS para administradores, autoriza operaciones autenticadas y restringe subidas a Storage.

## 2. Dar acceso a tu primer administrador
En **Supabase -> Authentication -> Users -> Add user** crea una cuenta con tu correo y una contraseña robusta. Confirma el correo según la configuración del proyecto. Copia el **User UID** (UUID), NO el correo.

En SQL Editor ejecuta, sustituyendo el UUID:
```sql
INSERT INTO public.admin_usuarios (user_id)
VALUES ('AQUI_EL_UUID_DEL_USUARIO')
ON CONFLICT (user_id) DO UPDATE SET activo = true;
```
Para revocar el acceso más adelante, cambia `activo` a `false`.
Si solo habrá administradores, desactiva registros públicos en **Authentication -> Providers -> Email** (opción de permitir nuevos usuarios).

## 3. Configurar Storage
Crea el bucket `perfumes` en **Supabase -> Storage**. Puedes hacerlo público para lectura de imágenes; la migración 002 restringe las escrituras a administradores autenticados. No habilites políticas de subida pública.

## 4. Streamlit Community Cloud
- Repositorio: `waxcollection/Waxcollection`
- Rama: `desarrollo-perfumeria`
- Archivo principal: `perfumeria/admin/app.py`
- Secrets:
```toml
SUPABASE_URL = "https://TU-PROYECTO.supabase.co"
SUPABASE_ANON_KEY = "TU_CLAVE_PUBLICA_ANON"
STORAGE_BUCKET = "perfumes"
```
Usa la clave `anon` (o publishable compatible), **NO** `service_role`. El administrador inicia sesión con su correo y contraseña creados en Supabase Auth.

## 5. Probar
1. Iniciar sesión con un usuario que NO figure en `admin_usuarios`: acceso denegado.
2. Iniciar sesión con el administrador: panel accesible.
3. Registrar una marca, un perfume y una presentación.
4. Subir imagen WebP, registrar entrada de botellas y abrir una botella.

## Seguridad
- La app no guarda contraseñas en tablas ni en GitHub.
- La clave anon es pública y está limitada por RLS; los permisos se determinan por `auth.uid()`.
- La lista de administradores no puede editarse mediante el frontend.
- El panel todavía requiere pruebas funcionales y una revisión adicional de permisos de escritura en inventario antes de manejar ventas reales.
- No compartas aquí contraseñas, JWT ni claves privadas.
