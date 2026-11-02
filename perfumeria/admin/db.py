"""Cliente Supabase de la sesión autenticada; sujeto a RLS."""
from auth import get_client

def client():
    return get_client()

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
