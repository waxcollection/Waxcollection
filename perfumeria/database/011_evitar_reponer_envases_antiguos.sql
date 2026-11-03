-- 011: corregir acreditaciones fantasma de envases al modificar pedidos.
-- Esta migracion no altera saldos existentes.
BEGIN;
ALTER TABLE public.pedido_stock_aplicado
 ADD COLUMN IF NOT EXISTS envases_globales_aplicados integer NOT NULL DEFAULT 0;
DO $patch$
DECLARE src text;
BEGIN
 src := pg_get_functiondef('public.admin_sincronizar_stock_pedido(bigint)'::regprocedure);
 IF position('v_global_delta integer;' in src) > 0 THEN RETURN; END IF;
 src := replace(src,' v_ml_delta numeric;',' v_ml_delta numeric;'||E'\n'||' v_global_delta integer;');
 src := replace(src,'          a.ml_por_unidad ml_previo',
     '          a.ml_por_unidad ml_previo,'||E'\n'||
     '          coalesce(a.envases_globales_aplicados,0) envases_globales_previos');
 src := replace(src,'   v_inv_id:=NULL;',
     '   v_inv_id:=NULL;'||E'\n'||'   v_global_delta:=0;');
 src := replace(src,
  '     UPDATE public.envases_decants'||E'\n'||
  '       SET unidades=unidades-v_delta,updated_at=now()'||E'\n'||
  '     WHERE ml=r.ml_por_unidad AND unidades-v_delta>=0;'||E'\n'||
  '     IF NOT FOUND THEN'||E'\n'||
  '       RAISE EXCEPTION ''Decants de % ml insuficientes para el pedido %'','||E'\n'||
  '         r.ml_por_unidad,p_pedido_id;'||E'\n'||
  '     END IF;'||E'\n'||
  '     INSERT INTO public.envases_decants_movimientos(ml,delta_unidades,motivo)'||E'\n'||
  '       VALUES(r.ml_por_unidad,-v_delta,'||E'\n'||
  '         ''Pedido #''||p_pedido_id||'' (ajuste neto de envases)'');',
  '     v_global_delta:=CASE WHEN v_delta>=0 THEN v_delta ELSE greatest(v_delta,-r.envases_globales_previos) END;'||E'\n'||
  '     IF v_global_delta<>0 THEN'||E'\n'||
  '       UPDATE public.envases_decants SET unidades=unidades-v_global_delta,updated_at=now()'||E'\n'||
  '       WHERE ml=r.ml_por_unidad AND unidades-v_global_delta>=0;'||E'\n'||
  '       IF NOT FOUND THEN RAISE EXCEPTION ''Envases de % ml insuficientes'',r.ml_por_unidad; END IF;'||E'\n'||
  '       INSERT INTO public.envases_decants_movimientos(ml,delta_unidades,motivo)'||E'\n'||
  '       VALUES(r.ml_por_unidad,-v_global_delta,''Pedido #''||p_pedido_id||'' (global verificado)'');'||E'\n'||
  '     END IF;');
 src := replace(src,'       pedido_id,presentacion_id,perfume_id,tipo,ml_por_unidad,cantidad'||E'\n'||
  '     ) VALUES (',
  '       pedido_id,presentacion_id,perfume_id,tipo,ml_por_unidad,cantidad,envases_globales_aplicados'||E'\n'||
  '     ) VALUES (');
 src := replace(src,'       r.ml_por_unidad,r.cantidad_actual'||E'\n'||
  '     ) ON CONFLICT',
  '       r.ml_por_unidad,r.cantidad_actual,'||E'\n'||
  '       CASE WHEN r.tipo=''decant'' THEN r.envases_globales_previos+v_global_delta ELSE 0 END'||E'\n'||
  '     ) ON CONFLICT');
 src := replace(src,'       SET cantidad=excluded.cantidad;',
  '       SET cantidad=excluded.cantidad,envases_globales_aplicados=excluded.envases_globales_aplicados;');
 IF position('v_global_delta integer;' in src)=0
    OR position('envases_globales_aplicados=excluded.envases_globales_aplicados;' in src)=0
    OR position('unidades=unidades-v_delta' in src)>0
 THEN RAISE EXCEPTION 'La función de inventario no coincide con la versión prevista; no aplicar'; END IF;
 EXECUTE src;
END $patch$;
COMMIT;
