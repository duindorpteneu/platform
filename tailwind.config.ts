import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#EEF4FD",
          100: "#DCE8F9",
          500: "#2E69CC",
          700: "#17418B",
          900: "#0B2E63",
        },
        ink: "#172033",
        canvas: "#F6F8FB",
        line: "#DDE3EC",
        success: "#17804A",
        warning: "#A85C05",
        danger: "#B42318",
      },
      boxShadow: {
        card: "0 1px 2px rgba(23, 32, 51, 0.04), 0 8px 24px rgba(23, 32, 51, 0.04)",
      },
      fontFamily: { sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"] },
    },
  },
  plugins: [],
};

export default config;
