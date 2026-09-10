# ⚠️ Map layers: switch before commercial launch

## What's active now (testing)

The dashboard map defaults to **Google satellite tiles** pulled from
`mt1.google.com`. No API key, no billing, zoom to level 21, best
imagery available anywhere.

This is fine while you're testing on `github.io` with five tags.

## Why it can't stay

Google's Terms of Service require their map tiles be served through the
Maps JavaScript API. The `mt1.google.com` tile endpoint is undocumented
and unlicensed. Practical consequences:

- Google can block or change it any day, with no notice and no recourse.
  Your customers' maps break and you have no support channel.
- Using it in a product you charge money for is a licensing exposure.
  It is the kind of thing that surfaces during due diligence, not before.
- There is no contract, so there is no uptime commitment.

While a Google test layer is selected the map shows an amber badge in
the top-left corner. That is deliberate — so this never gets demoed to
an investor or shipped to a customer unnoticed.

## How to switch (two minutes)

1. Open `config.js`.
2. Set `const USE_GOOGLE_TILES_TESTING = false;`
3. Pick a replacement:

   **Option A — free forever, no account (recommended to start)**
   Do nothing else. The map falls back to Sentinel-2 (ESA open data via
   EOX): ~10m resolution, CC BY 4.0, commercial use fine, no key, no
   quota, no card. Zooms to 19 via upscaling. Enough to read terrain,
   rivers and grazing ground.

   **Option B — high resolution, free tier**
   Sign up at mapbox.com, copy the default public token (starts `pk.`),
   paste it into `MAPBOX_TOKEN` in `config.js`. 50,000 map loads/month
   free, no credit card to start, commercial use permitted, sub-meter
   imagery in many areas. Restrict the token to your domain in the
   Mapbox dashboard.

   **Option C — Google, properly licensed**
   Google Cloud → enable Maps JavaScript API → create a key → billing
   account required even for the free tier. 10,000 free map loads/month,
   then $7 per 1,000. The old $200 credit was scrapped in March 2025.
   Set a budget alert and a quota cap the same day you enable it.

4. Push. Nothing else in the app changes — the pins, filters and
   popups are all layer-independent.

## What is NOT affected

Plain `google.com/maps?q=lat,lng` links (used in the table, map popups,
the cow page and the public tap page) are ordinary URLs, not the Maps
API. They cost nothing, need no key, work forever, and open the Google
Maps app with navigation on a phone. Keep them.
