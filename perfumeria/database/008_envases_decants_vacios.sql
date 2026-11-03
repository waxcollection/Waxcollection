-- 008: inventario de envases vacíos por tamaño, independiente del perfume disponible.
-- Ejecutar después de 007 en Supabase SQL Editor.
BEGIN;

CREATE TABLE IF NOT EXISTS public.envases_decants (
  ml numeric(8,2) PRIMARY KEY CHECK (ml > 0 AND ml <= 1000),
  unidades integer NOT NULL DEFAULT 0 CHECK (unidades >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.envases_decants_movimientos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ml numeric(8,2) NOT NULL REFERENCES public.envases_decants(ml),
  delta_unidades integer NOT NULL CHECK (delta_unidades <> 0),
  motivo text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.envases_decants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.envases_decants_movimientos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.envases_decants,public.envases_decants_movimientos
  FROM PUBLIC,anon,authenticated;

GRANT SELECT ON public.envases_decants,public.envases_decants_movimientos
  TO authenticated;

DROP POLICY IF EXISTS admin_ver_envases ON public.envases_decants;
CREATE POLICY admin_ver_envases ON public.envases_decants
  FOR SELECT TO authenticated USING ((SELECT public.es_admin()));

DROP POLICY IF EXISTS admin_ver_movimientos_envases ON public.envases_decants_movimientos;
CREATE POLICY admin_ver_movimientos_envases ON public.envases_decants_movimientos
  FOR SELECT TO authenticated USING ((SELECT public.es_admin()));

CREATE OR REPLACE FUNCTION public.admin_ajustar_envases_decants(
  p_ml numeric,p_delta integer,p_motivo text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_nuevas integer;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT public.es_admin()) THEN
    RAISE EXCEPTION 'Acceso administrativo requerido';
  END IF;
  IF p_ml IS NULL OR p_ml<=0 OR p_ml>1000
     OR p_delta IS NULL OR p_delta=0 OR abs(p_delta)>100000
     OR nullif(btrim(coalesce(p_motivo,'')),'') IS NULL
     OR length(p_motivo)>500 THEN
    RAISE EXCEPTION 'Tamaño, cantidad o motivo inválido';
  END IF;

  INSERT INTO public.envases_decants(ml,unidades)
    VALUES(p_ml,0) ON CONFLICT(ml) DO NOTHING;

  UPDATE public.envases_decants
  SET unidades=unidades+p_delta,updated_at=now()
  WHERE ml=p_ml AND unidades+p_delta>=0
  RETURNING unidades INTO v_nuevas;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay suficientes envases vacíos para descontar';
  END IF;

  INSERT INTO public.envases_decants_movimientos(ml,delta_unidades,motivo)
  VALUES(p_ml,p_delta,btrim(p_motivo));

  RETURN jsonb_build_object('ml',p_ml,'envases_vacios',v_nuevas);
END $$;

REVOKE ALL ON FUNCTION public.admin_ajustar_envases_decants(numeric,integer,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ajustar_envases_decants(numeric,integer,text)
  TO authenticated;

COMMIT;

-- Nota: Los envases vacíos no son decants preparados.
-- No se publican como disponibilidad vendible; no están limitados por los ml.
-- Al llenar decants, se debe registrar la salida de envases vacíos y entrada
-- de preparados mediante una operación específica para mantener conciliación.
