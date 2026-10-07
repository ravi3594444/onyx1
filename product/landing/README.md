# 22nd X AI Knowledge landing page

This folder contains the landing page from the requested landing design.
It is a standalone React and Vite frontend. It builds to static files.
The Onyx application, deployment scripts, image pins, and database are unchanged.

## Design and contents

- Uses the logo, Manrope font, pixel font, and blue accent from AXI Solutions.
- Uses the supplied Halftone Nebula WebGL template for the animated hero.
- Includes company knowledge headlines, responsive layouts, and a motion control.
- Includes three sample questions, source previews, team tabs, and FAQ panels.
- Links signup and login to the existing application.
- Labels sample companies, questions, and documents as illustrative content.

The template keeps its shader, pointer effects, visibility controls, and reduced-motion support.
Its layout classes use local CSS, which removes the need for Tailwind.
Its fallback image uses the selected brand colours when WebGL is unavailable.
Fonts and the logo are local assets. Font licence files are included.

## Build

Use Node.js 22.13 or later. From this folder, run:

```sh
npm ci
npm run build
```

The build runs TypeScript checks and writes the static site to `dist/`.
Use `npm run dev` for development or `npm run preview` to review the build.

## Public configuration

These values are compiled into the frontend. They must contain no secrets.
See `.env.example` for the defaults.

| Variable                 | Purpose                             | Default                            |
| ------------------------ | ----------------------------------- | ---------------------------------- |
| `VITE_APP_URL`           | Base URL for signup and login links | `https://my-knowledge.duckdns.org` |
| `VITE_LANDING_BASE_PATH` | URL prefix for landing assets       | `/`                                |

Set `VITE_APP_URL` to the application origin, without a route or trailing slash.
Use a trailing slash for the asset prefix.

For a landing page on the existing application origin:

```sh
VITE_APP_URL=https://my-knowledge.duckdns.org \
VITE_LANDING_BASE_PATH=/_landing/ npm run build
```

Serve `dist/index.html` at the exact root URL `/`.
Serve the other files in `dist/` under `/_landing/`.
Keep the existing Onyx routes on their current proxy.
Do not route authentication, API requests, or application assets to the landing site.

For a separate marketing hostname, build with the default `/` asset prefix.
Keep `VITE_APP_URL` pointed at the application hostname.

## Handoff to the deployment agent

The user assigned VM deployment to the existing agent.
This PR supplies the frontend source and build instructions.
It does not change the active stack or pin a new application image.

1. Review this PR and run `npm ci` and `npm run build`.
2. Check the design in desktop and phone browsers before changing public routing.
3. Build the landing files with the asset prefix selected for the public route.
4. Serve the files through the existing proxy or a dedicated static frontend image.
5. Keep company data, application authentication, and API routing in the existing Onyx stack.
6. Check signup, login, and the actual application entry route after the proxy change.
7. Verify chat, uploads, citations, and invitations still work after deployment.

## Verification

The handoff report records the checks run before this PR.
The original hosted design passed its build and TypeScript checks.
Browser layout checks and VM deployment checks require the deployment agent.
