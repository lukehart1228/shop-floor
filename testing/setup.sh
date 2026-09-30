#!/bin/bash
# Builds the whole stand-in from the live GitHub repo, in one go:
#   bash setup.sh            (from anywhere; takes a few minutes the first time)
# Afterwards:
#   /home/claude/sf/repo     the live repo: pages at the top, sql/, testing/
#   /home/claude/sf/base     helpers (load.sh, fresh.sh, checks.sh, seeds, stubs)
#   /home/claude/sf/t        browser tests (pgsupa.js, test_same.js …)
#   /home/claude/sf/out      put new or changed files here while building
#   database sync_base       every SQL file in the live order (template); sync = a working copy
# Needs bash (the sandbox's /bin/sh isn't): run it as  bash setup.sh
set -e
SF=/home/claude/sf
mkdir -p $SF/base $SF/t $SF/out

echo "== 1. Postgres 16, pg_cron, the http extension"
if [ ! -x /usr/lib/postgresql/16/bin/initdb ] || [ ! -f /usr/share/postgresql/16/extension/pg_cron.control ]; then
  rm -f /etc/apt/sources.list.d/nodesource*            # its 403 makes apt-get update fail
  apt-get update -qq                                  # separate command: a failed update installs nothing
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-16 postgresql-16-cron libcurl4-openssl-dev postgresql-server-dev-16 poppler-utils >/tmp/apt.log
fi
if [ ! -f /usr/share/postgresql/16/extension/http.control ]; then
  cd /tmp && rm -rf pgsql-http && git clone -q --depth 1 https://github.com/pramsey/pgsql-http.git && cd pgsql-http && make -s && make -s install
fi
if [ ! -d /tmp/pg/data ]; then
  mkdir -p /tmp/pg && chown postgres:postgres /tmp/pg
  su postgres -c "/usr/lib/postgresql/16/bin/initdb -D /tmp/pg/data -A trust" >/dev/null
  printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = 'sync'\n" >> /tmp/pg/data/postgresql.conf
fi
pg_isready -q -h /tmp/pg -p 5433 || su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg/data -o '-k /tmp/pg -p 5433' -l /tmp/pg/log start" >/dev/null
sleep 1

echo "== 2. The live repo (codeload works when api.github.com is rate-limited)"
if [ -z "$KEEP_REPO" ]; then
  rm -rf $SF/repo /tmp/sf-repo.zip /tmp/shop-floor-main
  curl -sfL -o /tmp/sf-repo.zip https://codeload.github.com/lukehart1228/shop-floor/zip/refs/heads/main
  cd /tmp && unzip -q -o sf-repo.zip && mv /tmp/shop-floor-main $SF/repo
fi
cp $SF/repo/testing/helpers/*.sql $SF/repo/testing/helpers/*.sh $SF/repo/testing/helpers/*.py $SF/base/
cp $SF/repo/testing/helpers/pgsupa.js $SF/repo/testing/tests/*.js $SF/t/
cp $SF/repo/testing/tests/*.sh $SF/base/
chmod +x $SF/base/*.sh

echo "== 3. Browser test tools"
cd $SF && [ -d node_modules/jsdom ] || npm install --silent jsdom@24 pg fake-indexeddb >/dev/null 2>&1
ln -sfn $SF/node_modules $SF/t/node_modules

echo "== 4. The database, from every SQL file in the live order (each run twice, as one transaction)"
bash $SF/base/load.sh 2>&1 | grep -v NOTICE | tail -1
bash $SF/base/checks.sh
echo "(check_monday_sync, check_office and check_catch_up aren't in that list: they need the real Monday and always fail here.)"
