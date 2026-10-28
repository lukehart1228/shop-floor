#!/bin/bash
# test_job_status_db.sh — job_status.sql (28 Oct): a look-up login, signed in the way Supabase does it,
# can read job status and nothing else, and every function a signed-in login may call refuses it.
# Each call is undone straight after (a raised 'undo'), so the sweep changes nothing. A reply of
# {"ok": false} counts as refused: the Delivery phone's functions answer that way ("hasn't reached the
# database yet") when the caller can't see the trip, so the phone keeps the entry queued.
# Runs on a fresh seeded `sync` with job_status.sql loaded.  Usage: bash test_job_status_db.sh
P="psql -h /tmp/pg -p 5433 -U postgres -d sync -q -At"
LOOK=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb; MIKE=11111111-1111-1111-1111-111111111111; LUKE=22222222-2222-2222-2222-222222222222
fails=0; pass(){ echo "PASS $1"; }; fail(){ echo "FAIL $1"; fails=$((fails+1)); }
as() { # as <uuid> <file>: run a file as that login, through authenticator like the API
  { echo "set role authenticated;"; echo "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false) \\g /dev/null"; cat "$2"; } > /tmp/as_js.sql
  psql -h /tmp/pg -p 5433 -U authenticator -d sync -q -At -f /tmp/as_js.sql 2>&1 | grep -v '^CONTEXT\|^PL/pgSQL'; }

$P -c "insert into auth.users (id, email) values ('$LOOK', 'sally.sales@example.com') on conflict do nothing" >/dev/null
$P -c "insert into profiles (id, full_name, role, departments) values ('$LOOK', 'Sally (sales)', 'supervisor', '{}') on conflict (id) do nothing" >/dev/null
r=$($P -c "select set_look_up('sally.sales@example.com')"); echo "$r" | grep -q "can now look up jobs" && pass "set_look_up() makes Sally a look-up login" || fail "set_look_up: $r"

# ---- reads -----------------------------------------------------------------------------------------
cat > /tmp/q.sql <<'Q'
select jsonb_array_length(job_lookup('00099')->'jobs') || '|' || (job_lookup('00099')->>'look_up')
       || '|' || coalesce(job_lookup('00099')#>>'{jobs,0,departments,0,finish_by}', 'none');
Q
r=$(as $LOOK /tmp/q.sql | tail -1); [ "$r" = "1|true|none" ] && pass "Sally finds PROJ-00099 by number, marked look-up, no done-by dates ($r)" || fail "Sally's lookup: $r"
r=$(as $MIKE /tmp/q.sql | tail -1); echo "$r" | grep -qE "^1\|false\|20[0-9]{2}-" && pass "Mike finds it with done-by dates ($r)" || fail "Mike's lookup: $r"
TABLES="defects delivery_docs delivery_tasks flags loadouts outside_jobs photos problems problem_messages defect_messages qc_entries routine_tasks routine_task_logs sheet_sends supply_requests supply_request_events task_photos trip_parts feedback progress_events sheet_adjustments department_live_log monday_sync_log save_runs lab_runs machine_files"
for t in $TABLES; do echo "select '$t=' || count(*) from $t;"; done > /tmp/q.sql
echo "select 'storage=' || count(*) from storage.objects where bucket_id in ('photos','deliveries','machine-files');" >> /tmp/q.sql
r=$(as $LOOK /tmp/q.sql | grep -v '=0$' | tr '\n' ' '); [ -z "$r" ] && pass "Sally reads no row of the 27 log tables or the photo, delivery and machine files" || fail "Sally reads: $r"
r=$(as $MIKE /tmp/q.sql | grep -E '^(problems|flags|loadouts|photos)=' | tr '\n' ' '); pass "for comparison Mike reads: $r"
echo "select count(*) from profiles;" > /tmp/q.sql
r=$(as $LOOK /tmp/q.sql | tail -1); [ "$r" = "1" ] && pass "Sally sees only her own profile" || fail "Sally sees $r profiles"

# ---- the sweep: every function a signed-in login may run ----------------------------------------------
$P -F'|' -c "
select p.proname, pg_get_function_identity_arguments(p.oid),
       coalesce(array_to_string(p.proargnames, ','), ''), array_to_string(array(select format_type(t, null) from unnest(p.proargtypes) t), ',')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f' and p.provolatile = 'v'
   and has_function_privilege('authenticated', p.oid, 'execute')
   and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
   and pg_get_function_result(p.oid) <> 'trigger'
 order by 1" > /tmp/fns.txt
python3 - <<'PY' > /tmp/sweep.sql
import subprocess
def one(sql):
    return subprocess.run(['psql','-h','/tmp/pg','-p','5433','-U','postgres','-d','sync','-At','-c',sql],capture_output=True,text=True).stdout.strip()
ids = {}
for name, q in [('job',"select id from jobs where not is_test order by project_id limit 1"),('loadout',"select id from loadouts limit 1"),
                ('request',"select id from supply_requests limit 1"),('sheet',"select id from sheets limit 1"),('send',"select id from sheet_sends limit 1"),
                ('doc',"select id from delivery_docs limit 1"),('task',"select id from delivery_tasks limit 1"),('item',"select id from inv_items limit 1"),
                ('problem',"select id from problems limit 1"),('defect',"select id from defects limit 1"),('flag',"select id from flags limit 1"),
                ('progress',"select id from sheet_progress limit 1"),('work_order',"select id from work_orders limit 1"),('photo',"select id from photos limit 1"),
                ('outside',"select id from outside_jobs limit 1"),('type',"select id from defect_types limit 1"),('feedback',"select id from feedback limit 1")]:
    v = one(q); ids[name] = f"'{v}'::uuid" if v else "gen_random_uuid()"
def val(n, t):
    n = (n or '').lower()
    if t == 'uuid':
        for k in ['work_order','loadout','request','progress','problem','defect','outside','feedback','photo','sheet','send','doc','task','item','flag','type','job']:
            if k in n: return ids[k]
        if 'thread' in n: return ids['problem']
        return 'gen_random_uuid()'
    if t == 'text':
        if any(k in n for k in ['dept','department','p_from','p_to']): return "'finishing'"
        if 'kind' in n: return "'delivery'"
        if 'email' in n: return "'someone@example.com'"
        if 'level' in n: return "'watch'"
        if 'result' in n: return "'pass'"
        return "'test'"
    return {'integer':'1','bigint':'1','numeric':'1','double precision':'0','boolean':'true','date':'current_date',
            'timestamp with time zone':'now()','jsonb':"'{}'::jsonb",'json':"'{}'::json",'text[]':"'{finishing}'::text[]",
            'integer[]':"'{1}'::int[]",'uuid[]':"array[]::uuid[]",'numeric[]':"'{1}'::numeric[]",'bytea':"'\\x00'::bytea"}.get(t, 'null')
print("do $sweep$ declare ok text := ''; r text; begin")
for line in open('/tmp/fns.txt'):
    name, ident, argn, argt = line.rstrip('\n').split('|')
    names = argn.split(',') if argn else []
    types = argt.split(',') if argt else []
    # numeric(…) types never appear here; split on ',' is safe for these signatures
    args = ', '.join(val(names[i] if i < len(names) else '', types[i]) for i in range(len(types)))
    call = f"perform {name}({args})"
    print(f"  begin r := ({name}({args}))::text; if coalesce(r, '') not like '%\"ok\": false%' then ok := ok || '{name} '; end if; raise exception 'undo'; exception when others then null; end;")
print("  raise notice 'ALLOWED: %', ok; end $sweep$;")
PY
n=$(wc -l < /tmp/fns.txt)
look=$(as $LOOK /tmp/sweep.sql | grep -o 'ALLOWED:.*' | sed 's/ALLOWED: //')
mike=$(as $MIKE /tmp/sweep.sql | grep -o 'ALLOWED:.*' | sed 's/ALLOWED: //')
luke=$(as $LUKE /tmp/sweep.sql | grep -o 'ALLOWED:.*' | sed 's/ALLOWED: //')
ALLOW=" send_feedback report_device "
bad=""; for f in $look; do case "$ALLOW" in *" $f "*) ;; *) bad="$bad $f";; esac; done
[ -z "$bad" ] && pass "Sally is refused every one of the $n functions a login may call, apart from Feedback and her device report (allowed: ${look:-none})" || fail "Sally ran:$bad"
proven=0; for f in $(cut -d'|' -f1 /tmp/fns.txt | sort -u); do case " $mike $luke " in *" $f "*) case " $look " in *" $f "*) ;; *) proven=$((proven+1));; esac;; esac; done
pass "of those, $proven ran for Mike or Luke with the same test values, so their refusal for Sally is the login, not the values; the rest refused everyone with these values"
$P -c "select count(*) from profiles where look_up" | grep -q '^1$' && pass "nothing the sweep did stuck (it undoes every call)" || fail "profiles changed"
echo "test_job_status: $fails failed"; [ $fails -eq 0 ]
