-- 002: Autenticación y autorización administrativa con Supabase Auth.
-- Ejecutar DESPUÉS de 001_admin_stock_functions.sql.
-- No se concede lectura pública de catálogo en esta etapa.
BEGIN;

CREATE TABLE IF NOT EXISTS public.admin_usuarios (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  activo boolean NOT NULL DEFAULT true,
  creado_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_usuarios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_usuarios FROM anon, authenticated;
GRANT SELECT ON public.admin_usuarios TO authenticated;

CREATE OR REPLACE FUNCTION public.es_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admin_usuarios a
    WHERE a.user_id = (SELECT auth.uid()) AND a.activo
  )
$$;
REVOKE ALL ON FUNCTION public.es_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_admin() TO authenticated;

DROP POLICY IF EXISTS admin_ver_propio_registro ON public.admin_usuarios;
CREATE POLICY admin_ver_propio_registro ON public.admin_usuarios
 FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

DO $$
DECLARE tabla text;
BEGIN
 FOREACH tabla IN ARRAY ARRAY[
  'marcas','perfumes','perfume_imagenes','presentaciones',
  'notas_olfativas','perfume_notas','acordes','perfume_acordes',
  'ocasiones','perfume_ocasiones','inventario','inventario_movimientos',
  'pedidos','pedido_detalles','pedido_historial','inventario_botellas',
  'contenido_imagenes','configuracion','descuentos'
 ] LOOP
  EXECUTE format('DROP POLICY IF EXISTS admin_gestion ON public.%I', tabla);
  EXECUTE format(
    'CREATE POLICY admin_gestion ON public.%I FOR ALL TO authenticated USING ((SELECT public.es_admin())) WITH CHECK ((SELECT public.es_admin()))', tabla
  );
 END LOOP;
END $$;

-- Las funciones de inventario de la migración 001 son SECURITY INVOKER.
-- Al ejecutarlas como authenticated se aplican las mismas políticas RLS.
-- Se mantiene el servicio sin privilegios de bypass desde Streamlit.
REVOKE ALL ON FUNCTION public.admin_ajustar_ml(bigint,numeric,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_ajustar_botellas(bigint,integer,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_abrir_botella(bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_ml(bigint,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_botellas(bigint,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_abrir_botella(bigint) TO authenticated;

-- El bucket de imágenes "perfumes" se crea manualmente desde Storage.
-- Su lectura pública depende de marcarlo Public; escritura solo para admin.
DROP POLICY IF EXISTS admin_subir_fotos_perfumes ON storage.objects;
CREATE POLICY admin_subir_fotos_perfumes ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'perfumes' AND (SELECT public.es_admin()));
DROP POLICY IF EXISTS admin_modificar_fotos_perfumes ON storage.objects;
CREATE POLICY admin_modificar_fotos_perfumes ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'perfumes' AND (SELECT public.es_admin()))
  WITH CHECK (bucket_id = 'perfumes' AND (SELECT public.es_admin()));
DROP POLICY IF EXISTS admin_eliminar_fotos_perfumes ON storage.objects;
CREATE POLICY admin_eliminar_fotos_perfumes ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'perfumes' AND (SELECT public.es_admin()));
DROP POLICY IF EXISTS admin_leer_fotos_perfumes ON storage.objects;
CREATE POLICY admin_leer_fotos_perfumes ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'perfumes' AND (SELECT public.es_admin()));

COMMIT;

-- PASO MANUAL DESPUÉS DE EJECUTAR:
-- 1) Authentication -> Users -> Add user (correo y contraseña; confirmar correo).
-- 2) Copiar UUID del usuario; sustituir en la instrucción siguiente y ejecutarla POR SEPARADO:
-- INSERT INTO public.admin_usuarios(user_id)
-- VALUES ('UUID_DEL_USUARIO') ON CONFLICT (user_id) DO UPDATE SET activo = true;
-- 3) Deshabilitar signups públicos en Authentication -> Providers -> Email si solo habrá administradores.
