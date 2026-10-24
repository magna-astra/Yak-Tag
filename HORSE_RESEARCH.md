# Horses — research notes (2026-10-24)

Collected before designing the horse version. Facts with a source link; **[unconfirmed]** = not checked against a primary source. Not on the website (`_config.yml` keeps `*.md` off yaktag.org).

## 1. Mongolian rules that matter

- **Minister's Order А/405 "Малын бүртгэлийн журам"** (2022, annex 2023) — https://faolex.fao.org/docs/pdf/mon224605.pdf · code list https://legalinfo.mn/mn/detail?lawId=16760156064861
  - Horses are identified by the **traditional brand (тамга) + a coded chip** (2.8.1); the brand image goes into the database (2.8.2); foals marked at 5 months (2.8.4).
  - National ID = **"MGL" + 10 digits**, issued by the national database (2.6); used on ownership, insurance, sale and movement papers (2.12). Lost tag replaced within 30 days.
- **Law on Livestock Genetic Resources** (2017) — every animal marked with a unique number and registered; export permits list each ID. https://legalinfo.mn/mn/detail/13051
- **Law on Animal Health** (2017) — owners mark and register (7.4.1); no vet certificate (7.5.5) and no leaving the soum (7.12.2) if unmarked. https://legalinfo.mn/mn/detail/13026
- **Law on Combating Livestock Theft** (2004, amended 2022) — brand (им тамга) + coat-colour records for large stock (7.1); a **sale/transfer needs a contract listing each animal: type, age, sex, brand** (9.1–9.3); origin certificate from the soum/bag governor. https://legalinfo.mn/mn/detail/313
- **National register:** "Малын үндэсний бүртгэл мэдээллийн нэгдсэн сан" — https://livestock.mofa.gov.mn (Digitalmedik LLC, 2021 tender). YAK-TAG complements it; it is the legal register.
- **Chips:** AIRS / national system uses ISO 11784/11785 FDX-B, **134.2 kHz — phone NFC (13.56 MHz) cannot read them**; a Bluetooth reader is needed ($24–120). https://ikon.mn/n/2cj9 · https://store.animal-id.net/catalog/scanners-us/946
- Breeding-horse/embryo import quota = 0 for 2026–2036; parliament asks for lineage evaluation and a breeding-horse database. https://eguur.mn/651279/

## 2. Theft (the clearest gap)

- 1,992 livestock-theft cases in 2024 + Q1 2025 (prosecutors) https://ikon.mn/n/3fmp ; police: 376 cases Jan–Sep 2025, +19.4% https://ubn.mn/p/90327
- Horses ≈ 35% of stolen animals (2019); most cross-border theft is horses; race bloodlines stolen to order. https://sudalgaa.gov.mn/download/mal-khulgaylakh-gemt-khergiyn-kheregzhilt-ergiyn-khuuliyn-1712-dugaar-zyl-2fz
- Traced today by brand + coat colour, origin certificates, checkpoints. Strays → soum governor → police (Order А/190, amended 2025-10-16) https://legalinfo.mn/mn/detail/10783 . **No national online alert system found.**
- Abroad: UK ChipChecker + Digital Stable "report missing"; Canada Equine Register (finder's scan notifies owner); NetPosse (US); Kyrgyzstan "Mal Check" buyer lookup (530,700 horses registered) https://aits.gvfi.gov.kg/home ; Kazakhstan police chip horses against theft.

## 3. Breeds (official code list, А/405)

| Code | Name | Status | Region / note |
|---|---|---|---|
| 0101 | Монгол | үүлдэр | nationwide; mature 360–380 kg |
| 0102 | Галшар | үүлдэр (2016) | Хэнтий, Галшар сум; racing type https://montsame.mn/mn/read/25529 |
| 0103 | Тэс | үүлдэр (2019) | Увс, Завхан, Хөвсгөл; large, red/red-brown https://www.montsame.mn/en/read/212607 |
| 0104 | Дархад | омог | Хөвсгөл (Ринчинлхүмбэ, Цагааннуур) |
| 0105 | Мянгад | омог | Ховд, Мянгад сум |
| 0106 | Өндөршил | омог | Дундговь (Шилмэл омог 2019) |
| 0110–0115 | Англи цэвэр цусны, Араб, Ахалтекин, Будённый, Кабардин, Орлов | бусад | imported; crossbreds common in racing |

- **Жаргалант is not on the official list** (Soviet-era type) — keep only for horses already saved. Add Мянгад, Өндөршил, Эрлийз (crossbred), imported breeds.
- Not Mongolian: Үзэмчин (Inner Mongolia), Хорчин [unconfirmed]. **Тахь is wild and protected — not in a livestock list.**

## 4. Words

- **Age (count the year of life; store birth year, derive the name):** 1 унага · 2 даага · 3 шүдлэн · 4 хязаалан · 5 соёолон · 6+ их нас. Naadam classes: Даага 10–12 km, Шүдлэн 12–14, Хязаалан 15–17, Соёолон 22–24, Их нас 24–26, Азарга 22–24 (Resolution 119/2005, amended 2009) https://legalinfo.mn/mn/detail?lawId=200955
- **Sex / role:** азарга (stallion, entire, 3+) · гүү (mare) · морь / агт (gelding) · үрээ (young entire male) · байдас (3–4-year-old female; байдсан гүү = first foaling) · сувай (did not conceive this year). https://mongoltoli.mn
- **Coat colours (зүс), 17 basic** (Konagaya) https://www.nomadic-kalmsu.ru/jour/article/download/87/98 : хээр (bay) · зээрд (chestnut) · хүрэн (brown) · хар (black) · халтар (seal brown) · хул (dun/buckskin) · халиун (light bay/dun) · шарга (palomino-like) · хонгор/ухаа (light chestnut) · цавьдар (flaxen chestnut) · саарал (grey) · буурал (roan) · бор (ash grey) · улаан (red roan, approx.) · цагаан (white) · алаг (piebald) · цоохор (spotted). Also хөх саарал, хөх бор. **Markings separate:** халзан (blaze), сартай (star), булаг (white legs).

## 5. Practice

- Stallion band (азарганы сүрэг) ≈ 10–30 horses; free grazing far from camp, found with binoculars; winter–summer camps ~15 km apart. https://pmc.ncbi.nlm.nih.gov/articles/PMC8437754/
- **Mare's milk / airag:** season June–October (peak August); milked every 1.5–2 h by day, 4.6–7 times/day; foals tied on the line (зэл) by day, with mares at night. Litres per mare per day: sources disagree (≈2–4 L studies [unconfirmed] vs 7.5 L ministry figure). → a horse milk screen should count **per group of mares per day**, with season start/end. https://mongoliajol.info/index.php/MJAS/article/view/1199
- Gestation ≈ 340 days, normal range ≈ 320–370 → show a **foaling window**, not one date. https://www.extension.purdue.edu/extmedia/VA/VA-26-W.pdf
- Horses: 5,128,700 (2025 census, preliminary), 8.8% of livestock; ~75% of herding households keep horses (survey). https://www.montsame.mn/en/read/386699

## 6. Health (veterinary authority instructions)

| Disease | | Control |
|---|---|---|
| Боом | anthrax | vaccine spring + autumn in endemic areas |
| Адууны ям (not "сап") | glanders | no vaccine; tested twice a year, positives destroyed; mallein test needed for meat export to China |
| Адууны томуу | equine influenza | inactivated vaccine (Biocombinat) |
| Адууны сахуу | strangles | vaccine licensed 2024 [availability unconfirmed] |
| Галзуу | rabies | vaccinated where outbreaks |
| Адууны халдварт цус багадах өвчин | EIA | test and cull |
| Адууны хачгийн халуурал | piroplasmosis | no vaccine; 66–88% seropositive |

## 7. Products to learn from

- **Mongolia, racing:** Aduu APP (Zetta Data, 2025, free) https://apps.apple.com/in/app/aduu-app/id6736912016 · Тод Манлай (brand, 7-generation pedigree, races, offline) https://www.todmanlai.app/ · ugshil.mn (pedigree registry) · ministry race-horse module (Bidsolution, 2020). None has theft alerts or transfers.
- **Herd trackers in Mongolia / Central Asia:** Spotter (Globalstar collars, 30,000+, $160 + $15–26/month, SMS geofence alerts) https://smartspotter.net/ · iGPS (Kazakhstan, 100,000+ horses, one tracker per 10–20 horses) · Hunu (Mongolia 2026, solar GPS + weather warnings) · Chandmani GPS (Unitel/Mobicom network). Stallions destroy collars — put them on a lead mare.
- **Abroad:** UK Digital Stable (free report-missing), FEI HorseApp (offline download + sync for vets; 1.9★ for double entry), Equilab / BarnManager / Stable Secretary (stable apps; complaints: paywalled safety, data lost in updates, entering the same thing twice). None handles free-roaming herds.
- **Tags on horses:** QR silicone halter/mane tag ($15, finder's scan sends location); tail-braided tags on free-roaming horses stayed ~8.5 months on average (https://pubs.usgs.gov/publication/70248068). **No proven AI face/coat recognition product for horses** — research only.
