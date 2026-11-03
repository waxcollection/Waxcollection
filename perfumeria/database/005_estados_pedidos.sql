-- 005: Ampliar los estados admitidos por pedidos_estado_check.
-- Ejecutar en Supabase SQL Editor después de 004_admin_edit_orders.sql.
-- Conserva TODAS las condiciones originales del CHECK y añade los estados
-- utilizados por la gestión administrativa; no altera datos existentes.
BEGIN;
DO $$
DECLARE
  v_expr text;
BEGIN
  SELECT pg_get_expr(c.conbin,c.conrelid)
    INTO v_expr
  FROM pg_constraint c
  WHERE c.conrelid='public.pedidos'::regclass
    AND c.conname='pedidos_estado_check'
    AND c.contype='c';

  IF v_expr IS NULL THEN
    RAISE EXCEPTION 'No se encontró pedidos_estado_check; revisar el esquema antes de modificarlo';
  END IF;

  ALTER TABLE public.pedidos DROP CONSTRAINT pedidos_estado_check;

  EXECUTE format(
    'ALTER TABLE public.pedidos ADD CONSTRAINT pedidos_estado_check CHECK ((%s) OR (estado::text IN (%L,%L,%L,%L,%L,%L,%L)))',
    v_expr,
    'pendiente_pago','pagado','en_preparacion','en_transito',
    'entregado','cancelado','abandonado'
  );
END $$;
COMMIT;

-- Para comprobar el resultado:
-- SELECT pg_get_constraintdef(oid)
-- FROM pg_constraint
-- WHERE conrelid='public.pedidos'::regclass AND conname='pedidos_estado_check';
