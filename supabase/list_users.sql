-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Lets admins pick a registered client (name + email) when creating a fixed reservation.
create or replace function public.spin_list_users()
returns table(user_id uuid, display_name text, email text)
language sql stable security definer set search_path = public, auth as $$
  select u.id, p.display_name, u.email::text
  from auth.users u
  left join public.spin_profiles p on p.user_id = u.id
  where public.spin_is_admin() and u.email is not null and u.email_confirmed_at is not null
  order by lower(coalesce(p.display_name, u.email));
$$;
revoke all on function public.spin_list_users() from public, anon;
grant execute on function public.spin_list_users() to authenticated;
