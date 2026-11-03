"""Inventario GLOBAL de frascos de decant vacíos (2/5/10 ml), independiente del perfume."""
import streamlit as st
from db import client, call

SIZES = (2, 5, 10)


def show_empty_vials():
    st.subheader("🧪 Inventario global de decants")
    st.info("Una sola cantidad de envases vacíos por tamaño para TODOS los perfumes. No necesitas registrar stock de decants por perfume. Los ml se comprueban en cada perfume al comprar y se rebajan junto con el envase cuando confirmas la venta.")

    try:
        stock = client().table("envases_decants").select("ml,unidades").order("ml").execute().data or []
    except Exception as exc:
        st.error(f"No se pudo consultar el inventario global. Ejecuta primero la migración 009: {exc}")
        return

    by_size = {int(float(r["ml"])): int(r["unidades"]) for r in stock if float(r["ml"]) in SIZES}
    st.metric("Frascos disponibles (todos los tamaños)", f"{sum(by_size.values()):,}")
    st.dataframe(
        [{"Tamaño (ml)": size, "Frascos disponibles": by_size.get(size, 0)} for size in SIZES],
        use_container_width=True, hide_index=True,
    )

    with st.form("ajustar_decants_globales"):
        size = st.selectbox("Tamaño de decant", SIZES, format_func=lambda n: f"{n} ml")
        delta = st.number_input("Variación de envases (+ entrada / - retiro)",
                                min_value=-100000, max_value=100000, value=0, step=1)
        reason = st.text_input("Motivo", value="Compra de frascos para decants")
        submitted = st.form_submit_button("Registrar movimiento")

    if submitted:
        if not delta:
            st.warning("Indica una cantidad distinta de cero.")
            return
        if not reason.strip():
            st.warning("Indica el motivo del movimiento.")
            return
        try:
            call("admin_ajustar_envases_decants", {
                "p_ml": size, "p_delta": int(delta), "p_motivo": reason.strip(),
            })
            st.success("Inventario global de decants actualizado.")
            st.rerun()
        except Exception as exc:
            st.error(f"No fue posible registrar el movimiento: {exc}")

    st.caption("El sistema solo ofrece tamaños con envases disponibles. En las compras también verifica que haya ml suficientes del perfume elegido. Los envases se descuentan al confirmar el pedido, no mientras está pendiente.")
