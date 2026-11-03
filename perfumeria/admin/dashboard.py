"""Panel de lectura para inventario y órdenes, usando la sesión autenticada y RLS."""
from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation

import streamlit as st

from db import client

PAGE_SIZE = 1000
# Solo estos estados demuestran cobro; estar en tránsito por sí solo NO prueba pago.
PAID_STATES = {"pagado", "pagada", "pago_confirmado", "pago_recibido"}
CLOSED_WITHOUT_SALE = {"cancelado", "cancelada", "abandonado", "abandonada", "reembolsado", "reembolsada", "devuelto", "devuelta"}


def fetch_all(table, columns="*", order="id"):
    """Recorre páginas para no truncar los agregados en el límite REST de Supabase."""
    items = []
    start = 0
    while True:
        query = client().table(table).select(columns).range(start, start + PAGE_SIZE - 1)
        if order:
            query = query.order(order)
        page = query.execute().data or []
        items.extend(page)
        if len(page) < PAGE_SIZE:
            return items
        start += PAGE_SIZE


def number(value):
    try:
        return Decimal(str(value or 0))
    except (ValueError, InvalidOperation):
        return Decimal(0)


def colones(value):
    return "₡" + f"{number(value):,.0f}"


def normal_status(value):
    return str(value or "").strip().lower()


def show_dashboard(perfumes, brands, variants):
    st.subheader("📊 Dashboard")
    st.caption("Datos en tiempo real de Supabase · Consulta de solo lectura")

    if st.button("🔄 Actualizar datos", key="refresh_dashboard"):
        st.rerun()

    # Independientes: un error de permisos o una tabla faltante no debe ocultar todo el dashboard.
    try:
        opened = fetch_all("inventario", "perfume_id,ml_abiertos")
        bottles = fetch_all("inventario_botellas", "presentacion_id,unidades")
        by_ml = {r["perfume_id"]: number(r.get("ml_abiertos")) for r in opened}
        prepared_rows = fetch_all("inventario_decants", "presentacion_id,unidades")
        prepared_map = {r["presentacion_id"]: int(r.get("unidades") or 0) for r in prepared_rows}
        by_bottles = {r["presentacion_id"]: int(r.get("unidades") or 0) for r in bottles}
        perfumes_by_id = {p["id"]: p for p in perfumes}
        brands_by_id = {b["id"]: b.get("nombre", "") for b in brands}

        inventory = []
        bottle_total = 0
        for v in variants:
            p = perfumes_by_id.get(v["perfume_id"], {})
            stock_ml = by_ml.get(v["perfume_id"], Decimal(0))
            if v["tipo"] == "botella":
                available = by_bottles.get(v["id"], 0)
                bottle_total += available
                unit = "botellas"
            elif v["tipo"] == "decant":
                available = prepared_map.get(v["id"], 0)
                unit = "decants preparados"
            else:
                available = 0
                unit = "unidades"
            inventory.append({
                "Marca": brands_by_id.get(p.get("marca_id"), "—"),
                "Perfume": p.get("nombre", f"ID {v['perfume_id']}"),
                "Presentación ID": v["id"],
                "Tipo": v["tipo"],
                "Tamaño (ml)": float(number(v.get("ml"))),
                "Precio (₡)": float(number(v.get("precio"))),
                "Disponible": available,
                "Unidad": unit,
                "Activo": bool(v.get("activo")),
            })

        unique_ml = sum(by_ml.values(), Decimal(0))
        packed_by_perfume = defaultdict(Decimal)
        decants_prepared_total = 0
        for v in variants:
            if v["tipo"] == "decant":
                units = prepared_map.get(v["id"], 0)
                decants_prepared_total += units
                packed_by_perfume[v["perfume_id"]] += number(v.get("ml")) * units
        total_packed_ml = sum(packed_by_perfume.values(), Decimal(0))
        free_ml = unique_ml - total_packed_ml
        a, b, c, d = st.columns(4)
        a.metric("Botellas cerradas", f"{bottle_total:,}")
        b.metric("Decants listos", f"{decants_prepared_total:,}")
        c.metric("Mililitros totales", f"{unique_ml:,.2f}")
        d.metric("Mililitros libres", f"{free_ml:,.2f}")
        st.caption(f"Mililitros envasados en decants: {total_packed_ml:,.2f} ml. Los ml totales incluyen los decants preparados; no deben sumarse de nuevo.")
        if free_ml < 0:
            st.error("Los decants preparados superan los ml declarados. Revisa los movimientos de inventario.")
        st.markdown("#### Decants listos y capacidad de preparación")
        decant_table = []
        for v in variants:
            if v["tipo"] != "decant":
                continue
            p = perfumes_by_id.get(v["perfume_id"], {})
            free_for_perfume = by_ml.get(v["perfume_id"], Decimal(0)) - packed_by_perfume[v["perfume_id"]]
            ml = number(v.get("ml"))
            decant_table.append({
                "Marca": brands_by_id.get(p.get("marca_id"), "—"),
                "Perfume": p.get("nombre", f"ID {v['perfume_id']}"),
                "Presentación ID": v["id"],
                "Tamaño (ml)": float(ml),
                "Preparados para venta": prepared_map.get(v["id"], 0),
                "Posibles adicionales": max(0, int(free_for_perfume // ml)) if ml > 0 else 0,
                "Ml libres del perfume": float(free_for_perfume),
            })
        if decant_table:
            st.dataframe(decant_table, use_container_width=True, hide_index=True)
            st.caption("Los posibles adicionales de cada tamaño son alternativas sobre el mismo saldo libre; no se deben sumar entre tamaños.")
        else:
            st.info("Aún no hay presentaciones de decants.")

        st.markdown("#### Existencias por presentación")
        if inventory:
            brand_options = sorted({r["Marca"] for r in inventory})
            selected_brands = st.multiselect("Filtrar marcas", brand_options, key="dashboard_brands")
            selected_types = st.multiselect("Filtrar tipo", sorted({r["Tipo"] for r in inventory}), key="dashboard_types")
            visible_inventory = [
                r for r in inventory
                if (not selected_brands or r["Marca"] in selected_brands)
                and (not selected_types or r["Tipo"] in selected_types)
            ]
            st.dataframe(visible_inventory, use_container_width=True, hide_index=True)
            st.download_button("Descargar inventario CSV", data=to_csv(visible_inventory),
                               file_name="inventario_perfumeria.csv", mime="text/csv",
                               disabled=not visible_inventory)
        else:
            st.info("No hay presentaciones registradas.")
    except Exception as exc:
        st.error(f"No se pudo consultar el inventario: {exc}")

    st.divider()
    st.markdown("#### Órdenes y ventas")
    try:
        orders = fetch_all("pedidos", "*")
        # El historial nos permite identificar pagos aunque el pedido después avance a tránsito.
        history = fetch_all("pedido_historial", "pedido_id,estado_nuevo")
        histories = defaultdict(set)
        for h in history:
            histories[h.get("pedido_id")].add(normal_status(h.get("estado_nuevo")))

        states = sorted({str(o.get("estado")) for o in orders if o.get("estado") is not None})
        counts = Counter(str(o.get("estado")) for o in orders)
        a, b, c, d = st.columns(4)
        a.metric("Pedidos registrados", f"{len(orders):,}")
        paid_orders = [
            o for o in orders
            if normal_status(o.get("estado")) not in CLOSED_WITHOUT_SALE
            and (
                normal_status(o.get("estado")) in PAID_STATES
                or bool(histories.get(o.get("id"), set()) & PAID_STATES)
            )
        ]
        paid_total = sum((number(o.get("total")) for o in paid_orders), Decimal(0))
        transit_orders = [o for o in orders if normal_status(o.get("estado")) in {"en_transito", "en_tránsito", "transito", "tránsito"}]
        transit_total = sum((number(o.get("total")) for o in transit_orders), Decimal(0))
        b.metric("Ventas con pago registrado", colones(paid_total))
        c.metric("Pedidos en tránsito", len(transit_orders))
        d.metric("Valor de pedidos en tránsito", colones(transit_total))
        st.caption("El monto pagado exige un estado de pago explícito, actual o histórico; no suma pendientes ni presume que tránsito significa pago. El valor en tránsito es informativo y puede estar incluido en las ventas pagadas.")

        if orders:
            st.markdown("**Pedidos por estado actual**")
            st.dataframe([
                {"Estado": state, "Pedidos": counts[state],
                 "Monto total (₡)": float(sum((number(o.get("total")) for o in orders if str(o.get("estado")) == state), Decimal(0)))}
                for state in states
            ], use_container_width=True, hide_index=True)

            # El selector se crea SOLO con estados que existen en la tabla.
            selected_states = st.multiselect("Filtrar pedidos por estado", states, key="dashboard_order_states")
            visible_orders = [o for o in orders if not selected_states or str(o.get("estado")) in selected_states]
            st.caption(f"Mostrando {len(visible_orders):,} de {len(orders):,} órdenes.")
            table_orders = [{
                "Pedido ID": o.get("id"),
                "Fecha": o.get("created_at"),
                "Cliente": o.get("nombre_completo"),
                "Teléfono": o.get("telefono_e164"),
                "Estado": o.get("estado"),
                "Total (₡)": float(number(o.get("total"))),
                "Pago registrado": "Sí" if o in paid_orders else "No",
            } for o in visible_orders]
            st.dataframe(table_orders, use_container_width=True, hide_index=True)
            st.download_button("Descargar órdenes filtradas CSV", data=to_csv(table_orders),
                               file_name="ordenes_perfumeria.csv", mime="text/csv",
                               disabled=not table_orders)
            st.caption("El dashboard no modifica estados de pedidos ni descuenta existencias.")
        else:
            st.info("Todavía no hay órdenes. Los filtros de estado aparecerán cuando existan pedidos.")
    except Exception as exc:
        st.error(f"No se pudieron consultar las órdenes o su historial: {exc}")


def to_csv(records):
    import csv
    import io

    if not records:
        return ""
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=list(records[0].keys()), extrasaction="ignore")
    writer.writeheader()
    writer.writerows(records)
    return "\ufeff" + output.getvalue()
