import io
import uuid

import streamlit as st
from PIL import Image, ImageOps
from supabase import create_client


# ============================================================
# CONFIGURACIÓN
# ============================================================

st.set_page_config(
    page_title="Administración del catálogo",
    page_icon="🛍️",
    layout="wide",
)


# ============================================================
# SUPABASE
# ============================================================

@st.cache_resource
def obtener_supabase():
    return create_client(
        st.secrets["SUPABASE_URL"],
        st.secrets["SUPABASE_SERVICE_ROLE_KEY"],
    )


supabase = obtener_supabase()


# ============================================================
# FUNCIONES GENERALES
# ============================================================

def obtener_categorias():
    respuesta = (
        supabase
        .table("categorias")
        .select("*")
        .order("orden")
        .execute()
    )

    return respuesta.data or []


def obtener_productos(
    incluir_inactivos=True
):
    query = (
        supabase
        .table("productos")
        .select(
            """
            id,
            codigo,
            nombre,
            slug,
            descripcion,
            precio,
            categoria_id,
            activo,
            destacado,
            orden,
            fecha_creacion,
            fecha_actualizacion,
            categorias (
                id,
                nombre
            )
            """
        )
        .order("orden")
    )

    if not incluir_inactivos:
        query = query.eq("activo", True)

    respuesta = query.execute()

    return respuesta.data or []


def obtener_producto(producto_id):
    respuesta = (
        supabase
        .table("productos")
        .select("*")
        .eq("id", producto_id)
        .single()
        .execute()
    )

    return respuesta.data


def obtener_imagenes(producto_id):
    respuesta = (
        supabase
        .table("imagenes_producto")
        .select("*")
        .eq("producto_id", producto_id)
        .order("principal", desc=True)
        .order("orden")
        .execute()
    )

    return respuesta.data or []


def generar_slug(texto):
    """
    Genera un slug sencillo.
    """
    import re
    import unicodedata

    texto = unicodedata.normalize(
        "NFKD",
        texto
    ).encode(
        "ascii",
        "ignore"
    ).decode()

    texto = texto.lower()

    texto = re.sub(
        r"[^a-z0-9]+",
        "-",
        texto
    )

    texto = texto.strip("-")

    return texto


# ============================================================
# IMÁGENES
# ============================================================

def optimizar_imagen(
    archivo,
    max_ancho=800,
    max_kb=150
):
    """
    Convierte a WebP.
    Mantiene proporción.
    Máximo 800 px de ancho.
    Intenta mantener <= 150 KB.
    """

    imagen = Image.open(archivo)

    # Corregir orientación EXIF
    imagen = ImageOps.exif_transpose(imagen)

    # Convertir transparencia a fondo blanco
    if imagen.mode in ("RGBA", "LA"):

        fondo = Image.new(
            "RGB",
            imagen.size,
            "WHITE"
        )

        fondo.paste(
            imagen,
            mask=imagen.getchannel("A")
        )

        imagen = fondo

    elif imagen.mode != "RGB":

        imagen = imagen.convert("RGB")

    # --------------------------------------------------------
    # REDIMENSIONAR
    # --------------------------------------------------------

    if imagen.width > max_ancho:

        nueva_altura = int(
            imagen.height
            * max_ancho
            / imagen.width
        )

        imagen = imagen.resize(
            (
                max_ancho,
                nueva_altura
            ),
            Image.Resampling.LANCZOS
        )

    # --------------------------------------------------------
    # COMPRESIÓN
    # --------------------------------------------------------

    calidad = 85

    while calidad >= 35:

        buffer = io.BytesIO()

        imagen.save(
            buffer,
            format="WEBP",
            quality=calidad,
            method=6
        )

        tamaño_kb = (
            len(buffer.getvalue())
            / 1024
        )

        if tamaño_kb <= max_kb:
            break

        calidad -= 5

    return (
        buffer.getvalue(),
        imagen.size,
        calidad,
        tamaño_kb
    )


def eliminar_archivo_storage(ruta):

    try:

        (
            supabase
            .storage
            .from_("catalogo")
            .remove([ruta])
        )

        return True

    except Exception as e:

        st.error(
            f"Error eliminando archivo: {e}"
        )

        return False


# ============================================================
# PRODUCTOS
# ============================================================

def crear_producto(datos):

    respuesta = (
        supabase
        .table("productos")
        .insert(datos)
        .execute()
    )

    return respuesta.data


def actualizar_producto(
    producto_id,
    datos
):

    respuesta = (
        supabase
        .table("productos")
        .update(datos)
        .eq("id", producto_id)
        .execute()
    )

    return respuesta.data


def cambiar_estado_producto(
    producto_id,
    activo
):

    (
        supabase
        .table("productos")
        .update({
            "activo": activo
        })
        .eq("id", producto_id)
        .execute()
    )


# ============================================================
# CATEGORÍAS
# ============================================================

def crear_categoria(
    nombre,
    slug,
    orden
):

    respuesta = (
        supabase
        .table("categorias")
        .insert({
            "nombre": nombre,
            "slug": slug,
            "orden": orden,
            "activo": True,
        })
        .execute()
    )

    return respuesta.data


def actualizar_categoria(
    categoria_id,
    datos
):

    respuesta = (
        supabase
        .table("categorias")
        .update(datos)
        .eq("id", categoria_id)
        .execute()
    )

    return respuesta.data


# ============================================================
# SUBIR IMAGEN
# ============================================================

def subir_imagen(
    producto,
    archivo,
    principal=False,
    orden=0,
    alt_text=""
):

    imagen_webp, dimensiones, calidad, tamaño_kb = (
        optimizar_imagen(archivo)
    )

    nombre_archivo = (
        f"{uuid.uuid4().hex}.webp"
    )

    ruta = (
        f"productos/"
        f"{producto['codigo']}/"
        f"{nombre_archivo}"
    )

    # --------------------------------------------------------
    # STORAGE
    # --------------------------------------------------------

    (
        supabase
        .storage
        .from_("catalogo")
        .upload(
            ruta,
            imagen_webp,
            {
                "content-type": "image/webp",
                "cache-control": "31536000",
                "upsert": "false",
            }
        )
    )

    # --------------------------------------------------------
    # SI ES PRINCIPAL, quitar principal de las demás
    # --------------------------------------------------------

    if principal:

        (
            supabase
            .table("imagenes_producto")
            .update({
                "principal": False
            })
            .eq(
                "producto_id",
                producto["id"]
            )
            .execute()
        )

    # --------------------------------------------------------
    # BD
    # --------------------------------------------------------

    (
        supabase
        .table("imagenes_producto")
        .insert({
            "producto_id": producto["id"],
            "ruta": ruta,
            "alt_text": alt_text,
            "principal": principal,
            "orden": orden,
        })
        .execute()
    )

    return (
        ruta,
        dimensiones,
        calidad,
        tamaño_kb
    )


# ============================================================
# ELIMINAR IMAGEN
# ============================================================

def eliminar_imagen(imagen):

    # Eliminar archivo
    eliminar_archivo_storage(
        imagen["ruta"]
    )

    # Eliminar registro BD
    (
        supabase
        .table("imagenes_producto")
        .delete()
        .eq(
            "id",
            imagen["id"]
        )
        .execute()
    )


# ============================================================
# HACER IMAGEN PRINCIPAL
# ============================================================

def hacer_principal(
    imagen_id,
    producto_id
):

    # Quitar principal a todas
    (
        supabase
        .table("imagenes_producto")
        .update({
            "principal": False
        })
        .eq(
            "producto_id",
            producto_id
        )
        .execute()
    )

    # Establecer nueva principal
    (
        supabase
        .table("imagenes_producto")
        .update({
            "principal": True
        })
        .eq(
            "id",
            imagen_id
        )
        .execute()
    )


# ============================================================
# ACTUALIZAR ORDEN
# ============================================================

def actualizar_orden_imagen(
    imagen_id,
    orden
):

    (
        supabase
        .table("imagenes_producto")
        .update({
            "orden": orden
        })
        .eq(
            "id",
            imagen_id
        )
        .execute()
    )


# ============================================================
# ENCABEZADO
# ============================================================

st.title("🛍️ Administración del catálogo")

st.caption(
    "Panel administrativo conectado a Supabase"
)


# ============================================================
# MENÚ
# ============================================================

menu = st.sidebar.radio(
    "Sección",
    [
        "Productos",
        "Nuevo producto",
        "Categorías",
    ]
)


# ============================================================
# PRODUCTOS
# ============================================================

if menu == "Productos":

    st.header("Productos")

    productos = obtener_productos()

    if not productos:

        st.info(
            "No hay productos registrados."
        )

    else:

        for producto in productos:

            categoria = producto.get(
                "categorias"
            )

            if categoria:
                categoria_nombre = (
                    categoria["nombre"]
                )
            else:
                categoria_nombre = (
                    "Sin categoría"
                )

            estado = (
                "🟢 Activo"
                if producto["activo"]
                else
                "🔴 Inactivo"
            )

            destacado = (
                " ⭐ Destacado"
                if producto["destacado"]
                else ""
            )

            with st.expander(
                f"{producto['codigo']} — "
                f"{producto['nombre']} "
                f"| {estado}{destacado}"
            ):

                col1, col2 = st.columns(
                    [2, 1]
                )

                with col1:

                    st.write(
                        f"**Categoría:** "
                        f"{categoria_nombre}"
                    )

                    st.write(
                        f"**Precio:** "
                        f"₡{producto['precio']:,.2f}"
                        if producto["precio"] is not None
                        else
                        "**Precio:** No definido"
                    )

                    if producto[
                        "descripcion"
                    ]:

                        st.write(
                            producto[
                                "descripcion"
                            ]
                        )

                with col2:

                    if producto["activo"]:

                        if st.button(
                            "Desactivar",
                            key=f"des_{producto['id']}"
                        ):

                            cambiar_estado_producto(
                                producto["id"],
                                False
                            )

                            st.rerun()

                    else:

                        if st.button(
                            "Activar",
                            key=f"act_{producto['id']}"
                        ):

                            cambiar_estado_producto(
                                producto["id"],
                                True
                            )

                            st.rerun()

                st.divider()

                # ------------------------------------------------
                # EDITAR
                # ------------------------------------------------

                st.subheader(
                    "Editar producto"
                )

                categorias = obtener_categorias()

                nombres_categorias = [
                    c["nombre"]
                    for c in categorias
                ]

                ids_categorias = [
                    c["id"]
                    for c in categorias
                ]

                try:

                    indice_categoria = (
                        ids_categorias.index(
                            producto[
                                "categoria_id"
                            ]
                        )
                    )

                except ValueError:

                    indice_categoria = 0

                with st.form(
                    key=f"form_editar_{producto['id']}"
                ):

                    nombre = st.text_input(
                        "Nombre",
                        value=producto[
                            "nombre"
                        ]
                    )

                    codigo = st.text_input(
                        "Código",
                        value=producto[
                            "codigo"
                        ]
                    )

                    descripcion = st.text_area(
                        "Descripción",
                        value=producto[
                            "descripcion"
                        ] or ""
                    )

                    precio = st.number_input(
                        "Precio",
                        min_value=0.0,
                        value=float(
                            producto[
                                "precio"
                            ] or 0
                        ),
                        step=500.0
                    )

                    categoria_seleccionada = (
                        st.selectbox(
                            "Categoría",
                            nombres_categorias,
                            index=indice_categoria
                            if nombres_categorias
                            else 0
                        )
                        if nombres_categorias
                        else None
                    )

                    destacado = st.checkbox(
                        "Producto destacado",
                        value=producto[
                            "destacado"
                        ]
                    )

                    orden = st.number_input(
                        "Orden",
                        min_value=0,
                        value=int(
                            producto[
                                "orden"
                            ]
                        ),
                        step=1
                    )

                    guardar = st.form_submit_button(
                        "Guardar cambios",
                        type="primary"
                    )

                if guardar:

                    if not nombre.strip():

                        st.error(
                            "El nombre es obligatorio."
                        )

                    else:

                        categoria_id = None

                        if (
                            categoria_seleccionada
                            and nombres_categorias
                        ):

                            posicion = (
                                nombres_categorias.index(
                                    categoria_seleccionada
                                )
                            )

                            categoria_id = (
                                ids_categorias[
                                    posicion
                                ]
                            )

                        nuevos_datos = {

                            "codigo": codigo.strip(),

                            "nombre": nombre.strip(),

                            "slug": generar_slug(
                                nombre
                            ),

                            "descripcion":
                                descripcion.strip(),

                            "precio": precio,

                            "categoria_id":
                                categoria_id,

                            "destacado":
                                destacado,

                            "orden":
                                orden,
                        }

                        try:

                            actualizar_producto(
                                producto["id"],
                                nuevos_datos
                            )

                            st.success(
                                "Producto actualizado."
                            )

                            st.rerun()

                        except Exception as e:

                            st.error(
                                f"Error: {e}"
                            )

                # ------------------------------------------------
                # IMÁGENES
                # ------------------------------------------------

                st.subheader(
                    "Imágenes"
                )

                imagenes = obtener_imagenes(
                    producto["id"]
                )

                if imagenes:

                    columnas = st.columns(
                        min(4, len(imagenes))
                    )

                    for i, imagen in enumerate(
                        imagenes
                    ):

                        with columnas[
                            i % len(columnas)
                        ]:

                            url = (
                                supabase
                                .storage
                                .from_("catalogo")
                                .get_public_url(
                                    imagen["ruta"]
                                )
                            )

                            st.image(
                                url,
                                width=180
                            )

                            if imagen[
                                "principal"
                            ]:

                                st.success(
                                    "⭐ Principal"
                                )

                            else:

                                st.caption(
                                    "Imagen secundaria"
                                )

                            nuevo_orden = st.number_input(
                                "Orden",
                                min_value=0,
                                value=int(
                                    imagen["orden"]
                                ),
                                key=(
                                    f"orden_"
                                    f"{imagen['id']}"
                                )
                            )

                            if st.button(
                                "Guardar orden",
                                key=(
                                    f"guardar_"
                                    f"{imagen['id']}"
                                )
                            ):

                                actualizar_orden_imagen(
                                    imagen["id"],
                                    nuevo_orden
                                )

                                st.rerun()

                            if not imagen[
                                "principal"
                            ]:

                                if st.button(
                                    "⭐ Principal",
                                    key=(
                                        f"principal_"
                                        f"{imagen['id']}"
                                    )
                                ):

                                    hacer_principal(
                                        imagen["id"],
                                        producto["id"]
                                    )

                                    st.rerun()

                            if st.button(
                                "🗑️ Eliminar",
                                key=(
                                    f"eliminar_"
                                    f"{imagen['id']}"
                                )
                            ):

                                eliminar_imagen(
                                    imagen
                                )

                                st.success(
                                    "Imagen eliminada."
                                )

                                st.rerun()

                else:

                    st.info(
                        "Este producto no tiene imágenes."
                    )

                # ------------------------------------------------
                # SUBIR IMÁGENES
                # ------------------------------------------------

                st.subheader(
                    "Agregar imágenes"
                )

                archivos = st.file_uploader(
                    "Selecciona una o varias imágenes",
                    type=[
                        "jpg",
                        "jpeg",
                        "png",
                        "webp"
                    ],
                    accept_multiple_files=True,
                    key=(
                        f"upload_"
                        f"{producto['id']}"
                    )
                )

                if archivos:

                    for archivo in archivos:

                        st.write(
                            f"📷 {archivo.name} — "
                            f"{archivo.size / 1024:.1f} KB"
                        )

                    if st.button(
                        "⬆️ Subir imágenes",
                        key=(
                            f"subir_"
                            f"{producto['id']}"
                        ),
                        type="primary"
                    ):

                        imagenes_actuales = (
                            obtener_imagenes(
                                producto["id"]
                            )
                        )

                        cantidad_actual = len(
                            imagenes_actuales
                        )

                        for posicion, archivo in enumerate(
                            archivos
                        ):

                            es_principal = (
                                cantidad_actual == 0
                                and posicion == 0
                            )

                            try:

                                resultado = subir_imagen(
                                    producto,
                                    archivo,
                                    principal=es_principal,
                                    orden=(
                                        cantidad_actual
                                        + posicion
                                    ),
                                    alt_text=producto[
                                        "nombre"
                                    ]
                                )

                                ruta, dimensiones, calidad, tamaño_kb = (
                                    resultado
                                )

                                st.success(
                                    f"{archivo.name} → "
                                    f"{dimensiones[0]}x"
                                    f"{dimensiones[1]} px, "
                                    f"{tamaño_kb:.1f} KB"
                                )

                            except Exception as e:

                                st.error(
                                    f"Error subiendo "
                                    f"{archivo.name}: {e}"
                                )

                        st.rerun()


# ============================================================
# NUEVO PRODUCTO
# ============================================================

elif menu == "Nuevo producto":

    st.header(
        "Crear nuevo producto"
    )

    categorias = obtener_categorias()

    if not categorias:

        st.warning(
            "Primero debes crear una categoría."
        )

    else:

        nombres = [
            c["nombre"]
            for c in categorias
        ]

        ids = [
            c["id"]
            for c in categorias
        ]

        with st.form(
            "nuevo_producto"
        ):

            codigo = st.text_input(
                "Código",
                placeholder="PROD-004"
            )

            nombre = st.text_input(
                "Nombre"
            )

            descripcion = st.text_area(
                "Descripción"
            )

            precio = st.number_input(
                "Precio",
                min_value=0.0,
                step=500.0
            )

            categoria_nombre = (
                st.selectbox(
                    "Categoría",
                    nombres
                )
            )

            destacado = st.checkbox(
                "Producto destacado"
            )

            orden = st.number_input(
                "Orden",
                min_value=0,
                value=0,
                step=1
            )

            crear = st.form_submit_button(
                "Crear producto",
                type="primary"
            )

        if crear:

            if not codigo.strip():

                st.error(
                    "El código es obligatorio."
                )

            elif not nombre.strip():

                st.error(
                    "El nombre es obligatorio."
                )

            else:

                categoria_id = ids[
                    nombres.index(
                        categoria_nombre
                    )
                ]

                datos = {

                    "codigo":
                        codigo.strip(),

                    "nombre":
                        nombre.strip(),

                    "slug":
                        generar_slug(
                            nombre
                        ),

                    "descripcion":
                        descripcion.strip(),

                    "precio":
                        precio,

                    "categoria_id":
                        categoria_id,

                    "activo":
                        True,

                    "destacado":
                        destacado,

                    "orden":
                        orden,
                }

                try:

                    crear_producto(
                        datos
                    )

                    st.success(
                        "Producto creado correctamente."
                    )

                    st.rerun()

                except Exception as e:

                    st.error(
                        f"Error creando producto: {e}"
                    )


# ============================================================
# CATEGORÍAS
# ============================================================

elif menu == "Categorías":

    st.header(
        "Categorías"
    )

    categorias = obtener_categorias()

    st.subheader(
        "Crear categoría"
    )

    with st.form(
        "nueva_categoria"
    ):

        nombre = st.text_input(
            "Nombre"
        )

        orden = st.number_input(
            "Orden",
            min_value=0,
            value=0,
            step=1
        )

        crear = st.form_submit_button(
            "Crear categoría",
            type="primary"
        )

    if crear:

        if not nombre.strip():

            st.error(
                "El nombre es obligatorio."
            )

        else:

            try:

                crear_categoria(
                    nombre.strip(),
                    generar_slug(
                        nombre
                    ),
                    orden
                )

                st.success(
                    "Categoría creada."
                )

                st.rerun()

            except Exception as e:

                st.error(
                    f"Error: {e}"
                )

    st.divider()

    st.subheader(
        "Categorías existentes"
    )

    for categoria in categorias:

        with st.expander(
            f"{categoria['nombre']} "
            f"({'Activa' if categoria['activo'] else 'Inactiva'})"
        ):

            with st.form(
                key=f"categoria_{categoria['id']}"
            ):

                nuevo_nombre = st.text_input(
                    "Nombre",
                    value=categoria[
                        "nombre"
                    ]
                )

                nuevo_slug = st.text_input(
                    "Slug",
                    value=categoria[
                        "slug"
                    ]
                )

                nuevo_orden = st.number_input(
                    "Orden",
                    min_value=0,
                    value=int(
                        categoria[
                            "orden"
                        ]
                    )
                )

                nueva_activa = st.checkbox(
                    "Activa",
                    value=categoria[
                        "activo"
                    ]
                )

                guardar = st.form_submit_button(
                    "Guardar"
                )

            if guardar:

                try:

                    actualizar_categoria(
                        categoria["id"],
                        {
                            "nombre":
                                nuevo_nombre.strip(),

                            "slug":
                                nuevo_slug.strip(),

                            "orden":
                                nuevo_orden,

                            "activo":
                                nueva_activa,
                        }
                    )

                    st.success(
                        "Categoría actualizada."
                    )

                    st.rerun()

                except Exception as e:

                    st.error(
                        f"Error: {e}"
                    )
