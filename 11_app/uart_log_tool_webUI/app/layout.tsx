import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "UART Log Workbench",
  description: "Local web workbench for UART log viewing and device control.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}