"""Acceso privado a Supabase. Ejecutar solo en Streamlit protegido; nunca en navegador."""
from supabase import create_client
import streamlit as st


@st.cache_resource
def client():
    return create_client(
        st.secrets["SUPABASE_URL"],
        st.secrets["SUPABASE_SERVICE_ROLE_KEY"],
    )


def rows(table, columns="*", order="id"):
    q = client().table(table).select(columns)
    if order:
        q = q.order(order)
    return q.execute().data or []


def insert(table, values):
    return client().table(table).insert(values).execute().data


def update(table, record_id, values):
    return client().table(table).update(values).eq("id", record_id).execute().data


def call(fn, values):
    return client().rpc(fn, values).execute().data
