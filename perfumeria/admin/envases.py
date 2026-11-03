"""Inventario de envases de decant vacíos, independiente del saldo de perfume."""
from decimal import Decimal

import streamlit as st
from db import client, call


def show_empty_vials():
    st.subheader("🧪 Envases de decants")
    st.info("Aquí registras envases VACÍOS de 2, 5, 10 ml u otros tamaños. Puedes comprar y almacenar cualquier cantidad sin tener perfume disponible. Estos envases NO cuentan como decants llenos listos para vender.")
    try:
        stock = client().table("envases_decants").select("ml,unidades").order("ml").execute().data or []
    except Exception as exc:
        st.error(f"No se pudo consultar envases. Ejecuta primero la migración 008: {exc}")
        return

    total = sum(int(r.get("unidades") or 0) for r in stock)
    st.metric("Total de envases vacíos", f"{total:,}")
    if stock:
        st.dataframe([
            {"Tamaño (ml)": float(r["ml"]), "Envases vacíos": int(r["unidades"])}
            for r in stock
        ], use_container_width=True, hide_index=True)
    else:
        st.caption("Aún no has registrado envases vacíos.")

    known_sizes = sorted(set([Decimal("2"), Decimal("5"), Decimal("10")] +
                             [Decimal(str(r["ml"])) for r in stock]))
    with st.form("ajustar_envases_vacios"):
        choice = st.selectbox("Tamaño habitual", ["Personalizado"] +
                              [f"{s:g} ml" for s in known_sizes])
        custom_ml = st.number_input("Tamaño personalizado (ml), solo si seleccionaste Personalizado",
                                    min_value=0.01, max_value=1000.0, value=10.0,
                                    step=1.0)
        delta = st.number_input("Variación de envases vacíos (+ compra / - salida)",
                                min_value=-100000, max_value=100000, value=0, step=1)
        reason = st.text_input("Motivo", value="Compra de envases vacíos")
        submitted = st.form_submit_button("Registrar movimiento")

    if submitted:
        if not delta:
            st.warning("Indica una cantidad distinta de cero.")
            return
        try:
            size = Decimal(str(custom_ml)) if choice == "Personalizado" else Decimal(choice.replace(" ml", ""))
            call("admin_ajustar_envases_decants", {
                "p_ml": float(size), "p_delta": int(delta),
                "p_motivo": reason.strip(),
            })
            st.success("Inventario de envases actualizado.")
            st.rerun()
        except Exception as exc:
            st.error(f"No fue posible registrar los envases: {exc}")

    st.caption("Por ahora, llenar un decant requiere dos movimientos explícitos: retirar un envase vacío aquí y registrar el decant lleno en Inventario. No se realiza una transferencia automática entre ambos.")
