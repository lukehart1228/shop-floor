insert into auth.users (id, email) values
 ('11111111-1111-1111-1111-111111111111','mike@example.com'), ('22222222-2222-2222-2222-222222222222','luke@example.com'),
 ('33333333-3333-3333-3333-333333333333','test@example.com'), ('44444444-4444-4444-4444-444444444444','donnie@example.com'),
 ('55555555-5555-5555-5555-555555555555','willie@example.com'), ('66666666-6666-6666-6666-666666666666','kp@example.com'),
 ('77777777-7777-7777-7777-777777777777','shawn@example.com'), ('88888888-8888-8888-8888-888888888888','david@example.com')
on conflict do nothing;
insert into profiles (id, full_name, role, departments) values
  ('11111111-1111-1111-1111-111111111111','Mike B','supervisor','{sanding,finishing}'),
  ('22222222-2222-2222-2222-222222222222','Luke H','manager','{}'),
  ('44444444-4444-4444-4444-444444444444','Donnie E','supervisor','{milling,cnc}'),
  ('55555555-5555-5555-5555-555555555555','Willie J','supervisor','{metal}'),
  ('66666666-6666-6666-6666-666666666666','KP','supervisor','{assembly_qc}'),
  ('88888888-8888-8888-8888-888888888888','David D','manager','{}')
on conflict do nothing;
insert into auth.users (id, email) values
 ('99999999-9999-9999-9999-999999999990','jimw@example.com'), ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','ericb@example.com')
on conflict do nothing;
insert into profiles (id, full_name, role, departments) values
  ('99999999-9999-9999-9999-999999999990','Jim W','supervisor','{finishing}'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Eric B','supervisor','{full_custom,assembly_qc}')
on conflict do nothing;
