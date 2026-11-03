-- 012: Reemplazo directo de función. No requiere ejecutar 010 ni 011.
-- Protege contra devoluciones falsas de envases al editar órdenes históricas.
-- No modifica saldos de inventario existentes.
BEGIN;
ALTER TABLE public.pedido_stock_aplicado
 ADD COLUMN IF NOT EXISTS envases_globales_aplicados integer NOT NULL DEFAULT 0
 CHECK (envases_globales_aplicados>=0);

CREATE OR REPLACE FUNCTION public.admin_sincronizar_stock_pedido(p_pedido_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
 v_state text;
 r record;
 v_delta integer;
 v_ml_delta numeric;
 v_global_delta integer;
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
          a.ml_por_unidad ml_previo,
          coalesce(a.envases_globales_aplicados,0) envases_globales_previos
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
   v_global_delta:=0;
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
     -- Una sola tabla de envases por tamaño, compartida por TODOS los perfumes.
     -- No modificar la porción histórica cuyo descuento global no está identificado.
     IF r.cantidad_actual < r.cantidad_previa-r.envases_globales_previos THEN
       RAISE EXCEPTION 'Pedido anterior a migración: conciliación manual requerida antes de reducir decants';
     END IF;
     v_global_delta:=v_delta;
     IF v_global_delta<>0 THEN
       UPDATE public.envases_decants
       SET unidades=unidades-v_global_delta,updated_at=now()
       WHERE ml=r.ml_por_unidad AND unidades-v_global_delta>=0;
       IF NOT FOUND THEN
         RAISE EXCEPTION 'Envases de % ml insuficientes',r.ml_por_unidad;
       END IF;
       INSERT INTO public.envases_decants_movimientos(ml,delta_unidades,motivo)
       VALUES(r.ml_por_unidad,-v_global_delta,
         'Pedido #'||p_pedido_id||' (movimiento global verificado)');
     END IF;
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
     INSERT INTO public.inventario_movimientos(
       inventario_id,tipo,delta_ml,observacion
     ) VALUES(v_inv_id,'ajuste',-v_ml_delta,
       'Pedido #'||p_pedido_id||' (ajuste neto de mililitros)');
   ELSE
     RAISE EXCEPTION 'Tipo de presentación desconocido: %',r.tipo;
   END IF;

   IF r.cantidad_actual=0 THEN
     DELETE FROM public.pedido_stock_aplicado
     WHERE pedido_id=p_pedido_id AND presentacion_id=r.presentacion_id;
   ELSE
     INSERT INTO public.pedido_stock_aplicado(
       pedido_id,presentacion_id,perfume_id,tipo,ml_por_unidad,cantidad,
       envases_globales_aplicados
     ) VALUES (
       p_pedido_id,r.presentacion_id,r.perfume_id,r.tipo,
       r.ml_por_unidad,r.cantidad_actual,
       CASE WHEN r.tipo='decant'
         THEN r.envases_globales_previos+v_global_delta ELSE 0 END
     ) ON CONFLICT(pedido_id,presentacion_id) DO UPDATE
       SET cantidad=excluded.cantidad,
           envases_globales_aplicados=excluded.envases_globales_aplicados;
   END IF;
 END LOOP;
END; $$;

REVOKE ALL ON FUNCTION public.admin_sincronizar_stock_pedido(bigint)
 FROM PUBLIC,anon,authenticated;
COMMIT;
