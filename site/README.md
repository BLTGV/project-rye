# Rye UI Showcase

Single-page static website that showcases Rye design tokens and core components with light/dark mode.

## Run locally

From project root:

```bash
python3 -m http.server 8080
```

Open `http://localhost:8080/site/`.

## Deploy anywhere

This site is static (`index.html`, `styles.css`, `script.js`) and can be hosted on:

- Cloudflare Pages or Workers static assets
- Netlify
- Vercel
- S3 + CloudFront
- GitHub Pages

No Cloudflare-specific runtime APIs are required.
