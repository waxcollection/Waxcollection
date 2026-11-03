-- 007: Control físico de decants preparados de cualquier tamaño (2/5/10 ml habituales).
-- Ejecutar después de 006.
-- inventario.ml_abiertos = total de ml no vendidos (incluye los ya envasados).
-- ml libres para preparar = ml_abiertos - sum(unidades preparadas * tamaño).
-- Preparar no cambia ml_abiertos. Vender decants descuenta ml y unidades en la misma transacción.
-- Pedidos anteriores a 007 requieren conciliación manual de decants ya rebajados.
BEGIN;

CREATE TABLE IF NOT EXISTS public.inventario_decants (
  presentacion_id bigint PRIMARY KEY REFERENCES public.presentaciones(id) ON DELETE RESTRICT,
  unidades integer NOT NULL DEFAULT 0 CHECK (unidades >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.inventario_decants_movimientos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  presentacion_id bigint NOT NULL REFERENCES public.presentaciones(id) ON DELETE RESTRICT,
  delta_unidades integer NOT NULL CHECK (delta_unidades <> 0),
  motivo text NOT NULL,
  pedido_id bigint REFERENCES public.pedidos(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_decants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventario_decants_movimientos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventario_decants,public.inventario_decants_movimientos
 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.inventario_decants,public.inventario_decants_movimientos TO authenticated;
DROP POLICY IF EXISTS admin_ver_decants ON public.inventario_decants;
CREATE POLICY admin_ver_decants ON public.inventario_decants FOR SELECT TO authenticated
 USING ((SELECT public.es_admin()));
DROP POLICY IF EXISTS admin_ver_decant_movs ON public.inventario_decants_movimientos;
CREATE POLICY admin_ver_decant_movs ON public.inventario_decants_movimientos FOR SELECT TO authenticated
 USING ((SELECT public.es_admin()));

CREATE OR REPLACE FUNCTION public.admin_ajustar_decants(
 p_presentacion_id bigint,p_delta integer,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
 v_perfume bigint;
 v_tamano numeric;
 v_total numeric;
 v_preparados numeric;
 v_nuevos integer;
BEGIN
 IF auth.uid() IS NULL OR NOT (SELECT public.es_admin()) THEN
   RAISE EXCEPTION 'Acceso administrativo requerido';
 END IF;
 IF p_delta IS NULL OR p_delta=0 OR abs(p_delta)>10000
  OR nullif(btrim(coalesce(p_motivo,'')),'') IS NULL OR length(p_motivo)>500 THEN
   RAISE EXCEPTION 'Cantidad o motivo inválidos';
 END IF;
 SELECT perfume_id,ml INTO v_perfume,v_tamano
 FROM public.presentaciones WHERE id=p_presentacion_id AND tipo='decant';
 IF NOT FOUND OR v_tamano IS NULL OR v_tamano<=0 THEN
   RAISE EXCEPTION 'La presentación seleccionada no es un decant válido';
 END IF;
 -- Siempre bloquear el saldo total antes de contar unidades envasadas.
 INSERT INTO public.inventario(perfume_id,ml_abiertos)
 VALUES(v_perfume,0) ON CONFLICT(perfume_id) DO NOTHING;
 SELECT ml_abiertos INTO v_total FROM public.inventario
 WHERE perfume_id=v_perfume FOR UPDATE;

 INSERT INTO public.inventario_decants(presentacion_id,unidades)
 VALUES(p_presentacion_id,0) ON CONFLICT(presentacion_id) DO NOTHING;
 UPDATE public.inventario_decants SET
   unidades=unidades+p_delta, updated_at=now()
 WHERE presentacion_id=p_presentacion_id AND unidades+p_delta>=0
 RETURNING unidades INTO v_nuevos;
 IF NOT FOUND THEN RAISE EXCEPTION 'No hay suficientes decants para retirar'; END IF;

 SELECT coalesce(sum(d.unidades*v.ml),0) INTO v_preparados
 FROM public.inventario_decants d
 JOIN public.presentaciones v ON v.id=d.presentacion_id
 WHERE v.perfume_id=v_perfume AND v.tipo='decant';
 IF v_preparados>v_total THEN
   RAISE EXCEPTION 'No hay suficientes ml libres: total % ml, envasados % ml',
      v_total,v_preparados;
 END IF;

 INSERT INTO public.inventario_decants_movimientos(
   presentacion_id,delta_unidades,motivo)
 VALUES(p_presentacion_id,p_delta,btrim(p_motivo));
 RETURN jsonb_build_object('presentacion_id',p_presentacion_id,'unidades',v_nuevos,
   'ml_totales',v_total,'ml_envasados',v_preparados,
   'ml_libres',v_total-v_preparados);
END $$;

REVOKE ALL ON FUNCTION public.admin_ajustar_decants(bigint,integer,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_decants(bigint,integer,text)
 TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_sincronizar_stock_pedido(p_pedido_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
 v_state text;
 r record;
 v_delta integer;
 v_ml_delta numeric;
 v_inv_id bigint;
BEGIN
 IF auth.uid() IS NULL OR NOT (SELECT public.es_admin()) THEN
   RAISE EXCEPTION 'Acceso administrativo requerido';
 END IF;
 -- Serializa dos ediciones del mismo pedido y evita el doble descuento.
 SELECT estado::text INTO v_state FROM public.pedidos
 WHERE id=p_pedido_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;

 IF v_state IN ('pendiente_pago','cancelado','abandonado') THEN RETURN; END IF;

 FOR r IN
   WITH requested AS (
     SELECT d.presentacion_id,v.perfume_id,
            d.presentacion_tipo_snapshot::text tipo,
            d.presentacion_ml_snapshot ml_por_unidad,
            sum(d.cantidad)::integer cantidad
     FROM public.pedido_detalles d
     JOIN public.presentaciones v ON v.id=d.presentacion_id
     WHERE d.pedido_id=p_pedido_id
     GROUP BY d.presentacion_id,v.perfume_id,
              d.presentacion_tipo_snapshot,d.presentacion_ml_snapshot
   )
   SELECT coalesce(q.presentacion_id,a.presentacion_id) presentacion_id,
          coalesce(q.perfume_id,a.perfume_id) perfume_id,
          coalesce(q.tipo,a.tipo) tipo,
          coalesce(q.ml_por_unidad,a.ml_por_unidad) ml_por_unidad,
          coalesce(q.cantidad,0) cantidad_actual,
          coalesce(a.cantidad,0) cantidad_previa,
          a.perfume_id perfume_previo,
          a.tipo tipo_previo,
          a.ml_por_unidad ml_previo
   FROM requested q FULL OUTER JOIN public.pedido_stock_aplicado a
     ON a.pedido_id=p_pedido_id AND a.presentacion_id=q.presentacion_id
   ORDER BY coalesce(q.presentacion_id,a.presentacion_id)
 LOOP
   IF r.cantidad_previa>0 AND r.cantidad_actual>0
     AND (r.perfume_id IS DISTINCT FROM r.perfume_previo
          OR r.tipo IS DISTINCT FROM r.tipo_previo
          OR r.ml_por_unidad IS DISTINCT FROM r.ml_previo) THEN
       RAISE EXCEPTION 'Presentación cambió después del descuento; requiere revisión';
   END IF;
   v_delta:=r.cantidad_actual-r.cantidad_previa;
   IF v_delta=0 THEN CONTINUE; END IF;

   v_inv_id:=NULL;
   IF r.tipo='botella' THEN
     INSERT INTO public.inventario_botellas(presentacion_id,unidades)
     VALUES(r.presentacion_id,0)
     ON CONFLICT(presentacion_id) DO NOTHING;
     UPDATE public.inventario_botellas SET
       unidades=unidades-v_delta,updated_at=now()
     WHERE presentacion_id=r.presentacion_id AND unidades-v_delta>=0
     RETURNING id INTO v_inv_id;
     IF v_inv_id IS NULL THEN
       RAISE EXCEPTION 'Botellas insuficientes para pedido %, presentación %',
         p_pedido_id,r.presentacion_id;
     END IF;
     INSERT INTO public.inventario_movimientos(
       inventario_botellas_id,tipo,delta_botellas,observacion
     ) VALUES(v_inv_id,'ajuste',-v_delta,
       'Pedido #'||p_pedido_id||' (ajuste neto de unidades)');
   ELSIF r.tipo='decant' THEN
     v_ml_delta:=r.ml_por_unidad*v_delta;
     INSERT INTO public.inventario(perfume_id,ml_abiertos)
     VALUES(r.perfume_id,0)
     ON CONFLICT(perfume_id) DO NOTHING;
     UPDATE public.inventario SET
       ml_abiertos=ml_abiertos-v_ml_delta,updated_at=now()
     WHERE perfume_id=r.perfume_id AND ml_abiertos-v_ml_delta>=0
     RETURNING id INTO v_inv_id;
     IF v_inv_id IS NULL THEN
       RAISE EXCEPTION 'Mililitros insuficientes para pedido %, perfume %',
         p_pedido_id,r.perfume_id;
     END IF;
     UPDATE public.inventario_decants
       SET unidades=unidades-v_delta,updated_at=now()
     WHERE presentacion_id=r.presentacion_id AND unidades-v_delta>=0;
     IF NOT FOUND THEN
       RAISE EXCEPTION 'Decants preparados insuficientes para pedido %, presentación %',
         p_pedido_id,r.presentacion_id;
     END IF;
     INSERT INTO public.inventario_movimientos(inventario_id,tipo,delta_ml,observacion)
     VALUES(v_inv_id,'ajuste',-v_ml_delta,
       'Pedido #'||p_pedido_id||' (venta decants, variación neta de ml)');
     INSERT INTO public.inventario_decants_movimientos(
       presentacion_id,delta_unidades,motivo,pedido_id)
     VALUES(r.presentacion_id,-v_delta,'Pedido #'||p_pedido_id||' (variación neta de unidades)',p_pedido_id);
   ELSE
     RAISE EXCEPTION 'Tipo de presentación desconocido: %',r.tipo;
   END IF;

   IF r.cantidad_actual=0 THEN
     DELETE FROM public.pedido_stock_aplicado
     WHERE pedido_id=p_pedido_id AND presentacion_id=r.presentacion_id;
   ELSE
     INSERT INTO public.pedido_stock_aplicado(
       pedido_id,presentacion_id,perfume_id,tipo,ml_por_unidad,cantidad
     ) VALUES (
       p_pedido_id,r.presentacion_id,r.perfume_id,r.tipo,
       r.ml_por_unidad,r.cantidad_actual
     ) ON CONFLICT(pedido_id,presentacion_id) DO UPDATE
       SET cantidad=excluded.cantidad;
   END IF;
 END LOOP;
END; $$;


REVOKE ALL ON FUNCTION public.admin_sincronizar_stock_pedido(bigint)
 FROM PUBLIC,anon,authenticated;

-- La RPC administrativa de 006 ya invoca sincronizar al guardar cambios.
-- Reutilizamos su lógica con el control adicional de decants preparados.

CREATE OR REPLACE FUNCTION public.tienda_catalogo()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'marcas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id',m.id,'nombre',m.nombre) ORDER BY m.nombre)
      FROM public.marcas m WHERE m.activo
    ), '[]'::jsonb),
    'ocasiones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id',o.id,'nombre',o.nombre) ORDER BY o.nombre)
      FROM public.ocasiones o
    ), '[]'::jsonb),
    'perfumes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',p.id,'nombre',p.nombre,'slug',p.slug,'marca_id',p.marca_id,
        'descripcion',p.descripcion,'genero',p.genero,'familia_olfativa',p.familia_olfativa,
        'imagenes',COALESCE((
          SELECT jsonb_agg(jsonb_build_object('path',i.storage_path,'alt',i.alt_text) ORDER BY i.principal DESC,i.orden,i.id)
          FROM public.perfume_imagenes i WHERE i.perfume_id=p.id
        ),'[]'::jsonb),
        'ocasiones',COALESCE((
          SELECT jsonb_agg(po.ocasion_id) FROM public.perfume_ocasiones po WHERE po.perfume_id=p.id
        ),'[]'::jsonb),
        'acordes',COALESCE((
          SELECT jsonb_agg(jsonb_build_object('nombre',a.nombre,'intensidad',pa.intensidad) ORDER BY pa.intensidad DESC)
          FROM public.perfume_acordes pa JOIN public.acordes a ON a.id=pa.acorde_id
          WHERE pa.perfume_id=p.id
        ),'[]'::jsonb),
        'presentaciones',COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id',v.id,'tipo',v.tipo,'ml',v.ml,
            'precio',v.precio,
            'descuento',COALESCE((
              SELECT max(d.porcentaje)
              FROM public.descuentos d
              WHERE d.activo AND (d.inicia_at IS NULL OR d.inicia_at<=now())
                AND (d.termina_at IS NULL OR d.termina_at>now())
                AND (d.presentacion_id=v.id OR d.perfume_id=p.id)
            ),0),
            'disponible',CASE WHEN v.tipo='botella' THEN
              COALESCE((SELECT ib.unidades FROM public.inventario_botellas ib WHERE ib.presentacion_id=v.id),0)
              ELSE COALESCE((SELECT idc.unidades FROM public.inventario_decants idc WHERE idc.presentacion_id=v.id),0) END
          ) ORDER BY v.tipo,v.ml)
          FROM public.presentaciones v WHERE v.perfume_id=p.id AND v.activo
        ),'[]'::jsonb)
      ) ORDER BY p.nombre)
      FROM public.perfumes p JOIN public.marcas m ON m.id=p.marca_id
      WHERE p.activo AND m.activo
    ),'[]'::jsonb)
  )
$$;

CREATE OR REPLACE FUNCTION public.tienda_crear_pedido(
  p_nombre text, p_telefono text, p_items jsonb
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pedido bigint; v_codigo text; v_total numeric(12,2):=0;
  v_item jsonb; v_id bigint; v_cantidad int;
  v_nombre text; v_tipo text; v_ml numeric; v_precio numeric; v_desc numeric;
  v_disponible numeric; v_perfume bigint;
  v_num int := 0; v_normalizado jsonb := '[]'::jsonb;
BEGIN
  IF p_nombre IS NULL OR length(btrim(p_nombre)) NOT BETWEEN 2 AND 120
     OR p_telefono IS NULL OR p_telefono !~ '^[+]506[0-9]{8}$'
     OR p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 20
  THEN RAISE EXCEPTION 'Datos de pedido inválidos'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_num := v_num + 1;
    IF jsonb_typeof(v_item) <> 'object'
      OR coalesce(v_item->>'presentacion_id','') !~ '^[0-9]{1,12}$'
      OR coalesce(v_item->>'cantidad','') !~ '^[0-9]{1,3}$'
    THEN RAISE EXCEPTION 'Artículo inválido'; END IF;
    v_id := (v_item->>'presentacion_id')::bigint;
    v_cantidad := (v_item->>'cantidad')::int;
    IF v_cantidad NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_normalizado) t WHERE (t->>'id')::bigint=v_id)
    THEN RAISE EXCEPTION 'Presentación duplicada'; END IF;

    SELECT p.id,p.nombre,v.tipo,v.ml,v.precio,
      COALESCE((SELECT max(d.porcentaje) FROM public.descuentos d
        WHERE d.activo AND (d.inicia_at IS NULL OR d.inicia_at<=now())
        AND (d.termina_at IS NULL OR d.termina_at>now())
        AND (d.presentacion_id=v.id OR d.perfume_id=p.id)),0),
      CASE WHEN v.tipo='botella' THEN COALESCE((
        SELECT ib.unidades FROM public.inventario_botellas ib WHERE ib.presentacion_id=v.id
      ),0)::numeric ELSE COALESCE((
        SELECT idc.unidades FROM public.inventario_decants idc WHERE idc.presentacion_id=v.id
      ),0)::numeric END
      INTO v_perfume,v_nombre,v_tipo,v_ml,v_precio,v_desc,v_disponible
    FROM public.presentaciones v JOIN public.perfumes p ON p.id=v.perfume_id
      JOIN public.marcas m ON m.id=p.marca_id
    WHERE v.id=v_id AND v.activo AND p.activo AND m.activo;
    IF NOT FOUND OR v_disponible < v_cantidad THEN
      RAISE EXCEPTION 'Presentación no disponible (id %)',v_id;
    END IF;
    v_precio:= round(v_precio*(1-v_desc/100),2);
    v_total := v_total + v_precio*v_cantidad;
    v_normalizado := v_normalizado || jsonb_build_array(
      jsonb_build_object('id',v_id,'cantidad',v_cantidad,'nombre',v_nombre,
        'tipo',v_tipo,'ml',v_ml,'precio',v_precio)
    );
  END LOOP;

  -- Los decants de 2 ml y 5 ml comparten el mismo saldo abierto.
  -- Verificar la suma solicitada por perfume, no solo cada variante.
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT v.perfume_id, sum((it->>'cantidad')::numeric * v.ml) AS ml_solicitados
      FROM jsonb_array_elements(v_normalizado) it
      JOIN public.presentaciones v ON v.id=(it->>'id')::bigint
      WHERE v.tipo='decant'
      GROUP BY v.perfume_id
    ) d
    LEFT JOIN public.inventario inv ON inv.perfume_id=d.perfume_id
    WHERE d.ml_solicitados > COALESCE(inv.ml_abiertos,0)
  ) THEN RAISE EXCEPTION 'No hay suficientes mililitros para los decants seleccionados'; END IF;

  INSERT INTO public.pedidos(nombre_completo,telefono_e164,total,estado)
  VALUES (btrim(p_nombre),p_telefono,v_total,'pendiente_pago')
  RETURNING id,codigo_seguimiento INTO v_pedido,v_codigo;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_normalizado) LOOP
    INSERT INTO public.pedido_detalles(
      pedido_id,presentacion_id,perfume_nombre_snapshot,presentacion_tipo_snapshot,
      presentacion_ml_snapshot,cantidad,precio_unitario
    ) VALUES(
      v_pedido,(v_item->>'id')::bigint,v_item->>'nombre',v_item->>'tipo',
      (v_item->>'ml')::numeric,(v_item->>'cantidad')::int,(v_item->>'precio')::numeric
    );
  END LOOP;
  INSERT INTO public.pedido_historial(pedido_id,estado_nuevo,actor,nota)
  VALUES(v_pedido,'pendiente_pago','cliente','Pedido creado desde tienda');
  RETURN jsonb_build_object('numero',v_pedido,'codigo',v_codigo,'total',v_total,
    'items',v_normalizado);
END $$;


REVOKE ALL ON FUNCTION public.tienda_catalogo() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tienda_crear_pedido(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tienda_catalogo() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tienda_crear_pedido(text,text,jsonb) TO anon;
COMMIT;
