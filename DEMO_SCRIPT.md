# YAK-TAG — demo script

Five minutes, in person, with a tag in your pocket.

The single most persuasive thing you have is **the tap**. It takes four
seconds, needs no explanation, and works on a phone the prospect already
owns. Everything else in the demo exists to frame that moment.

---

## Before you walk in

- [ ] Tags YT-008000 to YT-008004 written and tap-tested that morning
- [ ] Your own phone logged in as `bat@yaktag.test`, screen unlocked
- [ ] A laptop or second phone logged in as `admin12@yaktag.test`
- [ ] One tag loose in your pocket to hand over
- [ ] Mobile data on — the site is live, not local

Test one tap before the meeting starts. GitHub Pages occasionally takes
a minute after a push, and a dead tap in the first thirty seconds costs
you the room.

---

## 1. Hand them the tag first (30 seconds)

Don't open a laptop. Don't open slides. Give them the physical tag and
say:

> "Hold your phone near this."

They tap. A cow's page opens in their browser. Let the silence sit for a
moment — the thing that lands is that *they* did it, on *their* phone,
with no app.

Then, only once they've seen it:

> "That's a real animal in a real database. No app, no scanner, no
> subscription on their side. Any phone made in the last eight years
> can do that."

**If the tap fails** (older phone, NFC off, iPhone with NFC disabled in
some regions): don't fight it. Open `cow.html?tag=YT-008000` in their
browser instead and say "same page, this is what the tap opens." Never
spend more than fifteen seconds troubleshooting a tap.

---

## 2. Show what the herder does (60 seconds)

Still on their phone, on the cow page:

- Point at **today's milk** — "the herder types one number a day"
- Tap **the camera button** — take an actual photo of whatever's in the
  room. Show it appear, locked, with a GPS reading.
- Say: *"That photo can never be edited or deleted, not by the herder,
  not by the farm. Only the system administrator, and even then it's
  logged."*

That immutability is the part that makes buyers lean in — it's the
difference between a record-keeping app and evidence.

---

## 3. Show what the owner sees (90 seconds)

Now open the laptop, `admin12@yaktag.test`:

- **All animals in one table.** Milk today, milk this month, last fed,
  vaccination due, last known location.
- Point at the cow they just photographed — it's already there.
- Filter by **"Өнөөдөр бүртгэгдээгүй"** — "these are the animals nobody
  logged today. That's your morning check, thirty seconds."

Then the part that closes it:

- Log out. Log in as `admin07@yaktag.test`.
- Same screen, completely different animals.
- *"Farm 7 cannot see Farm 12's animals. Not by policy — the database
  physically refuses. We tested that before we built anything else."*

---

## 4. Be honest about the stage (30 seconds)

Say this before they ask. It buys more credibility than any feature:

> "Right now this is five tags on one farm. The tag hardware works, the
> phone flow works, the isolation works. What we haven't built yet is
> the self-service admin — creating farms and users still goes through
> us. That's next.
>
> We're looking for one farm to run 10 to 20 animals for a season and
> tell us what breaks."

Prospects trust a small honest number more than a large vague one. The
website says the same thing, so nothing contradicts you if they browse
it later.

---

## 5. What to ask for

Not a purchase. A pilot:

- 10–20 animals, one season
- They provide the animals and a herder willing to try it
- You provide tags, setup, and support
- In exchange: honest feedback about what fails in real conditions

---

## Questions you will get

**"What if the tag falls off or gets damaged?"**
Tags are replaceable. The animal's history lives in the database, not on
the tag — we write a new tag, link it to the same animal, and nothing is
lost. There's a documented retire/recycle process for exactly this.

**"What if someone swaps tags between animals?"**
That's what the locked photos are for. The muzzle print is unique per
animal, like a fingerprint, and once photographed it can't be altered.
A swapped tag stops matching its photo.

**"Does it work without mobile signal?"**
The tap works offline — the tag is passive, no network needed to read
it. The current web version needs signal to load the page; offline entry
with automatic sync is on the roadmap and the database is already built
for it (every scan carries a client-generated ID so retries never
duplicate).

**"How much?"**
Don't invent a number. "Pilot is free — we want the feedback. Pricing
after we know what it actually costs to support a farm."

**"Can I see the code?"**
Yes, it's on GitHub. Openness helps here.

---

## What not to do

- Don't demo the marketing site first. Tap first, site later, if at all.
- Don't claim RFID/long-range works yet. It doesn't. NFC only.
- Don't quote the 12,000-animal figure as if it's current. It's a phase 4
  target and the site labels it that way.
- Don't show the Supabase dashboard. It looks like a construction site
  and invites questions you don't need.
