import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#EEF4FD",
          100: "#DCE8F9",
          500: "rgb(var(--brand-500-rgb, 46 105 204) / <alpha-value>)",
          700: "rgb(var(--brand-700-rgb, 23 65 139) / <alpha-value>)",
          900: "rgb(var(--brand-900-rgb, 11 46 99) / <alpha-value>)",
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
