import { resolve } from 'node:path';
import { defineConfig } from 'vite';

const pages = ['index','owner','unassigned','admin','customers','loans','release','audit','accounting','journal','balances','reports'];

export default defineConfig({
  base: './',
  build: {
    rollupOptions: {
      input: Object.fromEntries(pages.map(page => [page, resolve(import.meta.dirname, page+'.html')]))
    }
  }
});
