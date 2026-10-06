import { defineConfig } from "vite";

export default defineConfig({
  build: { outDir: "builds/frontend" },
  clearScreen: false,
  server: {
    host: "127.0.0.1",
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/builds/**"] },
  },
});
