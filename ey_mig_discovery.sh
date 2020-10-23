#!/bin/bash
function build_cat_node_cmds {
#dd`rm 1a_catlg_db_cmds.cmds
db_ip=`ifconfig -a | grep "inet " | grep -vE "127.0.0.1" | awk '{print $2}'`
proj_id=`ifconfig -a | grep "inet " | grep -vE "127.0.0.1" | awk '{print $2}'| tr -d '.'`

db_instance=$1
db_node_name="ND"`ifconfig -a | grep "inet " | grep -vE "127.0.0.1" | awk '{print $2}'| tr -d '.' | cut -c 3-9`
db_auth_meth=`db2 get dbm cfg | grep -i "(AUTHENTICATION)"  | awk '{print $6}'`
db_port=`db2 get dbm cfg  | grep -i "(SVCENAME)" | awk '{print $6}'`
db_ostype=`db2pd -osinfo | grep -i OSName | awk '{print toupper($2)}'`
printf '%s%s%s%s%s%s%s%s\n'  "catalog TCPIP NODE "$db_node_name" REMOTE "$db_ip" SERVER "$db_port" OSTYPE "$db_ostype > ${proj_id}_1a_catlg_node_cmds.cmds
printf '%s,\"%s%s%s%s%s%s%s%s\"\n' "$proj_id" "catalog TCPIP NODE "$db_node_name" REMOTE "$db_ip" SERVER "$db_port" OSTYPE "$db_ostype > ${proj_id}_1a_catlg_node_meta.del
db_SVCE=
}
function build_cat_db_cmds { 
db_name=$1
node_name=$2
printf '%s%s%s%s%s%s%s%s\n' 'catalog database ' $db_name ' as ' r_$db_name ' at node ' $node_name ' AUTHENTICATION ' $3 > ${proj_id}_1b_catlg_db_cmds.cmds
printf '\"%s\",\"%s%s%s%s%s%s%s%s\"\n'  "`echo $HOSTNAME`" 'catalog database '  $db_name ' as ' r_$db_name ' at node ' $node_name ' AUTHENTICATION ' $3 > ${proj_id}_1b_catlg_db_meta.del
}
function work_load_type {
echo "Workload Type:"
db2 +o connect to $i 
db2 "SELECT ROWS_RETURNED/SELECT_SQL_STMTS AS DB_AVG_RESULT_SIZE,
CASE
  WHEN (ROWS_RETURNED/SELECT_SQL_STMTS) <=10 THEN 'OLTP'
  WHEN ((ROWS_RETURNED/SELECT_SQL_STMTS) >10 AND (ROWS_RETURNED/SELECT_SQL_STMTS) <=15) THEN 'MIXED WORKLOAD'
  ELSE 'WAREHOUSE'
END AS WORKLOAD_TYPE
FROM TABLE(MON_GET_DATABASE(-2)) WITH UR
"
}
function tablespace_sizes { 
db2 +o connect to $i 
db2 "export to ${proj_id}_project_meta of del select ${proj_id} from sysibm.sysdummy1"
db2 "export to ${proj_id}_${i}_tablespace_meta.del of del select $proj_id,  '$i', substr(tbsp_name,1,30), tbsp_type, tbsp_content_type as type, (select count(*) from syscat.tables st where st.tbspace=t.tbsp_name) as tabcount, tbsp_using_auto_storage as auto_sto, tbsp_auto_resize_enabled as auto_resize, tbsp_page_size as page_size, tbsp_used_pages as used_pages, tbsp_total_pages as total_pages, tbsp_total_pages*tbsp_page_size/1024/1024/1024 as ts_gb from table(mon_get_tablespace('',-2)) as t order by tbsp_name with ur"
}

function disable_FKS {
db2 +o connect to $i 
echo "Generating Alter statements to disable Foreign Keys prior to loads..................."
db2 "select 'ALTER TABLE '||rtrim(tabschema)||'.'||ltrim(tabname)||' ALTER FOREIGN KEY '||CONSTNAME||' NOT ENFORCED;' from syscat.tabconst where type = 'F' and ENFORCED = 'Y'" > ${proj_id}_03_$1_Disable_FKS.ddl
}
function tables_with_LOBs {
db2 -x "select c.tabschema as schema_name,
       c.tabname as table_name,
       c.colname as column_name,
       c.typename as data_type
from syscat.columns c
inner join syscat.tables t on 
      t.tabschema = c.tabschema and t.tabname = c.tabname
where t.type = 'T'
    and t.tabschema not like 'SYS%' and c.tabname not like 'EXPLAIN%' and c.tabname not like 'ADVISE%' and c.tabname not like 'ERROR_%'
    and typename in ('BLOB', 'CLOB', 'DBCLOB')
order by c.tabschema, 
    c.tabname, 
    c.colname"
}
function db_size {
db2 +o connect to $1
db2 "export to ${proj_id}_database_$1_size_meta.del of del 
with t1(dbname, db_name, db_size,db_capacity) as (select '$proj_id','$i', db_size, db_capacity from systools.stmg_dbsize_info)
,
t2 (db2_avg_result_size,WORKLOAD_TYPE) as (SELECT ROWS_RETURNED/SELECT_SQL_STMTS AS DB_AVG_RESULT_SIZE,
CASE
  WHEN (ROWS_RETURNED/SELECT_SQL_STMTS) <=10 THEN 'OLTP'
  WHEN ((ROWS_RETURNED/SELECT_SQL_STMTS) >10 AND (ROWS_RETURNED/SELECT_SQL_STMTS) <=15) THEN 'MIXED WORKLOAD'
  ELSE 'WAREHOUSE'
END AS WORKLOAD_TYPE
FROM TABLE(MON_GET_DATABASE(-2)))
Select * from t1,t2" 

echo "starting export"
db2 "export to ${proj_id}_server_meta.del of del SELECT ${proj_id} as PROJECT, HOST_NAME, 'IP', OS_FULL_VERSION, TOTAL_CPUS, TOTAL_MEMORY from SYSIBMADM.ENV_SYS_INFO"

db2 "export to ${proj_id}_instance_meta.del of del select b.HOST_NAME as PROJECT,  INST_NAME, SERVICE_LEVEL, FIXPACK_NUM from sysibmadm.env_inst_info,SYSIBMADM.ENV_SYS_INFO b"
}
function ms_scripts {
db2 +o connect to $1
db2 -txf msscriptone.txt > ${proj_id}_${i}_db2output1.csv
db2 -txf msscripttwo.txt > ${proj_id}_${i}_db2output2.csv
db2 "export to ${proj_id}_${i}_table_meta.del of del SELECT ${proj_id}, '$i', tbspace.tbspace, tables.stats_time as statstime
,trim(trailing from substr(tables.tabschema,1,128)) as schema ,trim(trailing from substr(tables.tabname,1,128)) as tabname
, card as rows_per_table
, decimal(float(tables.npages)/ ( 1024 / (tbspace.pagesize/1024)),9,2) as used_mb
, decimal(float(tables.fpages)/ ( 1024 / (tbspace.pagesize/1024)),9,2) as allocated_mb

FROM syscat.tables tables
, syscat.tablespaces tbspace
WHERE tables.tbspace=tbspace.tbspace and tables.tabschema not like 'SYS%'"
}
function generate_load_cmds {
db2 +o connect to $1
db2 -x  "with cte(schema) as
(select schemaname from syscat.schemata where schemaname not like 'SYS%' and schemaname <> 'NULLID'),
cte1(schema, table, mod) as
(select distinct tbcreator as schema, tbname as table,
case WHEN (name='SYS_START' and generated='A') THEN 'PERIODOVERRIDE' WHEN (name='SYS_END' and generated='A') THEN 'PERIODOVERRIDE'
WHEN (name='TRANS_START' and generated='A') THEN 'TRANSACTIONIDOVERRIDE'
WHEN (name='SYS_START' and generated='') THEN 'PERIODOVERRIDE' WHEN (name='SYS_END' and generated='') THEN 'PERIODOVERRIDE'
WHEN (name='TRANS_START' and generated='') THEN 'TRANSACTIONIDOVERRIDE'
WHEN (generated='A' and identity='N') THEN 'GENERATEDOVERRIDE'
WHEN (generated='A' and identity='Y') THEN 'IDENTITYOVERRIDE'
WHEN generated='D' THEN 'GENERATEDOVERRIDE'
END AS GENERATED
from sysibm.syscolumns c, sysibm.tables t
where c.tbcreator=t.table_schema and c.tbname=t.table_name
and t.table_schema in (select schema from cte)
and t.table_type='BASE TABLE' and ((c.generated<>'') or (c.generated='' and c.name in ('SYS_START','SYS_END','TRANS_START')))),

cte2(schema, table, mod, rank) as
(select cte1.*, (select count(*) as count from cte1 b where cte1.schema=b.schema and cte1.table=b.table and cte1.mod>b.mod) as counter
from cte1),

load_mod (schema, table, modlist) as
(select schema, table, cast(listagg((case when rank=0 then '' || trim(mod)
when rank>0 then ' ' || trim(mod) end
), '') as varchar(100)) as modlist from cte2 group by schema, table),

column_list as (
select
i.table_schema as indschema,
i.table_name as indname,
listagg(CAST(
case
when ic.ordinal_position = 1 then ' ' || case when (DATA_TYPE='DECIMAL' and IS_NULLABLE='YES') THEN 'COALESCE(' || '\"' || trim(COLUMN_NAME) || '\"' || ',' || 'CAST(NULL as decimal))
AS ' || '\"' || trim(COLUMN_NAME) || '\"' ELSE '\"' || trim(COLUMN_NAME) || '\"' END
when ic.ordinal_position > 1 then ', ' || case when (DATA_TYPE='DECIMAL' and IS_NULLABLE='YES') THEN 'COALESCE(' || '\"' || trim(COLUMN_NAME) || '\"' || ',' || 'CAST(NULL as decimal))
AS ' || '\"' || trim(COLUMN_NAME) || '\"' ELSE '\"' || trim(COLUMN_NAME) || '\"' END
end
as varchar(32000)), '') within group (order by ic.ordinal_position) as colnames
from sysibm.tables as i
join sysibm.columns as ic
on i.table_schema = ic.table_schema
and i.table_name = ic.table_name
where i.table_schema IN (select schema from cte)
and i.table_type = 'BASE TABLE'
and (select max(c.ordinal_position) from sysibm.columns c where c.table_name = i.table_name) < 500
group by i.table_schema,
i.table_name,
i.table_schema,
i.table_name
order by i.table_schema,
i.table_name,
i.table_name )

select 'DECLARE CW CURSOR DATABASE SOURCEDB USER db2inst1 using password123 for SELECT '
|| trim(colnames) || ' from ' || '\"' || trim(indschema) || '\"' || '.' || '\"' || trim(indname) || '\"' || ' WITH UR;'
|| x'0A' ||
'LOAD FROM CW OF CURSOR '
|| CASE WHEN MODLIST IS NULL THEN '' ELSE 'MODIFIED BY ' || MODLIST END || ' WARNINGCOUNT 10 MESSAGES /db2loads/messages/'
|| trim(indname) || '.msg REPLACE INTO ' || '\"' || trim(indschema) || '\"' || '.' || '\"' || trim(indname) || '\"' || ' NONRECOVERABLE ALLOW NO ACCESS;' as loadcmd
from column_list c left join load_mod t on c.indschema=t.schema and c.indname=t.table with uR
" > ${proj_id}_04_$1_load_from_cursor.sql
}
###Start of Script
host_name=$HOSTNAME
echo "Instances Located:"
#server and instance meta
db_instance=`ps -ef|grep -i db2sysc|grep -v grep|awk '{print $1}'`
echo $db_instance

echo "OS Info"
db2pd -osinfo
db2level
db2licm -l
#get dbm cfg"
echo "Generating DBM CFG"
#db2cfexp 0_DBM_cfg.out
 
build_cat_node_cmds $db_instance   

echo "Datebases:"
for i in `db2 list db directory | grep Indirect -B 5 |grep "Database name" |awk {'print $4'} |sort -u | uniq`;     do       echo -e "\t"$i;  db2 +o connect to $i;  db2 "call get_dbsize_info(?,?,?,0)" | awk 'BEGIN{RS=ORS="\n\n";FS=OFS="\n"}/DATABASESIZE/' | tail -2 | awk -F: '{print "\t\tTOTAL DATABASE SIZE: " $2/1024/1024/1024" GB"}' |head -1;  done

build_cat_node_cmds $db_instance   

for i in `db2 list db directory | grep Indirect -B 5 |grep "Database name" |awk {'print $4'} |sort -u | uniq`;
   do
      work_load_type $i
      db2 +o connect to $i
      echo "Database filesystems for:"$i
      db2 "export to ${proj_id}_${i}_FILESYSTEMS_meta.del of del SELECT ${proj_id} , '$i',substr(TYPE,1,30), substr(PATH,1,150) FROM TABLE(ADMIN_LIST_DB_PATHS()) AS FILES"
      echo "Generating Create DB and DB CFG for objects in : " $i
      db2look -d $i -createdb -printdbcfg -o ${proj_id}"_01_createdb_"$i"_ddl.out" 2>/dev/null;
      echo "building catalog DB commands..................."
      build_cat_db_cmds $i $db_node_name $db_auth_meth
      echo "Generating DDL for objects in : " $i
      db2look -d $i -a -e -l -x -o ${proj_id}"_02_ddl_"$i".out" 2>/dev/null;
      echo "Tablespace Sizes:"
      tablespace_sizes $i
      echo "Tables with Large Objects(LOB)"
      tables_with_LOBs
      disable_FKS $i
      generate_load_cmds $i
      ms_scripts $i
      db_size $i
done




















