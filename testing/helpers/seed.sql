insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages)
values (13060952631,'PROJ-00418','Enid''s Table Restaurant and Bookstore', local_today()+55,'In Production',true,false,true,'{"wood":"Sanding"}'),
       (11462549625,'PROJ-00099','Oaks Academy Q01092', local_today()+28,'In Production',true,true,false,'{"wood":"CNC"}'),
       (12543970562,'PROJ-00362','Trinitas - Noblesville', local_today()+3,'Delivery',false,true,true,'{}'),
       (12362919739,'PROJ-00325','Patch Development', local_today()+70,'Pre-Production',false,false,false,'{}');
do $$
declare w uuid; s uuid; q int[] := array[1,2,2,3,3,3,4,1,1]; codes text[] := array['TB-03','TB-03','TB-03','TB-04','TB-04','TB-06','WMT-DAN-DIN','WMT-DAN-DIN','TB-01']; i int;
begin
  insert into work_orders (job_id) select id from jobs where project_id='PROJ-00418' returning id into w;
  for i in 1..9 loop
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
      values (w, i, q[i], codes[i], 'Ash', format('PROJ-00418/v1/sheet-%s.png',i), format('PROJ-00418/v1/sheet-%s.pdf',i), now()) returning id into s;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      select s, d, q[i], case when d in ('milling','cnc') then q[i] when d='sanding' and i<=3 then q[i] else 0 end
      from unnest(array['milling','cnc','sanding','finishing','metal','assembly_qc']) d;
  end loop;
  insert into work_orders (job_id) select id from jobs where project_id='PROJ-00099' returning id into w;
  for i in 1..3 loop
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
      values (w, i, 3, 'DSK-0'||i, 'Maple', format('PROJ-00099/v1/sheet-%s.png',i), format('PROJ-00099/v1/sheet-%s.pdf',i), now()) returning id into s;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      select s, d, 3, case when d='milling' then 3 else 0 end from unnest(array['milling','cnc','sanding','finishing','assembly_qc']) d;
  end loop;
end $$;
select make_test_job('PROJ-00418');
select set_person('test@example.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true);
insert into profiles (id, full_name, role, departments) values ('77777777-7777-7777-7777-777777777777','Shawn K','supervisor','{delivery}') on conflict do nothing;
