/* =========================================================
   CONFIGURACIÓN SUPABASE
========================================================= */

// IMPORTANTE:
// Utiliza solamente la Publishable / Anon Key.
// NUNCA coloques aquí la service_role key.

const SUPABASE_URL = 'https://cufiqlngaetgyyiqxgpg.supabase.co';

const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN1ZmlxbG5nYWV0Z3l5aXF4Z3BnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyNjkwODksImV4cCI6MjEwNjg0NTA4OX0.H1QIhVPHV5Z121nRiU0D3ScrJSFJ0jbGuqzO7AyOKxI';

/* =========================================================
   VARIABLES
========================================================= */

let categorias = [];
let productos = [];
let categoriaSeleccionada = null;

/* =========================================================
   ELEMENTOS DOM
========================================================= */

const categoriesContainer = document.getElementById('categories');
const productsGrid = document.getElementById('productsGrid');
const productsTitle = document.getElementById('productsTitle');
const productCount = document.getElementById('productCount');
const loading = document.getElementById('loading');
const errorMessage = document.getElementById('errorMessage');
const errorText = document.getElementById('errorText');
const emptyMessage = document.getElementById('emptyMessage');
const retryButton = document.getElementById('retryButton');
const productModal = document.getElementById('productModal');
const modalOverlay = document.getElementById('modalOverlay');
const modalClose = document.getElementById('modalClose');
const modalImage = document.getElementById('modalImage');
const modalCategory = document.getElementById('modalCategory');
const modalTitle = document.getElementById('modalTitle');
const modalDescription = document.getElementById('modalDescription');
const modalPrice = document.getElementById('modalPrice');
const currentYear = document.getElementById('currentYear');

/* =========================================================
   INICIO
========================================================= */

document.addEventListener('DOMContentLoaded', iniciar);

async function iniciar() {
  currentYear.textContent = new Date().getFullYear();

  try {
    mostrarLoading();
    await cargarCategorias();
    await cargarProductos();
    ocultarLoading();
  } catch (error) {
    console.error(error);
    mostrarError(error.message || 'No fue posible cargar el catálogo.');
  }
}

/* =========================================================
   SUPABASE REQUEST
========================================================= */

async function supabaseFetch(tabla, parametros = '') {
  const url = `${SUPABASE_URL}/rest/v1/${tabla}${parametros}`;

  const response = await fetch(url, {
    method: 'GET',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json'
    }
  });

  if (!response.ok) {
    const texto = await response.text();
    throw new Error(`Supabase respondió ${response.status}: ${texto}`);
  }

  return response.json();
}

/* =========================================================
   CATEGORÍAS
========================================================= */

async function cargarCategorias() {
  categorias = await supabaseFetch(
    'categorias',
    '?select=id,nombre,slug,orden&activo=eq.true&order=orden.asc'
  );
  renderizarCategorias();
}

/* =========================================================
   PRODUCTOS
========================================================= */

async function cargarProductos() {
  productos = await supabaseFetch(
    'productos',
    '?select=id,codigo,nombre,slug,descripcion,precio,categoria_id,destacado,orden&activo=eq.true&order=orden.asc'
  );

  // Cargamos las imágenes por separado.
  // Esto mantiene las consultas simples y facilita trabajar con Supabase REST.
  for (const producto of productos) {
    const imagenes = await supabaseFetch(
      'imagenes_producto',
      `?select=id,ruta,alt_text,principal,orden&producto_id=eq.${producto.id}&order=orden.asc`
    );
    producto.imagenes = imagenes;
  }

  renderizarProductos();
}

/* =========================================================
   CATEGORÍAS UI
========================================================= */

function renderizarCategorias() {
  categoriesContainer.innerHTML = '';

  // Botón TODOS
  const allButton = document.createElement('button');
  allButton.className = 'category-button active';
  allButton.textContent = 'Todos';
  allButton.dataset.category = 'all';
  allButton.addEventListener('click', () => seleccionarCategoria(null));
  categoriesContainer.appendChild(allButton);

  // Categorías reales
  categorias.forEach((categoria) => {
    const button = document.createElement('button');
    button.className = 'category-button';
    button.textContent = categoria.nombre;
    button.dataset.category = categoria.id;
    button.addEventListener('click', () => seleccionarCategoria(categoria.id));
    categoriesContainer.appendChild(button);
  });
}

/* =========================================================
   SELECCIONAR CATEGORÍA
========================================================= */

function seleccionarCategoria(categoriaId) {
  categoriaSeleccionada = categoriaId;

  document.querySelectorAll('.category-button').forEach((button) => {
    button.classList.remove('active');
  });

  const selectedButton =
    categoriaId === null
      ? document.querySelector('[data-category="all"]')
      : document.querySelector(`[data-category="${categoriaId}"]`);

  if (selectedButton) {
    selectedButton.classList.add('active');
  }

  renderizarProductos();
}

/* =========================================================
   PRODUCTOS UI
========================================================= */

function renderizarProductos() {
  productsGrid.innerHTML = '';
  emptyMessage.classList.add('hidden');

  let productosFiltrados = productos;

  if (categoriaSeleccionada !== null) {
    productosFiltrados = productos.filter(
      (producto) => producto.categoria_id === categoriaSeleccionada
    );
  }

  productCount.textContent = `${productosFiltrados.length} ${
    productosFiltrados.length === 1 ? 'producto' : 'productos'
  }`;

  if (categoriaSeleccionada === null) {
    productsTitle.textContent = 'Todos los productos';
  } else {
    const categoria = categorias.find(
      (categoria) => categoria.id === categoriaSeleccionada
    );
    productsTitle.textContent = categoria ? categoria.nombre : 'Productos';
  }

  if (productosFiltrados.length === 0) {
    emptyMessage.classList.remove('hidden');
    return;
  }

  productosFiltrados.forEach((producto) => {
    const card = crearTarjetaProducto(producto);
    productsGrid.appendChild(card);
  });
}

/* =========================================================
   CREAR TARJETA
========================================================= */

function crearTarjetaProducto(producto) {
  const card = document.createElement('article');
  card.className = 'product-card';

  const imageContainer = document.createElement('div');
  imageContainer.className = 'product-image';

  const imagenPrincipal = obtenerImagenPrincipal(producto);

  if (imagenPrincipal) {
    const img = document.createElement('img');
    img.src = obtenerUrlImagen(imagenPrincipal.ruta);
    img.alt = imagenPrincipal.alt_text || producto.nombre;
    img.loading = 'lazy';
    imageContainer.appendChild(img);
  } else {
    const placeholder = document.createElement('div');
    placeholder.className = 'image-placeholder';
    placeholder.textContent = '📦';
    imageContainer.appendChild(placeholder);
  }

  if (producto.destacado) {
    const featured = document.createElement('span');
    featured.className = 'product-featured';
    featured.textContent = 'Destacado';
    imageContainer.appendChild(featured);
  }

  const info = document.createElement('div');
  info.className = 'product-info';

  const category = obtenerCategoria(producto.categoria_id);

  const categoryElement = document.createElement('div');
  categoryElement.className = 'product-category';
  categoryElement.textContent = category ? category.nombre : '';

  const name = document.createElement('h3');
  name.className = 'product-name';
  name.textContent = producto.nombre;

  const description = document.createElement('p');
  description.className = 'product-description';
  description.textContent = producto.descripcion || 'Sin descripción.';

  const price = document.createElement('div');
  price.className = 'product-price';
  price.textContent = formatearPrecio(producto.precio);

  info.appendChild(categoryElement);
  info.appendChild(name);
  info.appendChild(description);
  info.appendChild(price);

  card.appendChild(imageContainer);
  card.appendChild(info);

  card.addEventListener('click', () => abrirModal(producto));

  return card;
}

/* =========================================================
   IMAGEN PRINCIPAL
========================================================= */

function obtenerImagenPrincipal(producto) {
  if (!producto.imagenes || producto.imagenes.length === 0) {
    return null;
  }

  return (
    producto.imagenes.find((imagen) => imagen.principal === true) ||
    producto.imagenes[0]
  );
}

/* =========================================================
   URL STORAGE
========================================================= */

function obtenerUrlImagen(ruta) {
  return `${SUPABASE_URL}/storage/v1/object/public/catalogo/${ruta}`;
}

/* =========================================================
   CATEGORÍA PRODUCTO
========================================================= */

function obtenerCategoria(categoriaId) {
  return categorias.find((categoria) => categoria.id === categoriaId);
}

/* =========================================================
   PRECIO
========================================================= */

function formatearPrecio(precio) {
  if (precio === null || precio === undefined) {
    return 'Consultar precio';
  }

  return new Intl.NumberFormat('es-CR', {
    style: 'currency',
    currency: 'CRC',
    minimumFractionDigits: 0
  }).format(Number(precio));
}

/* =========================================================
   MODAL
========================================================= */

function abrirModal(producto) {
  const imagen = obtenerImagenPrincipal(producto);
  const categoria = obtenerCategoria(producto.categoria_id);

  if (imagen) {
    modalImage.src = obtenerUrlImagen(imagen.ruta);
    modalImage.alt = imagen.alt_text || producto.nombre;
  } else {
    modalImage.removeAttribute('src');
    modalImage.alt = '';
  }

  modalCategory.textContent = categoria ? categoria.nombre : '';
  modalTitle.textContent = producto.nombre;
  modalDescription.textContent = producto.descripcion || 'Sin descripción disponible.';
  modalPrice.textContent = formatearPrecio(producto.precio);

  productModal.classList.remove('hidden');
  productModal.setAttribute('aria-hidden', 'false');
  document.body.style.overflow = 'hidden';
}

/* =========================================================
   CERRAR MODAL
========================================================= */

function cerrarModal() {
  productModal.classList.add('hidden');
  productModal.setAttribute('aria-hidden', 'true');
  document.body.style.overflow = '';
}

/* =========================================================
   EVENTOS MODAL
========================================================= */

modalClose.addEventListener('click', cerrarModal);
modalOverlay.addEventListener('click', cerrarModal);

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    cerrarModal();
  }
});

/* =========================================================
   LOADING
========================================================= */

function mostrarLoading() {
  loading.classList.remove('hidden');
  productsGrid.innerHTML = '';
  errorMessage.classList.add('hidden');
}

function ocultarLoading() {
  loading.classList.add('hidden');
}

/* =========================================================
   ERROR
========================================================= */

function mostrarError(mensaje) {
  loading.classList.add('hidden');
  errorMessage.classList.remove('hidden');
  errorText.textContent = mensaje;
}

retryButton.addEventListener('click', async () => {
  errorMessage.classList.add('hidden');
  mostrarLoading();

  try {
    await cargarCategorias();
    await cargarProductos();
    ocultarLoading();
  } catch (error) {
    console.error(error);
    mostrarError(error.message);
  }
});
