# Source verification — 7 October 2026

| Check | Result |
| --- | --- |
| Install from the npm lockfile | PASS |
| Strict TypeScript check | PASS |
| Production Vite build | PASS |
| Source formatting check | PASS |
| Built HTML uses the selected `/_landing/` asset prefix | PASS |
| Built HTML points to existing logo, JavaScript, and CSS files | PASS |
| Runtime dependencies match the npm lockfile | PASS |
| Original vertex and fragment shader source retained | PASS |
| Desktop and phone browser review | NOT VERIFIED |
| Public VM integration | NOT DEPLOYED |

The production build produced about 242 kB of JavaScript and 35 kB of CSS.
Their compressed sizes were about 76 kB and 8.5 kB.
The two local font files total about 53 kB.

The GitHub workflow repeats dependency installation, TypeScript checks, and the production build.
It uploads the static files as `axi-landing-dist`.
It has no deploy step and uses no VM secrets.
