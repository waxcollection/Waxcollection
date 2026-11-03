-- 003: Operaciones públicas mínimas, sin exponer tablas privadas ni service_role.
-- Ejecutar después de 001 y 002.
BEGIN;

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
              ELSE floor(COALESCE((SELECT inv.ml_abiertos FROM public.inventario inv WHERE inv.perfume_id=p.id),0)/v.ml)::int END
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
     OR p_telefono IS NULL OR p_telefono !~ '^[+]506[0-9]{8}
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
      ),0)::numeric ELSE floor(COALESCE((
        SELECT inv.ml_abiertos FROM public.inventario inv WHERE inv.perfume_id=p.id
      ),0)/v.ml) END
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

CREATE OR REPLACE FUNCTION public.tienda_seguimiento(p_codigo text,p_ultimos4 text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT jsonb_build_object('numero',p.id,'estado',p.estado,
   'fecha',p.created_at,'nombre',split_part(btrim(p.nombre_completo),' ',1),
   'telefono_ultimos4',right(p.telefono_e164,4))
 FROM public.pedidos p
 WHERE p.codigo_seguimiento=p_codigo
   AND right(p.telefono_e164,4)=p_ultimos4
   AND p_codigo ~ '^[A-F0-9]{24}$'
   AND p_ultimos4 ~ '^[0-9]{4}$'
 LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.tienda_catalogo() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tienda_crear_pedido(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tienda_seguimiento(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tienda_catalogo() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.tienda_crear_pedido(text,text,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.tienda_seguimiento(text,text) TO anon;
COMMIT;
-- IMPORTANTE: pendiente_pago NO reserva existencias; confirmar debe revalidar inventario.
-- Endpoints públicos de crear pedido y seguimiento requieren rate limiting en Worker/WAF.
