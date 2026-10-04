# Browser evidence, multi-tenant stack (4 October 2026)

Taken by `.github/workflows/axi-ui-evidence.yml` (mode `saas`, run 2) with Playwright on a
GitHub runner against https://my-knowledge.duckdns.org. Images: backend
`v4.8.4-axi.2@sha256:987abe7c…`, web `v4.8.4-axi-cloud.5@sha256:817ba99e…`.
The accounts are synthetic `@example.com` companies that the script signs up through the
web form. The script sets up no model and no assistant prompt.

| File | What it shows |
| --- | --- |
| `01-login.png`, `01b-login-phone.png`, `02-signup.png` | Branded sign-in and sign-up, phone width without horizontal scroll |
| `03-company-a-home.png` | First page after the sign-up of company A: no dialog, the platform model selected |
| `04-company-a-account-menu.png` | Account menu with the branded version line |
| `05-company-a-admin-users.png`, `06-company-a-invite.png` | Owner is admin; invitation of member A |
| `07-company-a-llm.png` | Platform provider "22nd X AI model" is the default; no key text |
| `08-company-a-chat.png` | Chat answers with the platform model |
| `09-company-b-home.png`, `10-company-b-admin-users.png` | Company B sees only its own users |
| `12-member-a-home.png`, `13-member-a-admin-blocked.png` | Invited member joins company A and has no admin panel |
| `14-company-a-users-after.png` | Company A lists the owner (Admin) and the member (Basic) |
| `ui_evidence.log` | PASS/INFO lines of the run |
