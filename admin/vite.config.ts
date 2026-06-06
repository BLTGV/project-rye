import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

const UI_PORT = Number(process.env.RYE_ADMIN_UI_PORT ?? 5180);
const API_PORT = Number(process.env.RYE_ADMIN_API_PORT ?? 8799);

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "~": path.resolve(__dirname, "src"),
      "~client": path.resolve(__dirname, "src/client"),
      "~server": path.resolve(__dirname, "src/server"),
    },
  },
  build: {
    outDir: "dist/client",
    emptyOutDir: true,
    rollupOptions: {
      input: path.resolve(__dirname, "index.html"),
    },
  },
  server: {
    // Bind all interfaces so the admin is reachable via the `omarchy` hostname
    // from another machine. Local admin development uses fixed default ports:
    // 5180 for Vite UI and 8799 for the Node API runner.
    host: true,
    port: UI_PORT,
    strictPort: true,
    // Trusted personal box reached by hostname (omarchy), LAN IP, and tailnet.
    // Allow any Host header so those all work; safe for a private dev network.
    allowedHosts: true,
    proxy: {
      "/api": `http://127.0.0.1:${API_PORT}`,
    },
  },
});
