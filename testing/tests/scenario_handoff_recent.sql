-- PROJ-00099: CNC pushed sheet 1 only; Mike (Sanding) finished sheet 1 on the tablet
update sheet_progress set qty_done = 3 where department = 'cnc' and sheet_id in (select s.id from sheets s join work_orders w on w.id=s.work_order_id join jobs j on j.id=w.job_id where j.project_id='PROJ-00099' and s.sheet_number=1);
update sheet_progress set qty_done = 3 where department = 'sanding' and sheet_id in (select s.id from sheets s join work_orders w on w.id=s.work_order_id join jobs j on j.id=w.job_id where j.project_id='PROJ-00099' and s.sheet_number=1);
-- PROJ-00600: in production, NOT handed off; Milling, Metal and Full Custom rows
do $$ declare j uuid; w uuid; s uuid; begin
  insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, handed_off) values (19999999001,'PROJ-00600','Held Job Co', local_today()+40,'In Production',true,false) returning id into j;
  insert into work_orders (job_id) values (j) returning id into w;
  insert into sheets (work_order_id, sheet_number, qty, item_code, png_path, pdf_path, pdf_uploaded_at) values (w,1,2,'HJ-1','PROJ-00600/v1/sheet-1.png','PROJ-00600/v1/sheet-1.pdf',now()) returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s,'milling',2,0),(s,'cnc',2,0),(s,'metal',2,0),(s,'full_custom',2,0);
end $$;
-- PROJ-00418: Mike finishes every Sanding sheet on the tablet
update sheet_progress set qty_done = qty_required where department = 'sanding' and sheet_id in (select s.id from sheets s join work_orders w on w.id=s.work_order_id join jobs j on j.id=w.job_id where j.project_id='PROJ-00418' and w.is_current);
