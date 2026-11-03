-- 004: Edición transaccional de pedidos desde el administrador Streamlit.
-- Ejecutar en Supabase SQL Editor después de 003.
-- No reserva ni descuenta stock: la confirmación/despacho requieren control de inventario aparte.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_editar_pedido(
    p_pedido_id bigint,
    p_estado text DEFAULT NULL,
    p_items jsonb DEFAULT NULL,
    p_nota text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_order public.pedidos%ROWTYPE;
  v_state text;
  v_total numeric(12,2) := 0;
  v_item jsonb;
  v_variant bigint;
  v_qty integer;
  v_perfume bigint;
  v_name text;
  v_kind text;
  v_ml numeric;
  v_price numeric;
  v_discount numeric;
  v_available numeric;
  v_seen bigint[] := ARRAY[]::bigint[];
  v_count integer := 0;
  v_new jsonb := '[]'::jsonb;
  v_changed_items boolean := false;
  v_changed_state boolean := false;
BEGIN
  -- SECURITY DEFINER siempre comprueba quién invoca la función.
  IF auth.uid() IS NULL OR NOT (SELECT public.es_admin()) THEN
    RAISE EXCEPTION 'Acceso administrativo requerido';
  END IF;
  IF p_pedido_id IS NULL OR p_pedido_id < 1 THEN
    RAISE EXCEPTION 'Número de pedido inválido';
  END IF;
  IF length(coalesce(p_nota,'')) > 500 THEN
    RAISE EXCEPTION 'La observación no puede superar 500 caracteres';
  END IF;

  SELECT * INTO v_order FROM public.pedidos
  WHERE id = p_pedido_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado';
  END IF;
  v_state := v_order.estado::text;

  IF p_estado IS NOT NULL THEN
    IF p_estado NOT IN (
      'pendiente_pago','pagado','en_preparacion','en_transito',
      'entregado','cancelado','abandonado'
    ) THEN
      RAISE EXCEPTION 'Estado no permitido: %', p_estado;
    END IF;
    -- No convertir órdenes cerradas en órdenes activas por accidente.
    IF v_state IN ('cancelado','abandonado','entregado')
       AND p_estado IS DISTINCT FROM v_state THEN
      RAISE EXCEPTION 'No se puede reabrir automáticamente un pedido cerrado';
    END IF;
    v_changed_state := p_estado IS DISTINCT FROM v_state;
  END IF;

  IF p_items IS NOT NULL THEN
    IF jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 20 THEN
      RAISE EXCEPTION 'Se requiere entre 1 y 20 artículos; para anular use estado cancelado';
    END IF;
    IF v_state IN ('cancelado','abandonado','entregado') THEN
      RAISE EXCEPTION 'Los artículos de un pedido cerrado no se pueden editar';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
      IF jsonb_typeof(v_item) <> 'object'
        OR coalesce(v_item->>'presentacion_id','') !~ '^[0-9]{1,12}$'
        OR coalesce(v_item->>'cantidad','') !~ '^[0-9]{1,3}$'
      THEN
        RAISE EXCEPTION 'Artículo inválido';
      END IF;
      v_variant := (v_item->>'presentacion_id')::bigint;
      v_qty := (v_item->>'cantidad')::integer;
      IF v_qty < 1 OR v_qty > 20 OR v_variant = ANY(v_seen) THEN
        RAISE EXCEPTION 'Cantidad inválida o presentación repetida';
      END IF;
      v_seen := array_append(v_seen, v_variant);
      v_count := v_count + 1;

      SELECT p.id,p.nombre,v.tipo,v.ml,v.precio,
        coalesce((SELECT max(d.porcentaje) FROM public.descuentos d
          WHERE d.activo
            AND (d.inicia_at IS NULL OR d.inicia_at <= now())
            AND (d.termina_at IS NULL OR d.termina_at > now())
            AND (d.presentacion_id=v.id OR d.perfume_id=p.id)),0),
        CASE WHEN v.tipo='botella'
          THEN coalesce((SELECT ib.unidades FROM public.inventario_botellas ib
                         WHERE ib.presentacion_id=v.id),0)::numeric
          ELSE floor(coalesce((SELECT inv.ml_abiertos FROM public.inventario inv
                               WHERE inv.perfume_id=p.id),0)/nullif(v.ml,0))
        END
      INTO v_perfume,v_name,v_kind,v_ml,v_price,v_discount,v_available
      FROM public.presentaciones v
      JOIN public.perfumes p ON p.id=v.perfume_id
      JOIN public.marcas m ON m.id=p.marca_id
      WHERE v.id=v_variant AND v.activo AND p.activo AND m.activo;

      IF NOT FOUND OR v_available IS NULL OR v_available < v_qty THEN
        RAISE EXCEPTION 'Presentación no disponible (id %)', v_variant;
      END IF;
      IF v_discount < 0 OR v_discount > 100 THEN
        RAISE EXCEPTION 'Descuento fuera de rango';
      END IF;
      v_price := round(v_price*(1-v_discount/100),2);
      v_total := v_total+v_price*v_qty;
      v_new := v_new || jsonb_build_array(jsonb_build_object(
        'id',v_variant,'cantidad',v_qty,'nombre',v_name,
        'tipo',v_kind,'ml',v_ml,'precio',v_price));
    END LOOP;

    -- Decants de 2 ml y 5 ml comparten inventario: validar el conjunto.
    IF EXISTS (
      SELECT 1 FROM (
        SELECT p.perfume_id,sum((a->>'cantidad')::numeric*p.ml) AS solicitado
        FROM jsonb_array_elements(v_new) a
        JOIN public.presentaciones p ON p.id=(a->>'id')::bigint
        WHERE p.tipo='decant'
        GROUP BY p.perfume_id
      ) x
      LEFT JOIN public.inventario inv ON inv.perfume_id=x.perfume_id
      WHERE x.solicitado > coalesce(inv.ml_abiertos,0)
    ) THEN
      RAISE EXCEPTION 'Mililitros insuficientes para la combinación de decants';
    END IF;

    -- Se registra un cambio explícito, aunque el total pueda coincidir.
    DELETE FROM public.pedido_detalles WHERE pedido_id=p_pedido_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_new) LOOP
      INSERT INTO public.pedido_detalles(
        pedido_id,presentacion_id,perfume_nombre_snapshot,presentacion_tipo_snapshot,
        presentacion_ml_snapshot,cantidad,precio_unitario)
      VALUES (
        p_pedido_id,(v_item->>'id')::bigint,v_item->>'nombre',
        v_item->>'tipo',(v_item->>'ml')::numeric,
        (v_item->>'cantidad')::integer,(v_item->>'precio')::numeric
      );
    END LOOP;
    UPDATE public.pedidos SET total=v_total WHERE id=p_pedido_id;
    v_changed_items := true;
  END IF;

  IF v_changed_state THEN
    UPDATE public.pedidos SET estado=p_estado WHERE id=p_pedido_id;
  END IF;

  IF v_changed_state OR v_changed_items OR nullif(btrim(coalesce(p_nota,'')),'') IS NOT NULL THEN
    INSERT INTO public.pedido_historial(pedido_id,estado_nuevo,actor,nota)
    VALUES (
      p_pedido_id,
      coalesce(p_estado,v_state),
      'admin',
      left(
        concat_ws(' | ',
          CASE WHEN v_changed_state THEN 'Estado: '||v_state||' → '||p_estado END,
          CASE WHEN v_changed_items THEN 'Artículos editados; total anterior: '||v_order.total::text||'; nuevo: '||v_total::text END,
          nullif(btrim(p_nota),'')
        ),500
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'id',p_pedido_id,'estado',coalesce(p_estado,v_state),
    'total',CASE WHEN v_changed_items THEN v_total ELSE v_order.total END,
    'articulos_actualizados',v_changed_items,
    'estado_actualizado',v_changed_state
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_editar_pedido(bigint,text,jsonb,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_editar_pedido(bigint,text,jsonb,text)
  TO authenticated;
COMMIT;
