-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Fixed bike blocks: a blocked bike cannot be booked in ANY class until an admin unblocks it.
-- Existing reservations on a bike that gets blocked are kept.

create table if not exists public.spin_blocked_bikes (
  bike int primary key check (bike between 1 and 26),
  created_at timestamptz not null default now()
);
alter table public.spin_blocked_bikes enable row level security;

drop policy if exists "signed-in read blocked" on public.spin_blocked_bikes;
drop policy if exists "admin insert blocked" on public.spin_blocked_bikes;
drop policy if exists "admin delete blocked" on public.spin_blocked_bikes;
create policy "signed-in read blocked" on public.spin_blocked_bikes
  for select to authenticated using (true);
create policy "admin insert blocked" on public.spin_blocked_bikes
  for insert to authenticated with check (public.spin_is_admin());
create policy "admin delete blocked" on public.spin_blocked_bikes
  for delete to authenticated using (public.spin_is_admin());

-- Booking rule: same as before, plus the bike must not be blocked
drop policy if exists "book own bike before class" on public.spin_reservations;
create policy "book own bike before class" on public.spin_reservations
  for insert to authenticated with check (
    user_id = auth.uid()
    and not exists (select 1 from public.spin_blocked_bikes b where b.bike = spin_reservations.bike)
    and exists (select 1 from public.spin_classes c
                where c.id = class_id and c.starts_at > now() and bike <= c.capacity)
  );

-- Live updates for everyone looking at the map
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'spin_blocked_bikes') then
    alter publication supabase_realtime add table public.spin_blocked_bikes;
  end if;
end $$;
