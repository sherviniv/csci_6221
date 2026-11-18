import "./globals.css";
import type { ReactNode } from "react";

export const metadata = {
  title: "Crystal Proxy Lab",
  description: "Live dashboard for a least-connections reverse proxy written in Crystal",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
