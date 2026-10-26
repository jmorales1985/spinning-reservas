-- Clients can only book the current week and the next one (weeks start on Monday, Costa Rica time).
-- Admins are exempt. Run this once in the Supabase SQL Editor.
create or replace function public.spin_booking_limit()
returns timestamptz language sql stable as $$
  select (date_trunc('week', now() at time zone 'America/Costa_Rica') + interval '14 days')
         at time zone 'America/Costa_Rica'
$$;
grant execute on function public.spin_booking_limit() to authenticated;
revoke all on function public.spin_booking_limit() from public, anon;

drop policy if exists "book own bike before class" on public.spin_reservations;
create policy "book own bike before class" on public.spin_reservations
  for insert to authenticated with check (
    user_id = auth.uid()
    and not public.spin_bike_blocked(class_id, bike)
    and exists (select 1 from public.spin_classes c
                where c.id = class_id and c.starts_at > now() and bike <= c.capacity
                  and (public.spin_is_admin() or c.starts_at < public.spin_booking_limit()))
  );
