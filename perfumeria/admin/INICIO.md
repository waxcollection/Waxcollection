# Inicio del administrador Streamlit

## 1. Base de datos
El esquema principal ya está creado. En Supabase → SQL Editor ejecuta `perfumeria/database/001_admin_stock_functions.sql` **una vez** para habilitar movimientos seguros de inventario.

## 2. Storage
En Supabase → Storage crea el bucket **perfumes** y márcalo como **Public** únicamente para lectura pública de imágenes. No publiques la clave `service_role`; las subidas las realiza exclusivamente Streamlit. No crees políticas públicas de escritura.

## 3. Secrets locales
En `perfumeria/admin/` crea `.streamlit/secrets.toml` a partir de `.streamlit/secrets.toml.example`. Introduce la URL del proyecto, la clave `service_role` y una contraseña administrativa robusta. **No subas el archivo real a GitHub.**

## 4. Ejecutar en Windows PowerShell
```powershell
cd perfumeria/admin
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
streamlit run app.py
```
Puedes usar `python -m streamlit run app.py` si el comando no aparece.

## 5. Uso inicial
1. Registrar marcas.
2. Registrar perfumes.
3. Registrar presentaciones de 2 ml, 5 ml y botellas comerciales.
4. Cargar fotografías optimizadas a WebP (máximo 800 px).
5. Añadir stock de botellas; abrir manualmente una botella para habilitar los ml de decants.

## Importante
- Esta primera versión no incluye pedidos, notas/acordes/ocasiones ni el frontend público.
- Mantén Streamlit accesible **solo localmente o tras VPN**. La contraseña interna es defensa adicional, no sustituto de un despliegue seguro.
- Los cambios manuales de inventario deben pasar por las funciones SQL; no edites cantidades directamente.
- El texto del error de Supabase puede incluir información técnica. No compartas capturas con credenciales.
