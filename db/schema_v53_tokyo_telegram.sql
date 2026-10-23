-- ============================================================
-- YAK-TAG — schema v53: the Telegram bot follows the move to Tokyo
--
-- Run ONCE in the NEW (Tokyo) project's SQL editor, right after the
-- website switch is pushed. Not before: until then Sydney is still
-- the live database, and a herder linking Telegram would be linked in
-- the wrong one.
--
-- 1. telegram_setup(...) now points to Tokyo by default (the old
--    default was the Sydney address — a later token change would have
--    sent the bot back there).
-- 2. Telegram is told to deliver the bot's messages to Tokyo. The
--    token, bot name and webhook secret were copied with the database,
--    so nothing has to be typed.
--
-- Then, 10 seconds later:   select telegram_check();
-- It must say  Telegram-ийн хариу (200): {"ok":true,...}
-- ============================================================

do $$
begin
  if to_regprocedure('public.telegram_setup(text, text, text, text)') is null
     or to_regprocedure('public.app_secret(text)') is null then
    raise exception 'Wrong database (v38 Telegram not found): open the Tokyo project mjijgxfmkgtxmpbmshtl and run again.';
  end if;
end $$;

-- same as v38, only the two defaults changed (Sydney → Tokyo)
create or replace function telegram_setup(
  p_token   text,
  p_bot     text,
  p_api_url text default 'https://mjijgxfmkgtxmpbmshtl.supabase.co',
  p_api_key text default 'sb_publishable_npSJ3ZAWO_ODx_cXbvORoQ__t-_1GiJ'   -- the public key from config.js
) returns text language plpgsql security definer set search_path = public as $$
declare
  v_token  text := trim(coalesce(p_token, ''));
  v_bot    text := ltrim(trim(coalesce(p_bot, '')), '@');
  v_secret text;
  v_id     bigint;
begin
  if v_token !~ '^[0-9]+:[A-Za-z0-9_-]{30,}$' then
    raise exception 'Token буруу байна. BotFather-аас авсан 123456789:AA… хэлбэртэй токен оруулна уу.';
  end if;
  if v_bot !~* '^[a-z0-9_]{2,29}bot$' then
    raise exception 'Bot-ийн username буруу. "bot"-оор төгсөнө, жишээ нь YakTagMN_bot.';
  end if;
  v_secret := coalesce(app_secret('telegram_webhook_secret'),
                       replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
  insert into app_secrets (name, value) values
    ('telegram_token', v_token), ('telegram_bot', v_bot), ('telegram_webhook_secret', v_secret)
  on conflict (name) do update set value = excluded.value, updated_at = now();

  select net.http_post(
    url  := 'https://api.telegram.org/bot' || v_token || '/setWebhook',
    body := jsonb_build_object(
      'url', p_api_url || '/rest/v1/rpc/telegram_webhook?apikey=' || p_api_key,
      'secret_token', v_secret,
      'allowed_updates', jsonb_build_array('message'),
      'drop_pending_updates', true)
  ) into v_id;
  insert into app_secrets (name, value) values ('telegram_setup_request', v_id::text)
  on conflict (name) do update set value = excluded.value, updated_at = now();
  return 'Хадгаллаа. 10 секундын дараа ажиллуулна уу:  select telegram_check();';
end $$;

revoke all on function telegram_setup(text, text, text, text) from public, anon, authenticated;

-- point the bot at Tokyo, with the token already saved here
-- (a database with no bot set up, like the local test copy, is left alone)
select case when coalesce(app_secret('telegram_token'), '') = '' or coalesce(app_secret('telegram_bot'), '') = ''
            then 'No Telegram token saved in this database — the bot was not touched.'
            else telegram_setup(app_secret('telegram_token'), app_secret('telegram_bot')) end as result;
