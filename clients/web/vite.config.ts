import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// In dev, forward API calls to the Rust server so the app stays same-origin.
const server = process.env.ZERO_SUM_SERVER ?? "http://127.0.0.1:8787";

export default defineConfig({
  plugins: [preact()],
  server: {
    proxy: {
      "/sync": { target: server, ws: true },
      "/budget": server,
      "/health": server,
    },
  },
});
