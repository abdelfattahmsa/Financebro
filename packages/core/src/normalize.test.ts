import { describe, expect, it } from "vitest";
import { canonicalUrl, htmlToText, normalizeItem, titleSimilarity, InformationItemInput } from "./index";

describe("canonicalUrl", () => {
  it("strips tracking, fragment, www, trailing slash and sorts params", () => {
    expect(canonicalUrl("https://www.Example.com/a/b/?utm_source=x&b=2&a=1#frag")).toBe("https://example.com/a/b?a=1&b=2");
  });
});

describe("htmlToText", () => {
  it("removes tags/scripts and decodes entities", () => {
    expect(htmlToText("<p>Hello &amp; <b>world</b></p><script>x()</script>&#8217;")).toBe("Hello & world\n’");
  });
});

describe("normalizeItem", () => {
  const base = { source: "a.com", source_type: "rss" as const, title: "Big News!", url: "https://a.com/x?utm_medium=y" };
  it("produces identical hashes for tracking-param variants", async () => {
    const a = await normalizeItem(InformationItemInput.parse(base));
    const b = await normalizeItem(InformationItemInput.parse({ ...base, url: "https://www.a.com/x/" }));
    expect(a.url_hash).toBe(b.url_hash);
    expect(a.content_hash).toBe(b.content_hash);
  });
  it("rejects invalid country codes", () => {
    expect(() => InformationItemInput.parse({ ...base, country: "EGY" })).toThrow();
  });
});

describe("titleSimilarity", () => {
  it("scores same-event headlines above unrelated ones", () => {
    const s1 = titleSimilarity("EU announces major new AI regulation", "EU unveils major new AI regulation rules");
    const s2 = titleSimilarity("EU announces major new AI regulation", "Gold prices slip as dollar firms");
    expect(s1).toBeGreaterThan(0.4);
    expect(s2).toBeLessThan(0.2);
  });
});
