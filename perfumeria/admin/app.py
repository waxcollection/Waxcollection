"""Administración local de perfumes. No exponer Streamlit directamente a Internet."""
import hashlib
import hmac
import re
import unicodedata
from uuid import uuid4

import streamlit as st

st.set_page_config(page_title="Administración · Perfumería", page_icon="🧴", layout="wide")


def slugify(value):
    plain = unicodedata.normalize("NFKD", value)
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", plain.lower()).strip("-")


from auth import require_admin, logout  # noqa: E402

require_admin()
from db import client, rows, insert, update, call  # noqa: E402
from image_utils import webp_bytes  # noqa: E402

st.title("🧴 Administración de perfumería")
with st.sidebar:
    st.caption("Panel privado · Supabase")
    section = st.radio("Módulo", ["Dashboard", "Pedidos", "Marcas", "Perfumes", "Presentaciones", "Fotografías", "Inventario"])
    if st.button("Cerrar sesión"):
        logout()
        st.rerun()


def run(action):
    try:
        action()
        st.success("Operación realizada correctamente")
        st.rerun()
    except Exception as exc:
        st.error(f"No se pudo completar la operación: {exc}")


try:
    brands = rows("marcas", "id,nombre,slug,activo")
    perfumes = rows("perfumes", "id,marca_id,nombre,slug,genero,descripcion,familia_olfativa,activo")
    variants = rows("presentaciones", "id,perfume_id,tipo,ml,sku,precio,activo")
except Exception as exc:
    st.error(f"Error conectando con Supabase: {exc}")
    st.stop()

brand_names = {f"{b['nombre']} (#{b['id']})": b["id"] for b in brands}
perfume_names = {f"{p['nombre']} (#{p['id']})": p["id"] for p in perfumes}
variant_names = {
    f"{next((p['nombre'] for p in perfumes if p['id']==v['perfume_id']), 'Perfume')} · {v['tipo']} {v['ml']} ml (#{v['id']})": v["id"]
    for v in variants
}


if section == "Dashboard":
    from dashboard import show_dashboard

    show_dashboard(perfumes, brands, variants)
    st.stop()


if section == "Pedidos":
    from pedidos_admin import show_orders

    show_orders(perfumes, variants)
    st.stop()


if section == "Marcas":
    st.subheader("Marcas")
    st.dataframe(brands, use_container_width=True, hide_index=True)
    with st.form("new_brand"):
        name = st.text_input("Nombre")
        active = st.checkbox("Activa", value=True)
        submitted = st.form_submit_button("Agregar marca")
    if submitted:
        if not name.strip():
            st.warning("Introduce el nombre")
        else:
            run(lambda: insert("marcas", {"nombre": name.strip(), "slug": slugify(name), "activo": active}))
    if brands:
        with st.expander("Editar marca existente"):
            selected = st.selectbox("Marca", list(brand_names))
            entry = next(b for b in brands if b["id"] == brand_names[selected])
            with st.form("edit_brand"):
                new_name = st.text_input("Nombre", entry["nombre"])
                new_active = st.checkbox("Activa", entry["activo"])
                save = st.form_submit_button("Guardar")
            if save and new_name.strip():
                run(lambda: update("marcas", entry["id"], {"nombre": new_name.strip(), "slug": slugify(new_name), "activo": new_active}))

elif section == "Perfumes":
    st.subheader("Perfumes")
    st.dataframe(perfumes, use_container_width=True, hide_index=True)
    if not brands:
        st.info("Primero crea una marca.")
        st.stop()
    mode = st.radio("Operación", ["Crear", "Editar"], horizontal=True)
    chosen = None
    if mode == "Editar" and perfumes:
        label = st.selectbox("Perfume a editar", list(perfume_names))
        chosen = next(p for p in perfumes if p["id"] == perfume_names[label])
    elif mode == "Editar":
        st.info("Todavía no existen perfumes")
        st.stop()
    with st.form("perfume_form"):
        name = st.text_input("Nombre", value=chosen["nombre"] if chosen else "")
        brand_id = st.selectbox(
            "Marca", list(brand_names), index=next((i for i, b in enumerate(brand_names.values()) if chosen and b == chosen["marca_id"]), 0)
        )
        genders = ["hombre", "mujer", "sin_distincion"]
        gender = st.selectbox("Género", genders, index=genders.index(chosen["genero"]) if chosen else 0)
        family = st.text_input("Familia olfativa", chosen["familia_olfativa"] or "" if chosen else "")
        description = st.text_area("Descripción", chosen["descripcion"] or "" if chosen else "")
        active = st.checkbox("Visible en catálogo", value=chosen["activo"] if chosen else True)
        save = st.form_submit_button("Guardar perfume")
    if save:
        if not name.strip() or not slugify(name):
            st.warning("Escribe un nombre válido")
        else:
            values = {
                "nombre": name.strip(), "marca_id": brand_names[brand_id], "genero": gender,
                "familia_olfativa": family.strip(), "descripcion": description.strip(), "activo": active,
                "slug": chosen["slug"] if chosen else slugify(name) + "-" + uuid4().hex[:6],
            }
            run(lambda: update("perfumes", chosen["id"], values) if chosen else insert("perfumes", values))

elif section == "Presentaciones":
    st.subheader("Presentaciones y precios")
    st.dataframe(variants, use_container_width=True, hide_index=True)
    if not perfumes:
        st.info("Primero registra un perfume.")
        st.stop()
    mode = st.radio("Operación", ["Crear", "Editar"], horizontal=True)
    chosen = None
    if mode == "Editar" and variants:
        label = st.selectbox("Presentación", list(variant_names))
        chosen = next(v for v in variants if v["id"] == variant_names[label])
    elif mode == "Editar":
        st.stop()
    with st.form("variant_form"):
        label = st.selectbox("Perfume", list(perfume_names),
            index=next((i for i, pid in enumerate(perfume_names.values()) if chosen and pid == chosen["perfume_id"]), 0))
        kinds = ["botella", "decant"]
        kind = st.selectbox("Tipo", kinds, index=kinds.index(chosen["tipo"]) if chosen else 0)
        ml = st.number_input("Mililitros (decants habituales: 2, 5 y 10)", min_value=0.01, step=1.0, value=float(chosen["ml"]) if chosen else 5.0)
        price = st.number_input("Precio en colones", min_value=0.0, step=100.0, value=float(chosen["precio"]) if chosen else 0.0)
        sku = st.text_input("SKU (opcional)", chosen["sku"] or "" if chosen else "")
        active = st.checkbox("Activa", value=chosen["activo"] if chosen else True)
        save = st.form_submit_button("Guardar presentación")
    if save:
        if ml <= 0:
            st.warning("El tamaño debe ser mayor que 0 ml.")
        else:
            values = {"perfume_id": perfume_names[label], "tipo": kind, "ml": ml,
                "precio": price, "sku": sku.strip() or None, "activo": active}
            run(lambda: update("presentaciones", chosen["id"], values) if chosen else insert("presentaciones", values))

elif section == "Fotografías":
    st.subheader("Imágenes de perfumes")
    if not perfumes:
        st.info("Primero registra un perfume.")
        st.stop()
    label = st.selectbox("Perfume", list(perfume_names))
    perfume_id = perfume_names[label]
    try:
        photos = client().table("perfume_imagenes").select("*").eq("perfume_id", perfume_id).order("orden").execute().data or []
        st.dataframe(photos, use_container_width=True, hide_index=True)
    except Exception as exc:
        st.error(f"No se pudieron cargar las imágenes: {exc}")
        st.stop()
    with st.form("photos_form"):
        image = st.file_uploader("Fotografía JPG, PNG o WebP", type=["jpg", "jpeg", "png", "webp"])
        alt = st.text_input("Texto alternativo", value=label)
        principal = st.checkbox("Imagen principal", value=not any(i["principal"] for i in photos))
        send = st.form_submit_button("Comprimir y subir")
    if send:
        if image is None:
            st.warning("Selecciona una fotografía")
        else:
            def upload():
                bucket = st.secrets.get("STORAGE_BUCKET", "perfumes")
                path = f"productos/{perfume_id}/{uuid4().hex}.webp"
                content = webp_bytes(image)
                client().storage.from_(bucket).upload(path, content, {"content-type": "image/webp", "upsert": "false"})
                try:
                    # El índice único exige desmarcar la imagen anterior antes de crear otra principal.
                    if principal:
                        client().table("perfume_imagenes").update({"principal": False}).eq("perfume_id", perfume_id).eq("principal", True).execute()
                    insert("perfume_imagenes", {
                        "perfume_id": perfume_id, "storage_path": path,
                        "alt_text": alt.strip(), "orden": len(photos), "principal": principal,
                    })
                except Exception:
                    client().storage.from_(bucket).remove([path])
                    raise
            run(upload)
    if photos:
        with st.expander("Cambiar foto principal"):
            labels = {f"Foto #{p['id']} · orden {p['orden']}": p for p in photos}
            selected = st.selectbox("Imagen", list(labels))
            if st.button("Establecer principal"):
                def change_main():
                    client().table("perfume_imagenes").update({"principal": False}).eq("perfume_id", perfume_id).eq("principal", True).execute()
                    client().table("perfume_imagenes").update({"principal": True}).eq("id", labels[selected]["id"]).execute()
                run(change_main)

elif section == "Inventario":
    st.subheader("Inventario")
    st.info("Los ajustes se registran en historial. Nunca modifiques stock manualmente desde el Table Editor.")
    if not perfumes:
        st.stop()
    label = st.selectbox("Perfume", list(perfume_names))
    perfume_id = perfume_names[label]
    opened = client().table("inventario").select("*").eq("perfume_id", perfume_id).execute().data or []
    closed = [v for v in variants if v["perfume_id"] == perfume_id and v["tipo"] == "botella"]
    st.metric("Mililitros abiertos", str(opened[0]["ml_abiertos"] if opened else 0))
    stock_rows = client().table("inventario_botellas").select("*").execute().data or []
    stock_map = {v["presentacion_id"]: v["unidades"] for v in stock_rows}
    st.dataframe([{"presentacion_id": v["id"], "ml": v["ml"], "unidades": stock_map.get(v["id"], 0)} for v in closed],
                 use_container_width=True, hide_index=True)
    st.markdown("#### Decants preparados")
    st.caption("Registra unidades físicamente llenas y listas para vender. Esto no descuenta mililitros del total: el sistema separa los ml envasados de los ml libres y los rebaja al confirmar la venta.")
    decant_variants = [v for v in variants if v["perfume_id"] == perfume_id and v["tipo"] == "decant"]
    if decant_variants:
        try:
            prepared_rows = client().table("inventario_decants").select("presentacion_id,unidades").execute().data or []
            prepared_map = {r["presentacion_id"]: int(r["unidades"]) for r in prepared_rows}
            prepared_ml = sum(prepared_map.get(v["id"], 0) * float(v["ml"]) for v in decant_variants)
            total_ml = float(opened[0]["ml_abiertos"]) if opened else 0.0
            i1, i2 = st.columns(2)
            i1.metric("Mililitros ya envasados", f"{prepared_ml:,.2f} ml")
            i2.metric("Mililitros libres para preparar", f"{total_ml - prepared_ml:,.2f} ml")
            st.dataframe([{"Presentación ID": v["id"], "Tamaño (ml)": v["ml"],
                           "Decants preparados": prepared_map.get(v["id"], 0),
                           "Mililitros envasados": prepared_map.get(v["id"], 0) * float(v["ml"])}
                          for v in decant_variants], use_container_width=True, hide_index=True)
            decant_options = {f"{v['ml']} ml · presentación #{v['id']}": v["id"] for v in decant_variants}
            with st.form("adjust_decants"):
                decant_choice = st.selectbox("Tamaño de decant", list(decant_options))
                decant_delta = st.number_input("Unidades preparadas (+ ingreso / - retiro)",
                                               min_value=-10000, max_value=10000,
                                               value=0, step=1)
                decant_reason = st.text_input("Motivo", value="Preparación de decants")
                save_decants = st.form_submit_button("Registrar decants preparados")
            if save_decants:
                if not decant_delta:
                    st.warning("Ingresa una cantidad distinta de cero.")
                else:
                    run(lambda: call("admin_ajustar_decants", {
                        "p_presentacion_id": decant_options[decant_choice],
                        "p_delta": int(decant_delta),
                        "p_motivo": decant_reason.strip(),
                    }))
        except Exception as exc:
            st.warning(f"No se pudo consultar el inventario de decants. Ejecuta la migración 007 en Supabase: {exc}")
    else:
        st.info("Crea presentaciones de tipo decant (2, 5 o 10 ml) en el módulo Presentaciones.")

    with st.form("adjust_ml"):
        ml_delta = st.number_input("Ajuste de ml abiertos (+ entrada / - merma)", value=0.0, step=1.0)
        reason = st.text_input("Motivo del ajuste", value="Ajuste manual")
        submit = st.form_submit_button("Registrar ajuste de ml")
    if submit:
        if not ml_delta:
            st.warning("Indica una cantidad diferente de cero.")
        else:
            run(lambda: call("admin_ajustar_ml", {"p_perfume_id": perfume_id, "p_delta": ml_delta, "p_motivo": reason}))
    if closed:
        label_v = st.selectbox("Presentación de botella", [str(v["id"]) + " · " + str(v["ml"]) + " ml" for v in closed])
        variant_id = int(label_v.split(" · ")[0])
        with st.form("adjust_bottles"):
            units = st.number_input("Variación de botellas cerradas", min_value=-10000, max_value=10000, value=0, step=1)
            reason_b = st.text_input("Motivo", "Reposición o ajuste")
            save_b = st.form_submit_button("Registrar ajuste de botellas")
        if save_b and units:
            run(lambda: call("admin_ajustar_botellas", {"p_presentacion_id": variant_id, "p_delta": units, "p_motivo": reason_b}))
        if st.button("Abrir una botella y transferir sus ml a decants"):
            run(lambda: call("admin_abrir_botella", {"p_presentacion_id": variant_id}))
    else:
        st.caption("Crea una presentación de tipo botella para administrar existencias.")
