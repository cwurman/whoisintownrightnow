-- Version both rows so an older device cannot overwrite newer privacy choices.
-- Column grants intentionally do not permit clients to set these counters.
alter table public.profiles add column revision bigint not null default 1;
alter table public.user_settings add column revision bigint not null default 1;

create or replace function public.account_row_updated() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at := now();
  new.revision := old.revision + 1;
  if tg_table_name = 'user_settings' then
    if new.location_mode is distinct from old.location_mode then
      new.privacy_revision := old.privacy_revision + 1;
    end if;
  end if;
  return new;
end;
$$;

-- Require the caller's snapshot; the original unchecked overload must not remain callable.
drop function public.save_account(text, text, text, text);
create function public.save_account(
  p_display_name text, p_avatar_path text, p_location_mode text, p_notification_mode text,
  p_profile_revision bigint, p_settings_revision bigint
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  account_id uuid := auth.uid();
  profile_revision bigint;
  settings_revision bigint;
begin
  if account_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 80 then
    raise exception 'Name must contain 1 to 80 characters' using errcode = '22023';
  end if;
  perform public.bootstrap_account();
  -- Every save locks in the same order. Compare only after acquiring both locks.
  select revision into profile_revision from public.profiles where id = account_id for update;
  select revision into settings_revision from public.user_settings where user_id = account_id for update;
  if p_profile_revision is distinct from profile_revision or p_settings_revision is distinct from settings_revision then
    raise exception 'Account changed on another device. Reload before saving.' using errcode = 'PT409';
  end if;
  if p_avatar_path is not null and not exists (
    select 1 from storage.objects where bucket_id = 'avatars' and name = p_avatar_path and (storage.foldername(name))[1] = account_id::text
  ) then raise exception 'Upload your profile photo before saving' using errcode = '22023'; end if;
  update public.user_settings set location_mode = p_location_mode, notification_mode = p_notification_mode,
    location_sharing_confirmed_at = coalesce(location_sharing_confirmed_at, now()) where user_id = account_id;
  update public.profiles set display_name = btrim(p_display_name), avatar_path = p_avatar_path,
    onboarding_completed_at = coalesce(onboarding_completed_at, now()) where id = account_id;
  return public.bootstrap_account();
end;
$$;
revoke all on function public.save_account(text, text, text, text, bigint, bigint) from public, anon, authenticated;
grant execute on function public.save_account(text, text, text, text, bigint, bigint) to authenticated;
