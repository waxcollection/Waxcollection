/* Tienda sencilla: sin dependencias, precios definitivos calculados por PostgreSQL. */
const cfg = window.PERFUMERIA_CONFIG || {};
const $ = (id) => document.getElementById(id);
const money = (n) => '₡' + Number(n || 0).toLocaleString('es-CR', { maximumFractionDigits: 2 });
const text = (s) => String(s ?? '');
const api = (path) => cfg.API_BASE.replace(/\/$/, '') + '/api/' + path;
const escapeHtml = (s) => text(s).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let catalog = { marcas: [], perfumes: [], ocasiones: [], storageBase: '' };
let cart = loadCart();
let activeProduct = null;
let galleryIndex = 0;
function loadCart() {
  try {
    const data = JSON.parse(localStorage.getItem('perfumeria-cart-v1') || '{}');
    return Date.now() - data.updated < 7 * 86400000 && Array.isArray(data.items) ? data.items : [];
  } catch { return []; }
}
function saveCart() {
  localStorage.setItem('perfumeria-cart-v1', JSON.stringify({ updated: Date.now(), items: cart }));
  $('cart-count').textContent = cart.reduce((a, x) => a + x.cantidad, 0);
}
function imageUrl(path) {
  return catalog.storageBase + text(path).split('/').map(encodeURIComponent).join('/');
}
function variantPrice(v) { return Math.round(Number(v.precio) * (1 - Number(v.descuento || 0) / 100) * 100) / 100; }
function available(p) { return p.presentaciones.some(v => Number(v.disponible) > 0); }
function brandName(p) { return catalog.marcas.find(m => m.id === p.marca_id)?.nombre || ''; }
function renderFilters() {
  $('brand-filter').innerHTML = '<option value="">Todas</option>' + catalog.marcas.map(m => `<option value="${m.id}">${escapeHtml(m.nombre)}</option>`).join('');
  $('occasion-filter').innerHTML = '<option value="">Todas</option>' + catalog.ocasiones.map(o => `<option value="${o.id}">${escapeHtml(o.nombre)}</option>`).join('');
}
function renderProducts() {
  const q = $('search').value.trim().toLowerCase(), brand = $('brand-filter').value;
  const gender = $('gender-filter').value, occasion = $('occasion-filter').value;
  const sale = $('sale-filter').checked;
  const filtered = catalog.perfumes.filter(p => {
    return (!q || (p.nombre + ' ' + brandName(p) + ' ' + (p.descripcion || '')).toLowerCase().includes(q))
      && (!brand || String(p.marca_id) === brand)
      && (!gender || p.genero === gender)
      && (!occasion || p.ocasiones.map(String).includes(occasion))
      && (!sale || p.presentaciones.some(v => Number(v.descuento) > 0));
  });
  $('result-count').textContent = filtered.length + ' perfumes';
  $('status').textContent = filtered.length ? '' : 'No encontramos perfumes con estos filtros.';
  $('products').innerHTML = filtered.map(p => {
    const variants = p.presentaciones.filter(v => Number(v.disponible) > 0);
    const low = variants.length ? Math.min(...variants.map(variantPrice)) : null;
    const img = p.imagenes[0];
    return `<article class="product">
      ${img ? `<img src="${escapeHtml(imageUrl(img.path))}" alt="${escapeHtml(img.alt || p.nombre)}" loading="lazy">` : '<div class="fallback" aria-hidden="true">✦</div>'}
      <div class="product-info">
        <p class="muted">${escapeHtml(brandName(p))} · ${escapeHtml(p.genero.replace('_', ' '))}</p>
        <h3>${escapeHtml(p.nombre)}</h3>
        <p class="price">${low === null ? 'Agotado' : 'Desde ' + money(low)}</p>
        <button type="button" data-product="${p.id}">Ver presentaciones</button>
      </div>
    </article>`;
  }).join('');
  document.querySelectorAll('[data-product]').forEach(b => b.addEventListener('click', () => openProduct(Number(b.dataset.product))));
}
function openProduct(id) {
  activeProduct = catalog.perfumes.find(p => p.id === id);
  if (!activeProduct) return;
  galleryIndex = 0;
  renderDetail();
  $('detail-dialog').showModal();
}
function renderDetail() {
  const p = activeProduct, pics = p.imagenes;
  const pic = pics[galleryIndex];
  const image = pic ? `<img src="${escapeHtml(imageUrl(pic.path))}" alt="${escapeHtml(pic.alt || p.nombre)}">` : '<div class="fallback">✦</div>';
  $('detail-content').innerHTML = `<div class="detail-layout">
    <div>${image}<div class="gallery-controls">
      ${pics.length > 1 ? '<button class="outline" id="prev-photo" type="button">‹</button><span>' + (galleryIndex + 1) + '/' + pics.length + '</span><button class="outline" id="next-photo" type="button">›</button>' : ''}
    </div></div>
    <div><p class="eyebrow">${escapeHtml(brandName(p))}</p><h2>${escapeHtml(p.nombre)}</h2>
    <p class="muted">${escapeHtml(p.familia_olfativa || '')}</p>
    <p>${escapeHtml(p.descripcion || '')}</p>
    <form id="add-form"><div class="variant-list">
    ${p.presentaciones.map((v, i) => `<label class="variant" aria-disabled="${Number(v.disponible) <= 0}">
      <input type="radio" name="variant" value="${v.id}" ${Number(v.disponible) <= 0 ? 'disabled' : ''} ${i === p.presentaciones.findIndex(x => Number(x.disponible) > 0) ? 'checked' : ''} required>
      <span>${v.tipo === 'decant' ? 'Decant' : 'Botella'} ${v.ml} ml · <strong>${money(variantPrice(v))}</strong>
      ${Number(v.descuento) > 0 ? '<small>Oferta -' + v.descuento + '%</small>' : ''}
      ${Number(v.disponible) <= 0 ? ' · Agotado' : ''}</span></label>`).join('')}
    </div><label>Cantidad <input type="number" name="qty" min="1" value="1" max="20" required></label>
    <button type="submit" ${available(p) ? '' : 'disabled'}>Agregar al carrito</button></form>
    ${p.acordes?.length ? '<h3>Acordes</h3>' + p.acordes.map(a => '<p>' + escapeHtml(a.nombre) + ' · ' + a.intensidad + '/100</p>').join('') : ''}
    </div></div>`;
  $('prev-photo')?.addEventListener('click', () => { galleryIndex = (galleryIndex - 1 + pics.length) % pics.length; renderDetail(); });
  $('next-photo')?.addEventListener('click', () => { galleryIndex = (galleryIndex + 1) % pics.length; renderDetail(); });
  $('add-form').addEventListener('submit', e => {
    e.preventDefault();
    const data = new FormData(e.target);
    const v = p.presentaciones.find(x => x.id === Number(data.get('variant')));
    const qty = Number(data.get('qty'));
    if (!v || !Number.isInteger(qty) || qty < 1 || qty > 20) return;
    const current = cart.find(x => x.presentacion_id === v.id);
    const next = qty + (current?.cantidad || 0);
    if (next > Number(v.disponible)) { alert('No hay existencias suficientes.'); return; }
    if (current) current.cantidad = next;
    else cart.push({ presentacion_id: v.id, cantidad: next });
    saveCart(); $('detail-dialog').close(); openCart();
  });
}
function cartLines() {
  return cart.map(item => {
    for (const p of catalog.perfumes) {
      const v = p.presentaciones.find(x => x.id === item.presentacion_id);
      if (v) return { ...item, perfume: p, variant: v };
    }
    return null;
  }).filter(Boolean);
}
function openCart() {
  renderCart();
  $('cart-dialog').showModal();
}
function renderCart() {
  const lines = cartLines();
  $('cart-items').innerHTML = lines.length ? lines.map(x => `<div class="cart-line">
    <div><strong>${escapeHtml(x.perfume.nombre)}</strong><br><small>${x.variant.tipo} ${x.variant.ml} ml · ${x.cantidad} × ${money(variantPrice(x.variant))}</small></div>
    <button class="outline" type="button" data-remove="${x.presentacion_id}" aria-label="Eliminar">×</button></div>`).join('') : '<p class="muted">Tu carrito está vacío.</p>';
  $('cart-total').textContent = money(lines.reduce((sum, x) => sum + variantPrice(x.variant) * x.cantidad, 0));
  $('checkout-btn').disabled = !lines.length;
  document.querySelectorAll('[data-remove]').forEach(b => b.addEventListener('click', () => {
    cart = cart.filter(x => x.presentacion_id !== Number(b.dataset.remove)); saveCart(); renderCart();
  }));
}
async function checkout(e) {
  e.preventDefault();
  const btn = $('checkout-btn'), result = $('checkout-result'), data = new FormData(e.target);
  const tel = text(data.get('telefono')).replace(/\D/g, '');
  const phone = tel.startsWith('506') && tel.length === 11 ? tel.slice(3) : tel;
  if (!/^[0-9]{8}$/.test(phone)) { result.textContent = 'Introduce un teléfono costarricense de 8 dígitos.'; return; }
  if (!cart.length) return;
  const pop = window.open('about:blank', '_blank');
  btn.disabled = true; result.textContent = 'Registrando pedido…';
  try {
    const response = await fetch(api('pedidos'), {
      method: 'POST', headers: {'content-type':'application/json'},
      body: JSON.stringify({ nombre: data.get('nombre'), telefono: '+506' + phone, items: cart }),
    });
    const order = await response.json();
    if (!response.ok) throw new Error(order.error || 'No se pudo crear el pedido');
    const lines = order.items.map(x => `• ${x.nombre} — ${x.tipo} ${x.ml} ml × ${x.cantidad} = ${money(x.precio * x.cantidad)}`);
    const message = `Hola, quiero realizar este pedido:\nOrden #${order.numero}\n${lines.join('\n')}\nTotal: ${money(order.total)}\nNombre: ${data.get('nombre')}\nTeléfono: +506${phone}\nCódigo de seguimiento: ${order.codigo}`;
    const whats = `https://wa.me/${cfg.WHATSAPP_NUMBER}?text=${encodeURIComponent(message)}`;
    if (pop) pop.location.href = whats;
    cart = []; saveCart(); renderCart();
    result.innerHTML = `<div class="notice"><strong>Pedido #${order.numero} registrado.</strong><p>Tu código es <code>${escapeHtml(order.codigo)}</code>. Guárdalo.</p><p>Debes enviar el mensaje por WhatsApp para que podamos atenderlo.</p></div>`;
    if (!pop) {
      const a = document.createElement('a'); a.href = whats; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = 'Abrir WhatsApp'; result.append(a);
    }
  } catch (err) {
    if (pop) pop.close();
    result.textContent = err.message || 'No se pudo crear el pedido';
  } finally { btn.disabled = !cart.length; }
}
async function track(e) {
  e.preventDefault();
  $('track-result').textContent = 'Consultando…';
  const data = new FormData(e.target);
  try {
    const r = await fetch(api('seguimiento'), {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ codigo: text(data.get('codigo')).trim().toUpperCase(), ultimos4: data.get('ultimos4') }),
    });
    const v = await r.json();
    if (!r.ok) throw new Error(v.error || 'No encontrado');
    $('track-result').textContent = `Orden #${v.numero} · ${v.nombre} · Teléfono terminado en ${v.telefono_ultimos4} · Estado: ${v.estado.replaceAll('_',' ')}`;
  } catch (err) { $('track-result').textContent = err.message; }
}
async function init() {
  $('brand-name').textContent = cfg.BRAND_NAME || 'Perfumería';
  $('footer-brand').textContent = cfg.BRAND_NAME || 'Perfumería';
  $('footer-year').textContent = new Date().getFullYear();
  saveCart();
  document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => $(b.dataset.close).close()));
  $('cart-toggle').addEventListener('click', openCart);
  $('checkout-form').addEventListener('submit', checkout);
  $('track-form').addEventListener('submit', track);
  for (const id of ['search','brand-filter','gender-filter','occasion-filter','sale-filter']) $(id).addEventListener('input', renderProducts);
  try {
    if (cfg.API_BASE.includes('REEMPLAZAR')) throw new Error('Configura la URL del Worker en config.js');
    const response = await fetch(api('catalogo'));
    if (!response.ok) throw new Error('No se pudo conectar con la API');
    catalog = await response.json();
    catalog.perfumes ||= []; catalog.marcas ||= []; catalog.ocasiones ||= [];
    renderFilters(); renderProducts();
  } catch (err) { $('status').textContent = err.message; }
}
init();
