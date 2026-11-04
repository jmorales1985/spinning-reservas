-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Clients can cancel their own reservation only up to 4 hours before the class starts; admins can always remove one.
drop policy if exists "cancel own before class or admin" on public.spin_reservations;
create policy "cancel own before class or admin" on public.spin_reservations
  for delete to authenticated using (
    public.spin_is_admin()
    or (user_id = auth.uid()
        and exists (select 1 from public.spin_classes c
                    where c.id = class_id and c.starts_at > now() + interval '4 hours'))
  );
