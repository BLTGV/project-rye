import { defineConfig } from "astro/config";
import cloudflare from "@astrojs/cloudflare";
import tailwindcss from "@tailwindcss/vite";
import remarkGfm from "remark-gfm";

export default defineConfig({
  site: "https://projectrye.dev",
  output: "server",
  adapter: cloudflare({
    imageService: "compile",
  }),
  markdown: {
    remarkPlugins: [remarkGfm],
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
