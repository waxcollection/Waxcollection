"""Login individual con Supabase Auth, sin service_role y sin caché global."""
import streamlit as st
from supabase import create_client


def get_client():
    if "sb_client" not in st.session_state:
        st.session_state.sb_client = create_client(
            st.secrets["SUPABASE_URL"],
            st.secrets["SUPABASE_ANON_KEY"],
        )
    return st.session_state.sb_client


def require_admin():
    try:
        supabase = get_client()
    except (KeyError, FileNotFoundError):
        st.error("Configura SUPABASE_URL y SUPABASE_ANON_KEY en Streamlit Secrets.")
        st.stop()

    if not st.session_state.get("logged_in"):
        st.subheader("Acceso administrativo")
        with st.form("supabase_login"):
            email = st.text_input("Correo electrónico")
            password = st.text_input("Contraseña", type="password")
            submit = st.form_submit_button("Iniciar sesión")
        if submit:
            try:
                result = supabase.auth.sign_in_with_password(
                    {"email": email.strip(), "password": password}
                )
                if result.user is None:
                    raise ValueError("Credenciales no válidas")
                st.session_state.logged_in = True
                st.rerun()
            except Exception:
                st.error("No se pudo iniciar sesión. Revisa las credenciales.")
        st.stop()

    try:
        session = supabase.auth.get_session()
        if not session or not session.user:
            raise ValueError("Sesión expirada")
        # La política RLS admin_ver_propio_registro determina si esta cuenta está autorizada.
        response = supabase.table("admin_usuarios").select("activo").eq(
            "user_id", session.user.id
        ).eq("activo", True).limit(1).execute()
        if not response.data:
            st.error("Tu cuenta no está autorizada como administradora.")
            st.stop()
    except Exception:
        st.session_state.logged_in = False
        supabase.auth.sign_out()
        st.warning("La sesión terminó. Inicia sesión de nuevo.")
        st.stop()


def logout():
    try:
        get_client().auth.sign_out()
    finally:
        st.session_state.logged_in = False
        st.session_state.pop("sb_client", None)
