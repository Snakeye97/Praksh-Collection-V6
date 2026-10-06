PRAKSH COLLECTION REWARDS — V6

WHAT V6 ADDS
- Keeps the existing Supabase customer/owner loyalty system.
- Customer optional profile: birthday, anniversary, gender and WhatsApp marketing consent.
- Lucky draws with title, prize, minimum purchase, start/end dates and weighted entries.
- Approved qualifying bills automatically earn draw entries.
- When a draw is created, already-approved bills inside the draw dates are also added.
- One-click owner winner selection and winner history.
- Promotions stored in Supabase and sent using approved WhatsApp Cloud API templates.
- WhatsApp bot commands: HI/HELP, POINTS and DRAW.
- WhatsApp inbound/outbound message logging.
- Promotion audiences: all opted-in customers, customers with available points, or VIP customers with at least ₹5,000 approved spend.
- Keeps the current loyalty formula: 5 points for every completed ₹100.
- Redemption remains minimum 100 points in multiples of 10; 1 point = ₹1 reward value.

IMPORTANT
- Do NOT use the old SQLite/Express project with this version.
- This is the Supabase version of the project.
- Never put the WhatsApp access token, app secret, service_role key or webhook verify token in supabase-config.js.

UPGRADE AN EXISTING V5 SITE
1. Back up your Supabase database.
2. In Supabase SQL Editor, run ONLY:
   upgrade-v6.sql
3. Deploy the two Edge Functions from this project:
   supabase functions deploy customer-api
   supabase functions deploy whatsapp-api
   The included supabase/config.toml disables platform JWT verification for these functions because customer-api uses its own session token and whatsapp-api must accept Meta webhook requests. Both functions perform their own authentication checks.
4. Upload the updated static website files to your host:
   index.html
   app.js
   common.js
   style.css
   owner-login.html
   owner-login.js
   owner.html
   owner.js
   supabase-config.js
5. Test customer login, bill submission, owner login and bill approval before connecting WhatsApp.

FRESH INSTALL
1. Create/open your Supabase project.
2. Run supabase-setup.sql in SQL Editor.
3. Run upgrade-v6.sql in SQL Editor.
4. Create the owner user in Authentication > Users.
5. Copy the owner user's UUID and run:
   insert into public.owner_users(user_id) values('YOUR-OWNER-UUID') on conflict do nothing;
6. Deploy customer-api and whatsapp-api.
7. Publish the static website files.

WHATSAPP CLOUD API SETUP
The WhatsApp integration uses Meta WhatsApp Cloud API.
Set these as Supabase Edge Function secrets, not website variables:

supabase secrets set WHATSAPP_ACCESS_TOKEN="YOUR_SYSTEM_USER_ACCESS_TOKEN"
supabase secrets set WHATSAPP_PHONE_NUMBER_ID="YOUR_PHONE_NUMBER_ID"
supabase secrets set WHATSAPP_VERIFY_TOKEN="CREATE_A_LONG_RANDOM_VERIFY_TOKEN"
supabase secrets set WHATSAPP_APP_SECRET="YOUR_META_APP_SECRET"
supabase secrets set WHATSAPP_GRAPH_VERSION="v26.0"
supabase secrets set WHATSAPP_DEFAULT_COUNTRY_CODE="91"

Use the Graph API version currently supported/shown for your Meta app. The code reads it from WHATSAPP_GRAPH_VERSION so you can change versions without editing JavaScript.

META WEBHOOK
After deploying whatsapp-api, your callback URL is:
https://YOUR-PROJECT-REF.supabase.co/functions/v1/whatsapp-api

In Meta Developer / WhatsApp configuration:
- Use the exact same WHATSAPP_VERIFY_TOKEN as the Verify Token.
- Subscribe to the messages webhook field.
- Keep WHATSAPP_APP_SECRET configured because V6 validates X-Hub-Signature-256 on incoming webhook POSTs.

PROMOTIONS
- Create/approve your WhatsApp message template in Meta first.
- Enter the exact approved template name in Owner Dashboard > WhatsApp Promotion.
- Customers must tick marketing consent before they are included.
- The current sender processes up to 100 eligible recipients per send request to keep Edge Function execution bounded.
- Templates in this V6 sender should not require dynamic body parameters. Parameterized templates can be added later.

LUCKY DRAW RULE USED BY V6
Entries = floor(approved bill amount / draw minimum purchase)
Example if minimum purchase is ₹999:
- ₹999 bill = 1 entry
- ₹1,998 bill = 2 entries
- ₹2,997 bill = 3 entries
The bill purchase date must be between the draw start and end date.

SECURITY
- Customer bill uploads remain private.
- Service role and WhatsApp secrets remain server-side in Edge Functions.
- Owner actions require Supabase Auth plus owner_users membership.
- Customer actions require the server-issued customer session token.
- WhatsApp webhook POSTs are checked using the Meta app secret signature.
- Promotional sends require customer marketing consent.

TEST ORDER
1. Customer login.
2. Submit a ₹100+ bill.
3. Owner approves bill and points appear.
4. Create a lucky draw with ₹999 minimum purchase.
5. Approve a qualifying bill and verify draw entries.
6. Pick a winner from Owner Dashboard.
7. Save a WhatsApp promotion.
8. Configure Meta secrets/webhook.
9. Send HI, POINTS and DRAW from a customer's WhatsApp number.
10. Send the approved promotional template to opted-in customers.

FILES
- supabase-setup.sql: original V5 database setup.
- upgrade-v6.sql: V6 upgrade. Run this on existing V5 databases.
- supabase/functions/customer-api/index.ts: customer login, profile, bills and redemption.
- supabase/functions/whatsapp-api/index.ts: Meta webhook, bot commands and promotion sending.
- supabase/config.toml: Edge Function JWT settings.
