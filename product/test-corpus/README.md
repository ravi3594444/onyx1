# Test corpus

Synthetic documents for the functional checks in `docs/product/PRD.md`.
They contain no real customer or employee data.

Upload only the files in `documents/`. Do not upload this README.

| File | Purpose | Access |
| --- | --- | --- |
| `expense-policy.md` | Short policy | All users |
| `whatsapp-assistant-product-guide.md` | Product guide; changed during the update check | All users |
| `refund-policy-2025.md` | Older version of a conflicting pair; removed during the deletion check | All users |
| `refund-policy-2026.md` | Newer version of a conflicting pair | All users |
| `hr-salary-bands-restricted.md` | Restricted document | HR group only |

## Expected evidence

A check passes only when the answer states the expected fact and cites the expected file.
A fluent answer without the expected citation does not pass.

| ID | Question | Expected fact | Expected source |
| --- | --- | --- | --- |
| Q1 | What is the daily meal allowance for domestic business travel? | INR 1,500 per day | `expense-policy.md` |
| Q2 | What are the support hours for WhatsApp Assistant? | Monday to Saturday, 09:00 to 19:00 IST | `whatsapp-assistant-product-guide.md` |
| Q3 | How many days does a customer have to request a full refund? | 30 days (2026 edition replaces the 14-day 2025 edition) | `refund-policy-2026.md`; a mention of the 2025 edition is acceptable only if it is identified as replaced |
| Q4 | What is the parental leave policy? | No document has this information. The answer must say so and must not invent a policy. | None |
| Q5 | What is the salary band for a Senior Software Engineer at level L4? | HR user: 38 to 46 lakh. Other users: no answer, and no `KESTREL-7731` marker in any result. | `hr-salary-bands-restricted.md` (HR user only) |

## Update and deletion checks

| ID | Change | Expected result after the connector sync |
| --- | --- | --- |
| U1 | In `whatsapp-assistant-product-guide.md`, set the support hours to "Monday to Friday, 10:00 to 18:00 IST" and the guide version to 2.4. | Q2 returns the new hours. |
| D1 | Remove `refund-policy-2025.md` from the source. | No search result shows the 2025 edition. Q3 cites only the 2026 edition. |
