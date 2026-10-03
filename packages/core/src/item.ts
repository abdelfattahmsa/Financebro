import { z } from "zod";

export const SOURCE_TYPES = ["rss", "atom", "jsonfeed", "api", "scraper", "rsshub", "gov", "company", "social", "manual"] as const;

/** The single contract every source (feeds, APIs, your own scrapers) must produce. */
export const InformationItemInput = z.object({
  source: z.string().min(1),                 // domain or source name, e.g. "reuters.com"
  source_type: z.enum(SOURCE_TYPES),
  title: z.string().min(1),
  url: z.string().url(),
  published_at: z.string().datetime({ offset: true }).nullish(),
  author: z.string().nullish(),
  content: z.string().nullish(),             // plain text or HTML; normalized on ingest
  image: z.string().url().nullish(),
  topics: z.array(z.string()).default([]),   // hints only; classification is re-derived server-side
  entities: z.array(z.string()).default([]),
  country: z.string().length(2).nullish(),   // ISO 3166-1 alpha-2
  language: z.string().min(2).max(8).nullish(),
});
export type InformationItemInput = z.infer<typeof InformationItemInput>;

/** POST /ingest body for your own scrapers. */
export const IngestBatch = z.object({ items: z.array(InformationItemInput).min(1).max(500) });
export type IngestBatch = z.infer<typeof IngestBatch>;

export interface NormalizedItem extends Omit<InformationItemInput, "content" | "published_at"> {
  content: string | null;
  published_at: string | null;
  url_hash: string;
  content_hash: string;
}
