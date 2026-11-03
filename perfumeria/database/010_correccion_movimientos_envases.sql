-- Diagnóstico antes de ajustar saldos manualmente.
SELECT ml,unidades FROM public.envases_decants ORDER BY ml;
SELECT ml,delta_unidades,motivo,created_at
FROM public.envases_decants_movimientos ORDER BY id DESC LIMIT 50;
SELECT pedido_id,presentacion_id,tipo,ml_por_unidad,cantidad
FROM public.pedido_stock_aplicado ORDER BY pedido_id DESC LIMIT 50;
