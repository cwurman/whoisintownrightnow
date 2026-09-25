-- Account foundation only. Live locations, friendships and invitations follow separately.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 80),
  avatar_path text check (avatar_path is null or avatar_path ~ ('^' || id::text || '/[0-9a-f-]{36}\.jpg$')),
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint completed_profile_has_name check (onboarding_completed_at is null or char_length(btrim(display_name)) > 0)
);

create table public.user_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  location_mode text not null default 'vicinity' check (location_mode in ('exact', 'vicinity')),
  notification_mode text not null default 'off' check (notification_mode in ('off', 'direct_only', 'all')),
  location_sharing_confirmed_at timestamptz,
  privacy_revision bigint not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.user_settings enable row level security;

-- Until friendship access exists, profiles and photos are visible only to their owner.
create policy profiles_read_own on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles for insert to authenticated with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy settings_read_own on public.user_settings for select to authenticated using (user_id = (select auth.uid()));
create policy settings_insert_own on public.user_settings for insert to authenticated with check (user_id = (select auth.uid()));
create policy settings_update_own on public.user_settings for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.profiles, public.user_settings from public, anon, authenticated;
grant select on public.profiles, public.user_settings to authenticated;
grant insert (id, display_name) on public.profiles to authenticated;
grant insert (user_id) on public.user_settings to authenticated;
grant update (display_name, avatar_path, onboarding_completed_at) on public.profiles to authenticated;
grant update (location_mode, notification_mode, location_sharing_confirmed_at) on public.user_settings to authenticated;

create function public.account_row_updated() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at := now();
  if tg_table_name = 'user_settings' then
    if new.location_mode is distinct from old.location_mode then
      new.privacy_revision := old.privacy_revision + 1;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.account_row_updated() from public, anon, authenticated;
create trigger profile_updated before update on public.profiles for each row execute function public.account_row_updated();
create trigger settings_updated before update on public.user_settings for each row execute function public.account_row_updated();

create function public.bootstrap_account(p_initial_name text default '') returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  account_id uuid := auth.uid();
begin
  if account_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  insert into public.profiles (id, display_name) values (account_id, left(btrim(coalesce(p_initial_name, '')), 80)) on conflict (id) do nothing;
  insert into public.user_settings (user_id) values (account_id) on conflict (user_id) do nothing;
  return (select jsonb_build_object('profile', to_jsonb(p), 'settings', to_jsonb(s)) from public.profiles p join public.user_settings s on s.user_id = p.id where p.id = account_id);
end;
$$;
revoke all on function public.bootstrap_account(text) from public, anon, authenticated;
grant execute on function public.bootstrap_account(text) to authenticated;

create function public.save_account(p_display_name text, p_avatar_path text, p_location_mode text, p_notification_mode text) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  account_id uuid := auth.uid();
begin
  if account_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 80 then
    raise exception 'Name must contain 1 to 80 characters' using errcode = '22023';
  end if;
  perform public.bootstrap_account();
  perform 1 from public.profiles where id = account_id for update;
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
revoke all on function public.save_account(text, text, text, text) from public, anon, authenticated;
grant execute on function public.save_account(text, text, text, text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 5242880, array['image/jpeg']);

create policy avatar_read_own on storage.objects for select to authenticated
using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatar_insert_own on storage.objects for insert to authenticated
with check (bucket_id = 'avatars' and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}\.jpg$'));
-- Versioned objects are immutable. A referenced photo cannot be removed accidentally.
create policy avatar_delete_unused_own on storage.objects for delete to authenticated
using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
  and not exists (select 1 from public.profiles where avatar_path = name));
