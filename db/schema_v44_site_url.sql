-- ============================================================
-- YAK-TAG — schema patch v44
-- The website moved to its own address: https://yaktag.org
--
-- Telegram "lost animal" alerts end with a link to the cow page.
-- This makes that link use the new address. (The old github.io
-- address would still work — GitHub forwards it — but the direct
-- link opens faster.)
--
-- Run ONLY AFTER https://yaktag.org opens the website.
-- Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.app_secret(text)') is null or to_regclass('public.app_secrets') is null then
    raise exception 'Wrong database (or v38 not run): open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

insert into public.app_secrets (name, value)
values ('site_url', 'https://yaktag.org')
on conflict (name) do update set value = excluded.value, updated_at = now();

select name, value from public.app_secrets where name = 'site_url';
