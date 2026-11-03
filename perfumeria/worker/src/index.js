const json = (data, status = 200, extra = {}) => new Response(JSON.stringify(data), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra },
});
function cors(origin, allowed) {
  return origin === allowed ? {
    "access-control-allow-origin": allowed,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "vary": "Origin",
  } : {};
}
async function rpc(env, fn, body) {
  const base = env.SUPABASE_URL?.replace(/\/$/, "");
  if (!base || !env.SUPABASE_ANON_KEY) throw new Error("Worker sin configurar");
  const r = await fetch(`${base}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    // Nunca exponer trazas SQL ni detalles de acceso.
    throw new Error(`Supabase RPC failed (${r.status})`);
  }
  return r.json();
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get("origin");
    const allowed = env.FRONTEND_ORIGIN?.replace(/\/$/, "");
    const headers = cors(origin, allowed);
    if (request.method === "OPTIONS") {
      return new Response(null, { status: origin === allowed ? 204 : 403, headers });
    }
    if (origin && origin !== allowed) return json({ error: "Origen no permitido" }, 403);
    const path = url.pathname.replace(/\/$/, "");
    if (!["/api/catalogo", "/api/pedidos", "/api/seguimiento"].includes(path)) {
      return json({ error: "Ruta no encontrada" }, 404, headers);
    }
    if (path === "/api/catalogo" && request.method === "GET") {
      try {
        const data = await rpc(env, "tienda_catalogo", {});
        return json({ ...data, storageBase: `${env.SUPABASE_URL.replace(/\/$/, "")}/storage/v1/object/public/perfumes/` }, 200, { ...headers, "cache-control": "public, max-age=60" });
      } catch {
        return json({ error: "No se pudo cargar el catálogo" }, 503, headers);
      }
    }
    if (path === "/api/pedidos" && request.method === "POST") {
      try {
        if (Number(request.headers.get("content-length") || 0) > 12000) return json({ error: "Solicitud demasiado grande" }, 413, headers);
        const input = await request.json();
        if (!input || typeof input.nombre !== "string" || typeof input.telefono !== "string" || !Array.isArray(input.items)) {
          return json({ error: "Solicitud inválida" }, 400, headers);
        }
        const data = await rpc(env, "tienda_crear_pedido", {
          p_nombre: input.nombre, p_telefono: input.telefono, p_items: input.items,
        });
        return json(data, 201, headers);
      } catch {
        return json({ error: "Pedido no disponible. Revisa existencias y datos." }, 400, headers);
      }
    }
    if (path === "/api/seguimiento" && request.method === "POST") {
      try {
        const input = await request.json();
        const codigo = String(input.codigo || "").trim().toUpperCase();
        const ultimos = String(input.ultimos4 || "").trim();
        if (!/^[A-F0-9]{24}$/.test(codigo) || !/^\d{4}$/.test(ultimos)) {
          return json({ error: "Código o teléfono inválidos" }, 400, headers);
        }
        const data = await rpc(env, "tienda_seguimiento", { p_codigo: codigo, p_ultimos4: ultimos });
        return data ? json(data, 200, headers) : json({ error: "Pedido no encontrado" }, 404, headers);
      } catch {
        return json({ error: "No se pudo consultar el pedido" }, 503, headers);
      }
    }
    return json({ error: "Método no permitido" }, 405, headers);
  },
};
