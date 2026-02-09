function isNil (value) {
  return value === null || value === undefined;
}

export function toInt (value, fallback) {
  const n = Number.parseInt(String(isNil(value) ? '' : value), 10);
  return Number.isFinite(n) ? n : fallback;
}

export function normalizeBaseUrl (raw) {
  const trimmed = String(isNil(raw) ? '' : raw).trim();
  if (!trimmed) {
    return '';
  }
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  return `http://${trimmed}`;
}

export function joinUrl (baseUrl, path) {
  const base = String(baseUrl).replace(/\/$/, '');
  const p = String(isNil(path) ? '/' : path);
  const normalizedPath = p.startsWith('/') ? p : `/${p}`;
  return `${base}${normalizedPath}`;
}
