"use client";

import { useState, useEffect } from "react";

const LANG_KEY = "vllm-recipes-lang";

function getInitialLang() {
  if (typeof window === "undefined") return "en";
  try {
    return localStorage.getItem(LANG_KEY) || "en";
  } catch {
    return "en";
  }
}

export function useLang() {
  const [lang, setLang] = useState("en");

  useEffect(() => {
    setLang(getInitialLang());
    const handler = () => setLang(getInitialLang());
    window.addEventListener("langchange", handler);
    return () => window.removeEventListener("langchange", handler);
  }, []);

  return lang;
}

export function LanguageToggle({ className = "" }) {
  const [lang, setLang] = useState("en");

  useEffect(() => {
    setLang(getInitialLang());
  }, []);

  const toggle = () => {
    const next = lang === "zh" ? "en" : "zh";
    try {
      localStorage.setItem(LANG_KEY, next);
    } catch {
      // localStorage unavailable
    }
    setLang(next);
    window.dispatchEvent(new CustomEvent("langchange"));
  };

  return (
    <button
      onClick={toggle}
      className={`inline-flex items-center gap-1 rounded-md border border-border px-2.5 py-1 text-xs font-medium transition-colors hover:border-vllm-blue/50 hover:text-vllm-blue ${className}`}
      aria-label="Toggle language"
    >
      {lang === "zh" ? "EN" : "中文"}
    </button>
  );
}
