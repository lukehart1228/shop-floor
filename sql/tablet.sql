-- =====================================================================
-- Shop Floor — tablet app support (Phase 1, step 4)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
--
-- Adds one view, v_floor_sheets: every sheet the floor can work on, with
-- its job and its count, in one place — so the tablet makes one simple
-- request instead of stitching five tables together.
--
-- A sheet appears only when:
--   * it's on the CURRENT version of its work order, and
--   * its job is linked to Monday AND Monday's Phase says In Production.
-- So a work order uploaded early, or under a mistyped PROJ number, can't
-- reach a tablet until Monday agrees the job is on the floor.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('tablet.sql'); end if;
end $$;

drop view if exists v_floor_sheets;

create view v_floor_sheets with (security_invoker = true) as
select
  sp.id                            as progress_id,
  sp.department,
  sp.qty_done,
  sp.qty_required,
  sp.state,
  sp.updated_at                    as progress_updated_at,
  s.id                             as sheet_id,
  s.sheet_number,
  s.item_code,
  s.species,
  s.shape,
  s.width,
  s.length,
  s.thickness,
  s.total_height,
  s.png_path,
  s.pdf_path,
  (s.pdf_uploaded_at is not null)  as pages_ready,
  w.id                             as work_order_id,
  w.version,
  j.id                             as job_id,
  j.project_id,
  j.name                           as job_name,
  j.delivery_date,
  j.materials_ordered
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id
                  and j.is_active
                  and j.monday_item_id is not null;

-- security_invoker: the view applies each login's own security rules.
-- Signed-in users can read it; people with no login get nothing.
revoke all on v_floor_sheets from anon;
grant select on v_floor_sheets to authenticated;
