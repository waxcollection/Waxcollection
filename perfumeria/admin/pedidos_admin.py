"""Administrar pedidos por número o código de seguimiento (solo personal autorizado)."""
from decimal import Decimal, InvalidOperation

import streamlit as st

from db import client, call

STATES = {
    "pendiente_pago": "Pendiente de pago",
    "pagado": "Pagado",
    "en_preparacion": "En preparación",
    "en_transito": "En tránsito",
    "entregado": "Entregado",
    "cancelado": "Cancelado",
    "abandonado": "Abandonado",
}
CLOSED = {"cancelado", "abandonado", "entregado"}


def amount(value):
    try:
        return Decimal(str(value or 0))
    except (ValueError, InvalidOperation):
        return Decimal(0)


def show_orders(perfumes, variants):
    st.subheader("🧾 Gestión de pedidos")
    st.caption("Busca por número de orden o código de seguimiento. Todos los cambios se registran en el historial.")

    lookup = st.text_input("Número de pedido o código de seguimiento", placeholder="Ej.: 15 o código de 24 caracteres").strip()
    if not lookup:
        st.info("Introduce el número de orden para consultar o editar un pedido.")
        return

    try:
        query = client().table("pedidos").select("*")
        if lookup.isdigit():
            query = query.eq("id", int(lookup))
        else:
            query = query.eq("codigo_seguimiento", lookup.upper())
        matches = query.limit(1).execute().data or []
        if not matches:
            st.warning("No se encontró ningún pedido con ese número o código.")
            return
        order = matches[0]
        order_id = order["id"]
        details = (
            client().table("pedido_detalles").select("*")
            .eq("pedido_id", order_id).order("id").execute().data or []
        )
        history = (
            client().table("pedido_historial").select("*")
            .eq("pedido_id", order_id).order("id", desc=True).execute().data or []
        )
    except Exception as exc:
        st.error(f"No se pudo consultar el pedido: {exc}")
        return

    a, b, c = st.columns(3)
    a.metric("Pedido", f"#{order_id}")
    b.metric("Total registrado", f"₡{amount(order.get('total')):,.0f}")
    c.metric("Estado", STATES.get(str(order.get("estado")), str(order.get("estado"))))
    st.write(f"**Cliente:** {order.get('nombre_completo') or '—'}")
    st.write(f"**Teléfono:** {order.get('telefono_e164') or '—'}")
    st.write(f"**Código de seguimiento:** `{order.get('codigo_seguimiento') or '—'}`")

    st.markdown("#### Artículos actuales")
    st.dataframe([{
        "Presentación ID": d.get("presentacion_id"),
        "Perfume": d.get("perfume_nombre_snapshot"),
        "Tipo": d.get("presentacion_tipo_snapshot"),
        "Mililitros": d.get("presentacion_ml_snapshot"),
        "Cantidad": d.get("cantidad"),
        "Precio unitario (₡)": float(amount(d.get("precio_unitario"))),
        "Subtotal (₡)": float(amount(d.get("precio_unitario"))*int(d.get("cantidad") or 0)),
    } for d in details], use_container_width=True, hide_index=True)

    active = str(order.get("estado")) not in CLOSED
    perfume_by_id = {p["id"]: p.get("nombre", str(p["id"])) for p in perfumes}
    variants_by_id = {v["id"]: v for v in variants}
    options = {
        f"{perfume_by_id.get(v['perfume_id'], 'Perfume')} · {v['tipo']} {v['ml']} ml · ₡{amount(v.get('precio')):,.0f} (#{v['id']})": v["id"]
        for v in variants if v.get("activo")
    }
    current = {int(d["presentacion_id"]): int(d["cantidad"]) for d in details}
    current_ids = list(current)
    available_labels = {label: vid for label, vid in options.items()}
    # Preservar líneas históricas de variantes desactivadas solo para visualizar;
    # al editar hay que elegir presentaciones activas de nuevo.
    default_labels = [label for label, vid in options.items() if vid in current_ids]
    unknown = [vid for vid in current_ids if vid not in variants_by_id or not variants_by_id[vid].get("activo")]

    if str(order.get("estado")) in {"pagado", "en_preparacion", "en_transito"}:
        st.warning("Si modificas los productos o cantidades de una orden ya cobrada, el nuevo total podría requerir un cobro adicional o una devolución. El sistema no procesa pagos ni reembolsos automáticamente.")

    st.markdown("#### Modificar el pedido")
    if not active:
        st.warning("El pedido está cerrado (cancelado, abandonado o entregado). No se pueden editar sus artículos ni reabrirlo automáticamente.")
    if unknown:
        st.warning("Este pedido tiene presentaciones que ya no están activas. Si editas los artículos, deberás sustituirlas por presentaciones activas.")

    current_state = str(order.get("estado") or "")
    state_options = list(STATES)
    if current_state not in state_options:
        state_options.insert(0, current_state)

    # Fuera del formulario: activar la edición debe recalcular los controles inmediatamente.
    modify_lines = st.checkbox("Editar productos y cantidades", value=False, disabled=not active, key=f"edit_lines_{order_id}")

    with st.form(f"admin_order_form_{order_id}"):
        desired = st.selectbox("Nuevo estado", state_options,
            index=state_options.index(current_state),
            format_func=lambda x: STATES.get(x, x),
            disabled=not active)
        selected_labels = st.multiselect(
            "Artículos del pedido (agrega o quita presentaciones)",
            list(available_labels), default=default_labels,
            disabled=not active or not modify_lines
        )
        new_lines = []
        for label in selected_labels:
            vid = available_labels[label]
            qty = st.number_input(
                f"Cantidad · {label}", min_value=1, max_value=20,
                value=min(20, max(1, current.get(vid, 1))),
                step=1, key=f"order_{order_id}_qty_{vid}",
                disabled=not active or not modify_lines
            )
            new_lines.append({"presentacion_id": vid, "cantidad": int(qty)})
        note = st.text_area("Motivo u observación del cambio", max_chars=500,
            placeholder="Ej.: Cliente solicita agregar un decant de 5 ml.")
        st.caption("Editar artículos recalcula precios y descuentos vigentes. No descuenta inventario; verifica diferencias de cobro antes de guardar.")
        confirm = st.checkbox("Confirmo haber revisado los cambios y su efecto en el cobro")
        # En st.form, la casilla no provoca rerun; validar confirmación al enviar.
        submit = st.form_submit_button("Guardar cambios", disabled=not active)

    if submit:
        if not confirm:
            st.warning("Confirma que revisaste los cambios antes de guardarlos.")
            return
        if not note.strip():
            st.warning("Indica el motivo de la modificación.")
            return
        if modify_lines and not new_lines:
            st.warning("No puedes dejar un pedido sin artículos. Para anularlo, selecciona Cancelado.")
            return
        try:
            result = call("admin_editar_pedido", {
                "p_pedido_id": order_id,
                "p_estado": desired if desired != current_state else None,
                "p_items": new_lines if modify_lines else None,
                "p_nota": note.strip(),
            })
            st.success(f"Pedido #{order_id} actualizado. Total: ₡{amount(result.get('total')):,.0f}")
            st.rerun()
        except Exception as exc:
            st.error(f"No fue posible guardar. Verifica que hayas ejecutado 004_admin_edit_orders.sql en Supabase: {exc}")

    st.markdown("#### Historial de cambios")
    if history:
        st.dataframe([{
            "Fecha": h.get("created_at"),
            "Estado": h.get("estado_nuevo"),
            "Actor": h.get("actor"),
            "Observación": h.get("nota"),
        } for h in history], use_container_width=True, hide_index=True)
    else:
        st.info("Sin movimientos registrados.")
