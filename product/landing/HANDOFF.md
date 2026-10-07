# Deployment handoff

## Requirement

Publish this landing page for the 22nd X AI company knowledge product.
Keep the existing Onyx application and customer data in place.

## Source

The complete source is in `product/landing`.
Run the build commands in `README.md` from that folder.
There are no model keys, passwords, or server credentials in this frontend.

## Route checks

The landing page must load without application login.
Its signup button must open `/auth/signup` on the application origin.
Its login button must open `/auth/login` on the application origin.
Verify the application entry route from the pinned Onyx release.
The current fork and the pinned release can have different route names.

When using the same hostname, reserve `/_landing/` for landing assets.
Serve the landing HTML only for the exact `/` route.
Use the current Onyx proxy for every application and API route.
Use `VITE_APP_URL` if the application hostname changes.

## Browser checks

- At 390 px and 1440 px, check text, buttons, and horizontal overflow.
- Open and close the mobile navigation.
- Select all three example questions and open each source preview.
- Close a source with its button, Escape, and a click outside the dialog.
- Select each team tab and expand the FAQ answers.
- Pause and resume the hero animation.
- Check reduced-motion mode and a browser without WebGL.
- Confirm all logo and font assets load from the selected URL prefix.

## Deployment evidence

Record the deployed commit and the static build or image identity.
Save desktop and phone screenshots of the public landing page.
Report the signup, login, chat, upload, citation, and invitation results.
Record missing evidence or failed checks as incomplete work.

This PR does not start a VM deploy or change the release image pins.
