-- Store only a counter; invitation audio and transcripts are never persisted here.
create table private.hang_draft_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  requests integer not null default 0 check (requests >= 0)
);
alter table private.hang_draft_limits enable row level security;
revoke all on private.hang_draft_limits from public, anon, authenticated;

create function private.consume_hang_draft() returns void
language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  budget private.hang_draft_limits%rowtype;
begin
  if caller is null or not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = caller and not u.is_anonymous and u.deleted_at is null
      and (u.banned_until is null or u.banned_until < now()) and p.onboarding_completed_at is not null
  ) then raise exception 'Complete sign-up before drafting hangs' using errcode = '42501'; end if;
  insert into private.hang_draft_limits(user_id) values (caller) on conflict do nothing;
  select * into budget from private.hang_draft_limits where user_id = caller for update;
  if budget.window_started_at <= now() - interval '1 hour' then
    budget.window_started_at := now(); budget.requests := 0;
  end if;
  if budget.requests >= 20 then raise exception 'Drafting limit reached. Try later.' using errcode = 'PT429'; end if;
  update private.hang_draft_limits set requests = budget.requests + 1,
    window_started_at = budget.window_started_at where user_id = caller;
end;
$$;
create function public.consume_hang_draft() returns void
language sql security invoker set search_path = '' as $$ select private.consume_hang_draft(); $$;
revoke all on function private.consume_hang_draft(), public.consume_hang_draft() from public, anon, authenticated;
grant execute on function private.consume_hang_draft(), public.consume_hang_draft() to authenticated;
notify pgrst, 'reload schema';
