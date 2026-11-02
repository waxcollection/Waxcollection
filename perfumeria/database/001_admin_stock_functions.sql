-- Ejecutar una sola vez en Supabase SQL Editor DESPUÉS del esquema inicial.
-- Servicio administrativo: ejecución solo mediante service_role. Nunca exponer la clave.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_ajustar_ml(p_perfume_id bigint, p_delta numeric, p_motivo text)
RETURNS void LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_id bigint;
BEGIN
 IF p_delta IS NULL OR p_delta = 0 OR p_motivo IS NULL OR btrim(p_motivo) = '' THEN
   RAISE EXCEPTION 'Ajuste inválido o sin motivo';
 END IF;
 INSERT INTO public.inventario(perfume_id,ml_abiertos)
 VALUES(p_perfume_id,0) ON CONFLICT (perfume_id) DO NOTHING;
 UPDATE public.inventario SET ml_abiertos=ml_abiertos+p_delta,updated_at=now()
 WHERE perfume_id=p_perfume_id AND ml_abiertos+p_delta>=0 RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION 'Mililitros insuficientes'; END IF;
 INSERT INTO public.inventario_movimientos(inventario_id,tipo,delta_ml,observacion)
 VALUES(v_id,'ajuste',p_delta,p_motivo);
END $$;

CREATE OR REPLACE FUNCTION public.admin_ajustar_botellas(p_presentacion_id bigint, p_delta integer, p_motivo text)
RETURNS void LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_id bigint;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.presentaciones WHERE id=p_presentacion_id AND tipo='botella') THEN
   RAISE EXCEPTION 'La presentación no es una botella';
 END IF;
 IF p_delta IS NULL OR p_delta = 0 OR p_motivo IS NULL OR btrim(p_motivo) = '' THEN
   RAISE EXCEPTION 'Ajuste inválido o sin motivo';
 END IF;
 INSERT INTO public.inventario_botellas(presentacion_id,unidades)
 VALUES(p_presentacion_id,0) ON CONFLICT(presentacion_id) DO NOTHING;
 UPDATE public.inventario_botellas SET unidades=unidades+p_delta,updated_at=now()
 WHERE presentacion_id=p_presentacion_id AND unidades+p_delta>=0 RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION 'Botellas insuficientes'; END IF;
 INSERT INTO public.inventario_movimientos(inventario_botellas_id,tipo,delta_botellas,observacion)
 VALUES(v_id,CASE WHEN p_delta>0 THEN 'entrada_botellas' ELSE 'ajuste' END,p_delta,p_motivo);
END $$;

CREATE OR REPLACE FUNCTION public.admin_abrir_botella(p_presentacion_id bigint)
RETURNS void LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_perfume bigint; v_ml numeric; v_bot_id bigint; v_inv_id bigint;
BEGIN
 SELECT perfume_id,ml INTO v_perfume,v_ml FROM public.presentaciones
 WHERE id=p_presentacion_id AND tipo='botella';
 IF v_perfume IS NULL THEN RAISE EXCEPTION 'Presentación de botella inexistente'; END IF;
 UPDATE public.inventario_botellas SET unidades=unidades-1,updated_at=now()
 WHERE presentacion_id=p_presentacion_id AND unidades>=1 RETURNING id INTO v_bot_id;
 IF v_bot_id IS NULL THEN RAISE EXCEPTION 'No hay botellas cerradas'; END IF;
 INSERT INTO public.inventario(perfume_id,ml_abiertos)
 VALUES(v_perfume,0) ON CONFLICT(perfume_id) DO NOTHING;
 UPDATE public.inventario SET ml_abiertos=ml_abiertos+v_ml,updated_at=now()
 WHERE perfume_id=v_perfume RETURNING id INTO v_inv_id;
 INSERT INTO public.inventario_movimientos(inventario_id,inventario_botellas_id,tipo,delta_botellas,delta_ml,observacion)
 VALUES(v_inv_id,v_bot_id,'apertura_botella',-1,v_ml,'Apertura manual desde administración');
END $$;

REVOKE ALL ON FUNCTION public.admin_ajustar_ml(bigint,numeric,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.admin_ajustar_botellas(bigint,integer,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.admin_abrir_botella(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_ml(bigint,numeric,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_botellas(bigint,integer,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_abrir_botella(bigint) TO service_role;
COMMIT;
