-- finish-by cases: a job due soon (so early departments are past), and one with no delivery date
insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages)
values (14000000001,'PROJ-00501','Soon Cafe', local_today()+12,'In Production',true,true,true,'{}'),
       (14000000002,'PROJ-00502','No Date Hotel', null,'In Production',true,true,true,'{}');
do $$
declare w uuid; s uuid; p text; i int;
begin
  foreach p in array array['PROJ-00501','PROJ-00502'] loop
    insert into work_orders (job_id) select id from jobs where project_id=p returning id into w;
    for i in 1..2 loop
      insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
        values (w, i, 2, 'CT-0'||i, 'Oak', format('%s/v1/sheet-%s.png',p,i), format('%s/v1/sheet-%s.pdf',p,i), now()) returning id into s;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done)
        select s, d, 2, case when d in ('milling','cnc') then 2 else 0 end from unnest(array['milling','cnc','sanding','finishing','metal','assembly_qc']) d;
    end loop;
  end loop;
end $$;
