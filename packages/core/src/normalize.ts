import type { InformationItemInput, NormalizedItem } from "./item";

const TRACKING = /^(utm_|fbclid$|gclid$|mc_cid$|mc_eid$|ref$|ref_src$|igshid$|yclid$|_hsenc$|_hsmi$)/i;
export const MAX_CONTENT_CHARS = 8000;

/** Canonical URL: lowercase host, no fragment/tracking params/trailing slash/default ports, sorted query. */
export function canonicalUrl(raw: string): string {
  const u = new URL(raw);
  u.hash = "";
  u.hostname = u.hostname.toLowerCase().replace(/^www\./, "");
  if ((u.protocol === "https:" && u.port === "443") || (u.protocol === "http:" && u.port === "80")) u.port = "";
  const kept = [...u.searchParams.entries()].filter(([k]) => !TRACKING.test(k)).sort(([a], [b]) => a.localeCompare(b));
  u.search = "";
  for (const [k, v] of kept) u.searchParams.append(k, v);
  if (u.pathname.length > 1) u.pathname = u.pathname.replace(/\/+$/, "");
  return u.toString();
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<\/(p|div|li|h[1-6]|br)>|<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (m, e: string) => {
      if (e[0] === "#") {
        const cp = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        return Number.isFinite(cp) && cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
      }
      return ENTITIES[e.toLowerCase()] ?? m;
    })
    .replace(/[ \t\f\v ]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .trim();
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Normalization key for near-identical titles/bodies (case, punctuation, whitespace-insensitive). */
export function normalizeForHash(s: string): string {
  return s.toLowerCase().normalize("NFKD").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

export async function normalizeItem(input: InformationItemInput): Promise<NormalizedItem> {
  const url = canonicalUrl(input.url);
  const content = input.content ? htmlToText(input.content).slice(0, MAX_CONTENT_CHARS) : null;
  const published = input.published_at ? new Date(input.published_at) : null;
  const title = htmlToText(input.title);
  return {
    ...input,
    title,
    url,
    content,
    published_at: published && !Number.isNaN(+published) ? published.toISOString() : null,
    url_hash: await sha256Hex(url),
    content_hash: await sha256Hex(normalizeForHash(title + " " + (content ?? "").slice(0, 2000))),
  };
}

/** Trigram Jaccard similarity of two titles (0..1) — v1 story clustering signal. */
export function titleSimilarity(a: string, b: string): number {
  const grams = (s: string) => {
    const t = `  ${normalizeForHash(s)} `;
    const set = new Set<string>();
    for (let i = 0; i < t.length - 2; i++) set.add(t.slice(i, i + 3));
    return set;
  };
  const A = grams(a), B = grams(b);
  let inter = 0;
  for (const g of A) if (B.has(g)) inter++;
  const union = A.size + B.size - inter;
  return union === 0 ? 0 : inter / union;
}
