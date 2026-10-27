-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Lets an admin block a bike in specific classes ("bloquear por clase"), besides the date-period blocks.
create table public.spin_class_blocks (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.spin_classes(id) on delete cascade,
  bike int not null check (bike between 1 and 26),
  note text check (note is null or char_length(note) <= 60),
  created_at timestamptz not null default now(),
  unique (class_id, bike)
);
alter table public.spin_class_blocks enable row level security;
create policy "read class blocks" on public.spin_class_blocks for select to authenticated using (true);
create policy "admin insert class blocks" on public.spin_class_blocks for insert to authenticated with check (public.spin_is_admin());
create policy "admin update class blocks" on public.spin_class_blocks for update to authenticated using (public.spin_is_admin()) with check (public.spin_is_admin());
create policy "admin delete class blocks" on public.spin_class_blocks for delete to authenticated using (public.spin_is_admin());

-- a bike is blocked when a period block covers the class OR the class itself is blocked for it
create or replace function public.spin_bike_blocked(p_class uuid, p_bike int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.spin_holds h
    join public.spin_classes c on c.id = p_class
    where h.user_id is null and h.bike = p_bike
      and public.spin_covers(h.starts_on, h.ends_on, h.weekdays, c.starts_at))
  or exists (select 1 from public.spin_class_blocks b where b.class_id = p_class and b.bike = p_bike);
$$;

alter publication supabase_realtime add table public.spin_class_blocks;
