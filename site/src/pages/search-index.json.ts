import { getCollection } from "astro:content";
import { sectionFromSlug, SECTION_TITLES, titleFromEntry } from "../lib/docs";
import { stripMarkdown, summarize } from "../lib/text";

export const prerender = true;

export async function GET() {
  const entries = await getCollection("docs");

  const payload = entries.map((entry) => {
    const sectionId = entry.data.section ?? sectionFromSlug(entry.slug);
    const section = SECTION_TITLES[sectionId] ?? sectionId;
    const body = stripMarkdown(entry.body);

    return {
      slug: entry.slug,
      url: `/docs/${entry.slug}/`,
      title: titleFromEntry(entry),
      section,
      excerpt: summarize(body, 180),
      body,
    };
  });

  return new Response(JSON.stringify(payload), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=3600",
    },
  });
}
