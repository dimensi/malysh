import { defineConfig } from "vite-plus";

export default defineConfig({
  build: {
    assetsInlineLimit: 0,
    rolldownOptions: {
      input: ["index.html", "support.html", "privacy.html"],
    },
  },
});
