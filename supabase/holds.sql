-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- "Holds" = bikes set aside for a period of time. Two kinds, in one table:
--   user_id IS NULL      -> BLOCK: nobody can book that bike in the covered classes
--   user_id = <person>   -> FIXED RESERVATION: the person gets that bike in every covered class
-- A hold covers classes whose date (Costa Rica time) is between starts_on and ends_on (NULL = no end),
-- on the chosen weekdays (NULL = every day; 0=Sunday .. 6=Saturday).
-- Existing reservations are never cancelled by a new block; fixed reservations skip classes where the
-- bike (or the person) is already taken.

create table public.spin_holds (
  id uuid primary key default gen_random_uuid(),
  bike int not null check (bike between 1 and 26),
  user_id uuid references auth.users(id) on delete cascade,
  starts_on date not null,
  ends_on date,
  weekdays int[] check (weekdays is null or (array_length(weekdays, 1) between 1 and 7 and weekdays <@ array[0,1,2,3,4,5,6])),
  note text check (note is null or char_length(note) <= 60),
  created_at timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index spin_holds_bike on public.spin_holds(bike);
alter table public.spin_holds enable row level security;

-- everyone sees blocks (needed to draw the map); only admins see fixed reservations' rows
create policy "read blocks, admins read all" on public.spin_holds
  for select to authenticated using (user_id is null or public.spin_is_admin());
create policy "admin insert holds" on public.spin_holds
  for insert to authenticated with check (public.spin_is_admin());
create policy "admin update holds" on public.spin_holds
  for update to authenticated using (public.spin_is_admin()) with check (public.spin_is_admin());
create policy "admin delete holds" on public.spin_holds
  for delete to authenticated using (public.spin_is_admin());

-- reservations created from a fixed hold remember it (kept as history when the hold is removed)
alter table public.spin_reservations
  add column hold_id uuid references public.spin_holds(id) on delete set null;
create index spin_reservations_hold on public.spin_reservations(hold_id);

-- does a hold period cover a class start time?
create or replace function public.spin_covers(p_from date, p_to date, p_days int[], p_starts timestamptz)
returns boolean language sql stable as $$
  select (p_starts at time zone 'America/Costa_Rica')::date between p_from and coalesce(p_to, 'infinity'::date)
     and (p_days is null or extract(dow from (p_starts at time zone 'America/Costa_Rica'))::int = any(p_days));
$$;

-- is this bike blocked for this class? (used by the booking policy)
create or replace function public.spin_bike_blocked(p_class uuid, p_bike int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.spin_holds h
    join public.spin_classes c on c.id = p_class
    where h.user_id is null and h.bike = p_bike
      and public.spin_covers(h.starts_on, h.ends_on, h.weekdays, c.starts_at));
$$;
grant execute on function public.spin_bike_blocked(uuid, int) to authenticated;
revoke all on function public.spin_bike_blocked(uuid, int) from public, anon;

-- booking rule: same as before, plus the bike must not be blocked for that class
drop policy if exists "book own bike before class" on public.spin_reservations;
create policy "book own bike before class" on public.spin_reservations
  for insert to authenticated with check (
    user_id = auth.uid()
    and not public.spin_bike_blocked(class_id, bike)
    and exists (select 1 from public.spin_classes c
                where c.id = class_id and c.starts_at > now() and bike <= c.capacity)
  );

-- create the fixed reservations for upcoming classes (one hold, one class, or all)
create or replace function public.spin_apply_holds(p_hold uuid, p_class uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.spin_reservations(class_id, bike, user_id, hold_id)
  select c.id, h.bike, h.user_id, h.id
  from public.spin_holds h
  join public.spin_classes c
    on c.starts_at > now() and h.bike <= c.capacity
   and public.spin_covers(h.starts_on, h.ends_on, h.weekdays, c.starts_at)
  where h.user_id is not null
    and (p_hold is null or h.id = p_hold)
    and (p_class is null or c.id = p_class)
  on conflict do nothing;
$$;
revoke all on function public.spin_apply_holds(uuid, uuid) from public, anon, authenticated;

create or replace function public.spin_trg_hold_ins() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.spin_apply_holds(new.id, null); return new; end $$;
create trigger spin_hold_after_insert after insert on public.spin_holds
  for each row execute function public.spin_trg_hold_ins();

-- classes created later (single or recurring) get the fixed reservations automatically
create or replace function public.spin_trg_class_ins() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.spin_apply_holds(null, new.id); return new; end $$;
create trigger spin_class_after_insert after insert on public.spin_classes
  for each row execute function public.spin_trg_class_ins();

-- Admin: create a hold. p_email NULL/empty = block. Returns 'not_found' or 'ok|<created>|<skipped>'
--   fixed: created = classes where the person got the bike, skipped = covered classes where it was not possible
--   block: created = 0,        skipped = existing future reservations on that bike that are kept
create or replace function public.spin_add_hold(p_bike int, p_email text, p_from date, p_to date, p_days int[], p_note text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare uid uuid; hid uuid; created int := 0; skipped int := 0;
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_email is not null and trim(p_email) <> '' then
    select id into uid from auth.users
     where lower(email) = lower(trim(p_email)) and email_confirmed_at is not null;
    if uid is null then return 'not_found'; end if;
  end if;
  insert into public.spin_holds(bike, user_id, starts_on, ends_on, weekdays, note)
  values (p_bike, uid, p_from, p_to, p_days, nullif(trim(coalesce(p_note, '')), ''))
  returning id into hid;   -- the insert trigger has already created the fixed reservations
  if uid is not null then
    select count(*) into created from public.spin_reservations where hold_id = hid;
    select count(*) into skipped from public.spin_classes c
     where c.starts_at > now() and p_bike <= c.capacity
       and public.spin_covers(p_from, p_to, p_days, c.starts_at);
    skipped := skipped - created;
  else
    select count(*) into skipped from public.spin_reservations r
     join public.spin_classes c on c.id = r.class_id
     where r.bike = p_bike and c.starts_at > now()
       and public.spin_covers(p_from, p_to, p_days, c.starts_at);
  end if;
  return 'ok|' || created || '|' || skipped;
end $$;

-- Admin: remove a hold and the future reservations it created (past ones stay as history)
create or replace function public.spin_remove_hold(p_hold uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  delete from public.spin_reservations r using public.spin_classes c
   where r.hold_id = p_hold and c.id = r.class_id and c.starts_at > now();
  delete from public.spin_holds where id = p_hold;
  return 'ok';
end $$;

-- Admin: holds that have not ended, with the person's name and email
create or replace function public.spin_list_holds()
returns table(id uuid, bike int, user_id uuid, starts_on date, ends_on date, weekdays int[], note text, display_name text, email text)
language sql stable security definer set search_path = public, auth as $$
  select h.id, h.bike, h.user_id, h.starts_on, h.ends_on, h.weekdays, h.note, p.display_name, u.email::text
  from public.spin_holds h
  left join public.spin_profiles p on p.user_id = h.user_id
  left join auth.users u on u.id = h.user_id
  where public.spin_is_admin()
    and (h.ends_on is null or h.ends_on >= (now() at time zone 'America/Costa_Rica')::date)
  order by h.starts_on, h.bike;
$$;

revoke all on function public.spin_add_hold(int, text, date, date, int[], text) from public, anon;
revoke all on function public.spin_remove_hold(uuid) from public, anon;
revoke all on function public.spin_list_holds() from public, anon;
grant execute on function public.spin_add_hold(int, text, date, date, int[], text) to authenticated;
grant execute on function public.spin_remove_hold(uuid) to authenticated;
grant execute on function public.spin_list_holds() to authenticated;

-- live updates
alter publication supabase_realtime add table public.spin_holds;
