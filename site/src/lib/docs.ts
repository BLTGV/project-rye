import type { CollectionEntry } from "astro:content";

export type DocEntry = CollectionEntry<"docs">;

export type NavItem = {
  slug: string;
  url: string;
  title: string;
  description?: string;
};

export type NavSection = {
  id: string;
  title: string;
  items: NavItem[];
};

const SECTION_ORDER = ["getting-started", "reference", "model", "layers", "cookbooks"];

export const SECTION_TITLES: Record<string, string> = {
  "getting-started": "Getting Started",
  reference: "Reference",
  model: "Model",
  layers: "Layers",
  cookbooks: "Cookbooks",
};

const DOCUMENT_ORDER: Record<string, string[]> = {
  "getting-started": ["installation", "quickstart"],
  reference: ["core-contract", "data-dictionary", "agent-ops-guide", "conventions-catalog"],
  model: ["overview", "schema", "functions", "integration", "security", "core-contract-and-conformance"],
  layers: ["crm", "pm"],
  cookbooks: [
    "saas-customer-operations",
    "recruiting-pipeline",
    "product-development",
    "mineral-rights",
  ],
};

export function sectionFromSlug(slug: string): string {
  return slug.split("/")[0] ?? "reference";
}

export function titleFromSlug(slug: string): string {
  const lastSegment = slug.split("/").pop() ?? slug;
  return lastSegment
    .replace(/-/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

export function titleFromEntry(entry: DocEntry): string {
  return entry.data.title?.trim() || titleFromSlug(entry.slug);
}

function sortEntries(section: string, entries: DocEntry[]): DocEntry[] {
  const preferred = DOCUMENT_ORDER[section] ?? [];
  const rank = new Map(preferred.map((name, idx) => [name, idx]));

  return entries.sort((a, b) => {
    const aName = a.slug.split("/").pop() ?? a.slug;
    const bName = b.slug.split("/").pop() ?? b.slug;

    const aRank = rank.get(aName);
    const bRank = rank.get(bName);

    if (aRank !== undefined && bRank !== undefined) {
      return aRank - bRank;
    }

    if (aRank !== undefined) {
      return -1;
    }

    if (bRank !== undefined) {
      return 1;
    }

    return titleFromEntry(a).localeCompare(titleFromEntry(b));
  });
}

export function buildNavigation(entries: DocEntry[]): NavSection[] {
  const grouped = new Map<string, DocEntry[]>();

  for (const entry of entries) {
    const section = entry.data.section ?? sectionFromSlug(entry.slug);
    const existing = grouped.get(section) ?? [];
    existing.push(entry);
    grouped.set(section, existing);
  }

  const sectionIds = [...grouped.keys()].sort((a, b) => {
    const aOrder = SECTION_ORDER.indexOf(a);
    const bOrder = SECTION_ORDER.indexOf(b);

    if (aOrder !== -1 && bOrder !== -1) return aOrder - bOrder;
    if (aOrder !== -1) return -1;
    if (bOrder !== -1) return 1;

    return a.localeCompare(b);
  });

  return sectionIds.map((section) => {
    const items = sortEntries(section, grouped.get(section) ?? []);

    return {
      id: section,
      title: SECTION_TITLES[section] ?? titleFromSlug(section),
      items: items.map((entry) => ({
        slug: entry.slug,
        url: `/docs/${entry.slug}/`,
        title: titleFromEntry(entry),
        description: entry.data.description,
      })),
    };
  });
}
