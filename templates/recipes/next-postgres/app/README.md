# app/ — Next.js source lives here

This directory is intentionally a stub. Replace with your Next.js app
(or `npx create-next-app@latest .` inside this directory). The supplied
`Dockerfile` expects:

- `package.json` with `build` producing `.next/standalone`
- Set `output: 'standalone'` in `next.config.js`
- A `GET /api/health` route that returns 200 (used by the healthcheck)

Example `next.config.js`:

```js
module.exports = {
  output: 'standalone',
}
```
