import io
import uuid

import streamlit as st
from PIL import Image
from supabase import create_client


# ============================================================
# CONFIGURACIÓN
# ============================================================

st.set_page_config(
    page_title="Administración del catálogo",
    page_icon="🛍️",
    layout="wide"
)


# ============================================================
# SUPABASE
# ============================================================

supabase = create_client(
    st.secrets["SUPABASE_URL"],
    st.secrets["SUPABASE_SERVICE_ROLE_KEY"]
)


# ============================================================
# OPTIMIZAR IMAGEN
# ============================================================

def optimizar_imagen(
    archivo,
    max_ancho=800,
    max_kb=150
):
    """
    Convierte la imagen a WebP, mantiene proporción
    y trata de mantenerla por debajo de max_kb.
    """

    imagen = Image.open(archivo)

    # Corregir orientación EXIF
    try:
        from PIL import ImageOps
        imagen = ImageOps.exif_transpose(imagen)
    except Exception:
        pass

    # Convertir a RGB
    if imagen.mode in ("RGBA", "LA"):
        fondo = Image.new("RGB", imagen.size, "WHITE")
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
            imagen.height * max_ancho / imagen.width
        )

        imagen = imagen.resize(
            (max_ancho, nueva_altura),
            Image.Resampling.LANCZOS
        )

    # --------------------------------------------------------
    # COMPRIMIR WEBP
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

        tamaño_kb = len(buffer.getvalue()) / 1024

        if tamaño_kb <= max_kb:
            break

        calidad -= 5

    return buffer.getvalue(), imagen.size, calidad, tamaño_kb


# ============================================================
# INTERFAZ
# ============================================================

st.title("🛍️ Administración del catálogo")

st.success("Conectado correctamente a Supabase")


st.divider()

st.subheader("Prueba de subida de imagen")


producto_codigo = st.text_input(
    "Código del producto",
    value="PROD-001"
)


archivo = st.file_uploader(
    "Selecciona una imagen",
    type=["jpg", "jpeg", "png", "webp"]
)


if archivo:

    st.write(
        f"**Archivo original:** {archivo.name}"
    )

    st.write(
        f"**Tamaño original:** "
        f"{archivo.size / 1024:.1f} KB"
    )

    # --------------------------------------------------------
    # OPTIMIZAR
    # --------------------------------------------------------

    try:

        imagen_webp, dimensiones, calidad, tamaño_kb = (
            optimizar_imagen(archivo)
        )

        st.write(
            f"**Dimensiones finales:** "
            f"{dimensiones[0]} × {dimensiones[1]} px"
        )

        st.write(
            f"**Formato:** WebP"
        )

        st.write(
            f"**Tamaño final:** "
            f"{tamaño_kb:.1f} KB"
        )

        st.write(
            f"**Calidad utilizada:** {calidad}"
        )

        # ----------------------------------------------------
        # VISTA PREVIA
        # ----------------------------------------------------

        st.image(
            imagen_webp,
            caption="Imagen optimizada",
            width=400
        )

        # ----------------------------------------------------
        # SUBIR
        # ----------------------------------------------------

        if st.button(
            "⬆️ Subir imagen",
            type="primary"
        ):

            nombre_archivo = (
                f"{uuid.uuid4().hex}.webp"
            )

            ruta = (
                f"productos/"
                f"{producto_codigo}/"
                f"{nombre_archivo}"
            )

            with st.spinner("Subiendo imagen..."):

                resultado = supabase.storage \
                    .from_("catalogo") \
                    .upload(
                        ruta,
                        imagen_webp,
                        {
                            "content-type": "image/webp",
                            "cache-control": "31536000",
                            "upsert": "false"
                        }
                    )

            st.success("Imagen subida correctamente")

            # ------------------------------------------------
            # URL PÚBLICA
            # ------------------------------------------------

            url = supabase.storage \
                .from_("catalogo") \
                .get_public_url(ruta)

            st.write("### URL pública")

            st.code(url)

            st.write("### Vista desde Storage")

            st.image(url)

            st.write("### Ruta que guardaremos en BD")

            st.code(ruta)

    except Exception as e:

        st.error(
            f"Error procesando la imagen: {e}"
        )
