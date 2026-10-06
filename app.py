import streamlit as st
from supabase import create_client

st.set_page_config(
    page_title="Administración del catálogo",
    page_icon="🛍️",
    layout="wide"
)

supabase = create_client(
    st.secrets["SUPABASE_URL"],
    st.secrets["SUPABASE_SERVICE_ROLE_KEY"]
)

st.title("🛍️ Administración del catálogo")

st.success("Conectado correctamente a Supabase")
