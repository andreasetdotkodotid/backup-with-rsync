#!/bin/bash

function cmd_rsync {
  export RSYNC_PASSWORD=PASSWORD
  res=0
  rsync -av $dir/$db.sql rsync://$rsync_user@$rsync_host/$rsync_target
  if [ $? -eq 0 ]; then
     res=1
  fi
  echo "backup_success{database=\"$db\"} $res" >> $tmp
}

function cmd_mysqldump {
  tmp=`mktemp`
  dbs=`mysql --disable-column-names --batch -e "show databases"`
  backup=0
  # backup
  for db in $dbs; do
     if [ "$db" != "information_schema" -a "$db" != "performance_schema" -a "$db" != "mysql" -a "$db" != "sys" ]; then
      res=0
      mysqldump --single-transaction --events --ignore-table=mysql.event --skip-comments $db > $dir/$db.sql
      if [ $? -eq 0 ]; then
         cmd_rsync
         backup=1
      fi
    fi
  done

  rm -f $tmp
  rm -f "$dir/$db.sql"
}

day=`date +%u`
dir="/var/backups/mysql"
if [ $day == 7 ]; then
  rsync_host="IP-BACKUP-MEDAN"
  rsync_user="$(hostname -f)"
  rsync_target="backup-$rsync_user/sql/"
else
  rsync_host="IP-BACKUP-JAKARTA"
  rsync_user="$(hostname -f)"
  rsync_target="$rsync_user/mysql/$day/"
fi

cmd_mysqldump
