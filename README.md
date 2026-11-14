# PledgePilot

Multi-shop pawn-broking web application with an Android build. Uses Supabase Auth, Postgres and private Storage.

## Run the web app

Install Node.js 22 or later. Copy .env.example to .env.local and set the public Supabase key for project pwuukmjlojxcfbgryolm. Then run:

```sh
npm ci
npm run dev
```

Run npm run build and host the dist directory over HTTPS for browser access. Serve all generated HTML files. Sign-in, owner, staff, customers, pledges, releases, audit, accounting, and reports each have their own page and URL.

## Provision Supabase

Use the Supabase CLI under an account with deployment access to the requested project.

```sh
supabase login
supabase link --project-ref pwuukmjlojxcfbgryolm
supabase db push
supabase functions deploy create-staff --project-ref pwuukmjlojxcfbgryolm
```

In Supabase Authentication, create and confirm the initial platform owner with the internal email `vasavinexus@sivajewel.example.com` and set its password there. Then use the SQL Editor with that user's UUID:

```sql
insert into public.owners (user_id) values ('REPLACE_WITH_AUTH_USER_UUID');
```

Sign in with username `vasavinexus` and the password set in Supabase, create a shop, select it and create its shop administrator. The administrator can create staff and configure page access. Pausing a shop blocks shop data access at the database and storage layers. All accounts sign in with usernames and passwords. Usernames are case-insensitive and unique across shops. Supabase Auth stores them internally as `username@sivajewel.example.com`. These addresses are placeholders, so email-based password recovery is unavailable. Set initial staff credentials from the staff page.

## Build Android

Install Android Studio with SDK 35 and use JDK 21. From the project root run npm run android to refresh the Android assets, then open the android directory in Android Studio or run the Gradle wrapper with assembleDebug. Android supports taking photos with the device camera. The desktop browser uses file attachments.

## Release and accounts

Interest uses simple monthly interest. A partial calendar month rounds up, same-day release defaults to zero months, and a month-end anniversary uses the last valid day of that month. The database saves original and applied months and rates. Submitting an audit review removes the release from the pending queue while preserving the review timestamp and reviewer.

Supabase filters customer and open-loan searches, customer history, pending release reviews, and date-based reports. Release quotes and accounting totals are calculated in the database. Transaction tables load 50 rows at a time.

The accounting screens use INR and a fixed chart of accounts. Pledges and releases generate ledger entries. Post opening capital and balances, other income and expenses through Accounting. Profit and loss uses realized interest. Balance sheet and trial balance are cumulative through the report date.

Photo cleanup runs hourly. Set the Vault secret `siva_jewel_photo_cleanup_url`
in each Supabase project to its HTTPS `/functions/v1/expire-jewel-photos`
endpoint. The scheduler sends no request until this secret is configured.
