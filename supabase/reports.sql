-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Admin reports: one row per reservation in a date range (Costa Rica time), with class, client and payment data.
-- Classes without reservations come back with res_id NULL so empty classes also show up.
create or replace function public.spin_report(p_from date, p_to date)
returns table(res_id uuid, class_id uuid, starts_at timestamptz, title text, instructor text, capacity int,
              bike int, user_id uuid, display_name text, email text,
              method text, proof_path text, paid boolean, pay_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  select r.id, c.id, c.starts_at, c.title, c.instructor, c.capacity,
         r.bike, r.user_id, p.display_name, u.email::text,
         y.method, y.proof_path, coalesce(y.paid, false), y.updated_at
  from public.spin_classes c
  left join public.spin_reservations r on r.class_id = c.id
  left join public.spin_profiles p on p.user_id = r.user_id
  left join auth.users u on u.id = r.user_id
  left join public.spin_payments y on y.reservation_id = r.id
  where public.spin_is_admin()
    and (c.starts_at at time zone 'America/Costa_Rica')::date between p_from and p_to
  order by c.starts_at, r.bike;
$$;
revoke all on function public.spin_report(date, date) from public, anon;
grant execute on function public.spin_report(date, date) to authenticated;
