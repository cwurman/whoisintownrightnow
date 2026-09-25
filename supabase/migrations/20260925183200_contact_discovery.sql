-- Only opt-in, verified numbers are discoverable. Address books are never persisted.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table private.contact_discovery (
  user_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default false
);
create table private.contact_lookup_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  numbers_checked integer not null default 0 check (numbers_checked >= 0)
);
alter table private.contact_discovery enable row level security;
alter table private.contact_lookup_limits enable row level security;
revoke all on private.contact_discovery, private.contact_lookup_limits from public, anon, authenticated;

create function private.contact_discovery_settings(p_enabled boolean default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  verified text;
  discoverable boolean;
begin
  if caller is null or not exists (
    select 1 from auth.users u where u.id = caller and not u.is_anonymous
      and u.deleted_at is null and (u.banned_until is null or u.banned_until < now())
  ) then raise exception 'Authentication required' using errcode = '42501'; end if;
  select '+' || ltrim(u.phone, '+') into verified from auth.users u
    where u.id = caller and u.phone_confirmed_at is not null and u.phone ~ '^\+?[1-9][0-9]{6,14}$';
  if p_enabled is true and verified is null then
    raise exception 'Verify your number before enabling discovery' using errcode = '22023';
  end if;
  if p_enabled is not null then
    insert into private.contact_discovery(user_id, enabled) values (caller, p_enabled)
    on conflict (user_id) do update set enabled = excluded.enabled;
  end if;
  select d.enabled into discoverable from private.contact_discovery d where d.user_id = caller;
  return jsonb_build_object('enabled', coalesce(discoverable, false), 'verified_phone', verified);
end;
$$;

create function private.match_contacts(p_phones text[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  budget private.contact_lookup_limits%rowtype;
  amount integer;
  result jsonb;
begin
  if caller is null or not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = caller and not u.is_anonymous and u.deleted_at is null
      and (u.banned_until is null or u.banned_until < now()) and p.onboarding_completed_at is not null
  ) then raise exception 'Complete sign-up before finding contacts' using errcode = '42501'; end if;
  amount := cardinality(p_phones);
  if p_phones is null or amount > 500 or exists (
    select 1 from unnest(p_phones) p where p is null or p !~ '^\+[1-9][0-9]{6,14}$'
  ) then raise exception 'Send up to 500 international phone numbers' using errcode = '22023'; end if;
  if amount = 0 then return '[]'::jsonb; end if;

  insert into private.contact_lookup_limits(user_id) values (caller) on conflict do nothing;
  select * into budget from private.contact_lookup_limits where user_id = caller for update;
  if budget.window_started_at <= now() - interval '1 hour' then
    budget.window_started_at := now();
    budget.numbers_checked := 0;
  end if;
  if budget.numbers_checked + amount > 10000 then
    raise exception 'Contact matching limit reached. Try again later.' using errcode = 'PT429';
  end if;
  update private.contact_lookup_limits set numbers_checked = budget.numbers_checked + amount,
    window_started_at = budget.window_started_at where user_id = caller;

  select coalesce(jsonb_agg(distinct input.phone), '[]'::jsonb) into result
    from unnest(p_phones) as input(phone)
    join auth.users u on u.phone = ltrim(input.phone, '+')
    join private.contact_discovery d on d.user_id = u.id and d.enabled
    join public.profiles p on p.id = u.id and p.onboarding_completed_at is not null
    where u.id <> caller and u.phone_confirmed_at is not null and not u.is_anonymous
      and u.deleted_at is null and (u.banned_until is null or u.banned_until < now());
  return result;
end;
$$;

-- Public entry points use invoker rights. Privilege elevation is isolated in an
-- unexposed schema with explicit authentication, input checks and a lookup budget.
create function public.contact_discovery_settings(p_enabled boolean default null) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.contact_discovery_settings(p_enabled);
$$;
create function public.match_contacts(p_phones text[]) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.match_contacts(p_phones);
$$;
revoke all on function private.contact_discovery_settings(boolean), private.match_contacts(text[]),
  public.contact_discovery_settings(boolean), public.match_contacts(text[]) from public, anon, authenticated;
grant execute on function private.contact_discovery_settings(boolean), private.match_contacts(text[]),
  public.contact_discovery_settings(boolean), public.match_contacts(text[]) to authenticated;
notify pgrst, 'reload schema';
