
 


spool db_chk1.csv
set PAGESIZE 50000

 


show parameter sga
show parameter pga
column stat_name format a60
Prompt "OS Statistics"
select stat_name, value from v$osstat;



prompt "check compression:"

select compress_for, count(1) from dba_tables where owner <>'SYS'
and trim(compress_for) is not null
group by compress_for;

spool off
prompt "segment size"


set ECHO OFF
set TERMOUT ON
set TAB OFF
set TRIMOUT ON
set TRIMSPOOL ON
set LINESIZE 500
set FEEDBACK OFF
set VERIFY OFF
set COLSEP ','

spool segment_type_size.csv
select owner, segment_type, round(sum(bytes/1024/1024/1024),2) gb from dba_segments
group by rollup (owner, segment_type)
order by 1,2;

spool off

Prompt "Peak Concurrency - Active session history"

spool peak_concurrency_ash.csv
select * from (
select sample_id, sample_time, count(1) 
from dba_hist_active_sess_history
where sample_time > sysdate-31
group by sample_id, sample_time
union all
select sample_id, sample_time, count(1) 
from v$active_session_history
group by sample_id, sample_time
order by 3 desc) where rownum < 121;
spool off

Prompt "Peak Concurrency without backup workload - Active session history"

spool peak_concurrency_ash_wo_bkup.csv
select * from (
select sample_id, sample_time, count(1) 
from dba_hist_active_sess_history
where sample_time > sysdate-31
and module not like '%rman%'
group by sample_id, sample_time
union all
select sample_id, sample_time, count(1) 
from v$active_session_history
where module not like '%rman%'
group by sample_id, sample_time
order by 3 desc) where rownum < 121;
spool off

Prompt "Hourly Average active sessions"

spool hourly_aas.csv
select extract(hour from sample_time),trunc(sample_time) day,  round(avg(aas),1)
from (
select sample_time, count(1) aas
from dba_hist_active_sess_history
where sample_time > sysdate-31
group by sample_time)
group by rollup( extract(hour from sample_time),trunc(sample_time)) order by 1,2;

spool off


Prompt "Check out db activities for the sample Id with top concurrency" 

spool top_concur_sample_events.csv
with top_sample as
( select sample_id from (
select sample_id, sample_time, count(1) 
from dba_hist_active_sess_history
where sample_time > sysdate-31
and module not like '%rman%'
group by sample_id, sample_time
order by 3 desc) where rownum < 50 )
select * from (
select session_state,event,sql_id, count(1) from 
dba_hist_active_sess_history ash,
top_sample t
where ash.sample_id = t.sample_id
group by session_state,event,sql_id
order by 4 desc) where rownum < 50;

spool off

Prompt "DB Time VS CPU Time"
column snap_id format 999999
column snap_time format a25
column CPU_MINs format 999999
column DBTIME_MINs format 999999
 
spool dbtime_cpu.csv
with cpu_dbtime as
(  select    stat_name, begin_snap_id, end_snap_id,  end_interval_time, delta_value/1000000/60 mins  from
(
select   begin_snap_id, end_snap_id, end_interval_time,  stat_name,
decode(sign(curr_value-prev_value), -1, curr_value, curr_value-prev_value) delta_value
from (
select    stat_name,  lag(snap_id)  over (order by stat_name, snap_id) begin_snap_id, snap_id end_snap_id, lag(end_interval_time)  over (order by stat_name, snap_id) end_interval_time, value curr_value,
NVL(LAG(value) OVER (ORDER BY  stat_name,  snap_id),0)       prev_value
from DBA_HIST_SYS_time_model  natural join
dba_hist_snapshot
where
end_interval_time > trunc(sysdate-31)
and stat_name in ('DB CPU','DB time')
and dbid = (select dbid from v$database)
and instance_number=(select instance_number from v$instance)
)
where end_interval_time  >= trunc(sysdate-31)
and begin_snap_id=end_snap_id-1
)
)
select   begin_snap_id,end_snap_id, end_interval_time snap_time,
round(sum(decode(stat_name,'DB CPU',mins,0))) CPU_MINs ,
round(sum(decode(stat_name,'DB time',mins,0)))  DBTIME_MINs
from cpu_dbtime
group by begin_snap_id, end_snap_id, end_interval_time
order by 1;
spool off


Prompt "Check out top db wait events" 

spool current_top_wait_events.csv
select * from (select event, count(1) from 
v$active_session_history
group by event order by 2 desc) where rownum < 15;
spool off


spool hist_top_wait_events.csv
select * from (select event, count(1) from
dba_hist_active_sess_history
where sample_time > sysdate-31
group by event order by 2 desc) where rownum < 30;
spool off

Prompt "Check db file sequential read latency" 

spool hist_dbfileseqread_latency.csv
select 'db file sequential read' event, to_char(snap_date,'yyyymmdd') sn_date, daily_time_waited_secs , daily_waits , round(daily_time_waited_secs*1000/daily_waits,2) avg_latency_ms  from (
select trunc(begin_interval_time)  snap_date,   sum(delta_time_waited_secs) daily_time_waited_secs,
sum(delta_time_waits) daily_waits   from
(
select snap_id, begin_interval_time,  
decode(sign(curr_time_waited_micro-prev_time_waited_micro), -1, curr_time_waited_micro/1000000, (curr_time_waited_micro-prev_time_waited_micro)/1000000) delta_time_waited_secs,
decode(sign(curr_total_waits-prev_total_waits), -1, curr_total_waits, curr_total_waits-prev_total_waits) delta_time_waits
from (
select a.snap_id, begin_interval_time, a.time_waited_micro curr_time_waited_micro, 
a.total_waits curr_total_waits,
NVL(LAG(a.total_waits) OVER (ORDER BY a.snap_id),0)       prev_total_waits,
NVL(LAG(a.time_waited_micro) OVER (ORDER BY a.snap_id),0) prev_time_waited_micro
from dba_hist_system_event a,
dba_hist_snapshot b
where trim(lower(a.event_name))=trim(lower('db file sequential read'))
and b.snap_id >= (SELECT MIN(snap_id)
                            FROM   dba_hist_snapshot
                            WHERE  begin_interval_time>= trunc(sysdate-31)-1/24
                           )
AND    b.snap_id <= (SELECT MAX(snap_id)
                            FROM   dba_hist_snapshot
                            WHERE   end_interval_time<= trunc(sysdate)
                           )
and a.snap_id=b.snap_id))
group by trunc(begin_interval_time)  
 )
where  snap_date   > trunc(sysdate-31)  
order by to_char(snap_date,'yyyymmdd');
spool off

Prompt "Check log file sync latency" 

spool hist_logfilesync_latency.csv
select 'log file sync' event, to_char(snap_date,'yyyymmdd') sn_date, daily_time_waited_secs , daily_waits , round(daily_time_waited_secs*1000/daily_waits,2) avg_latency_ms  from (
select trunc(begin_interval_time)  snap_date,   sum(delta_time_waited_secs) daily_time_waited_secs,
sum(delta_time_waits) daily_waits   from
(
select snap_id, begin_interval_time,  
decode(sign(curr_time_waited_micro-prev_time_waited_micro), -1, curr_time_waited_micro/1000000, (curr_time_waited_micro-prev_time_waited_micro)/1000000) delta_time_waited_secs,
decode(sign(curr_total_waits-prev_total_waits), -1, curr_total_waits, curr_total_waits-prev_total_waits) delta_time_waits
from (
select a.snap_id, begin_interval_time, a.time_waited_micro curr_time_waited_micro, 
a.total_waits curr_total_waits,
NVL(LAG(a.total_waits) OVER (ORDER BY a.snap_id),0)       prev_total_waits,
NVL(LAG(a.time_waited_micro) OVER (ORDER BY a.snap_id),0) prev_time_waited_micro
from dba_hist_system_event a,
dba_hist_snapshot b
where trim(lower(a.event_name))=trim(lower('log file sync'))
and b.snap_id >= (SELECT MIN(snap_id)
                            FROM   dba_hist_snapshot
                            WHERE  begin_interval_time>= trunc(sysdate-31)-1/24
                           )
AND    b.snap_id <= (SELECT MAX(snap_id)
                            FROM   dba_hist_snapshot
                            WHERE   end_interval_time<= trunc(sysdate)
                           )
and a.snap_id=b.snap_id))
group by trunc(begin_interval_time)  
 )
where  snap_date   > trunc(sysdate-31)  
order by to_char(snap_date,'yyyymmdd');

spool off

 


Prompt "IOPs and IO Throughput from Instance Activities"
 
spool iops_iombps.csv
 
with io as
(  select    stat_name, begin_snap_id, end_snap_id,  begin_interval_time,  
extract(hour from elapsed_time)*60*60 + extract( minute from elapsed_time)*60 +round(extract( second from elapsed_time) ) elapsed_seconds, delta_value   from
(
select   begin_snap_id, end_snap_id, begin_interval_time,  stat_name,
decode(sign(curr_value-prev_value), -1, curr_value, curr_value-prev_value) delta_value,
(end_interval_time-begin_interval_time)   elapsed_time 
from (
select    stat_name,  lag(snap_id)  over (order by stat_name, snap_id) begin_snap_id, snap_id end_snap_id, end_interval_time, lag(end_interval_time)  over (order by stat_name, snap_id) begin_interval_time, value curr_value,
NVL(LAG(value) OVER (ORDER BY  stat_name,  snap_id),0)       prev_value
from DBA_HIST_SYSSTAT natural join
dba_hist_snapshot
where
end_interval_time > trunc(sysdate-31)
and stat_name in ('physical write total bytes','physical read total bytes','physical read total IO requests', 'physical write total IO requests')
and dbid = (select dbid from v$database)
and instance_number=(select instance_number from v$instance)
)
where end_interval_time  >= trunc(sysdate-31)
and begin_snap_id=end_snap_id-1
)
)
select begin_snap_id, end_snap_id, snap_time, elapsed_seconds,pio_wbytes,pio_rbytes,prios,pwios, 
round ((pio_wbytes+pio_rbytes)/1024/1024/elapsed_seconds,2) MBPs,
round ((prios+pwios)/elapsed_seconds,0) IOPs
from (
select   begin_snap_id,end_snap_id, begin_interval_time snap_time, elapsed_seconds,
round(sum(decode(stat_name,'physical write total bytes',delta_value,0))) pio_wbytes,
round(sum(decode(stat_name,'physical read total bytes',delta_value,0))) pio_rbytes,
round(sum(decode(stat_name,'physical read total IO requests',delta_value,0))) prios,
round(sum(decode(stat_name,'physical write total IO requests',delta_value,0))) pwios
from io
group by begin_snap_id, end_snap_id, begin_interval_time , elapsed_seconds
order by 1);
spool off
  
Prompt "Top Block Change Segments:"

spool top_block_change.csv
column snap_day format a20
column object_name format a40
column object_type format a15
column daily_block_changes format 9999999999999
column rank format 99
select x.snap_day, y.object_name, y.object_type, x.block_changes daily_block_changes, rank from
(select * from (
select SNAP_DAY, obj#, block_changes, rank() over (partition by SNAP_DAY order by block_changes desc nulls last) rank
from (
select trunc(begin_interval_time) SNAP_DAY, OBJ#, sum(DB_BLOCK_CHANGES_DELTA) block_changes
from dba_hist_seg_stat  natural join dba_hist_snapshot
where  begin_interval_time > trunc(sysdate-31)
and dbid = (select dbid from v$database) 
and instance_number = (select i.instance_number from v$instance i)
group by trunc(begin_interval_time),  obj#
having sum(db_block_changes_delta) > 6000000)
)
where rank < 4 order by snap_day, rank) x,
dba_objects y where x.obj#= y.object_id
order by 1, rank;
spool off


Prompt "Top query pattern:"

spool top_query_pattern.csv
select * from
(
select
          sql_id,
            sum(executions_delta) daily_execs,
           round(sum(buffer_gets_delta)/sum(greatest(1,executions_delta)),2) avg_buffer_gets,
          round(sum(disk_reads_delta)/sum(greatest(1,executions_delta)) ,3) avg_disk_reads,
            round(sum(elapsed_time_delta)/sum(greatest(1,executions_delta))/1000000,4) avg_elapsed_seconds,
            round(sum(rows_processed_delta)/sum(greatest(1,executions_delta)),1) avg_rows_processed_per_exec,
          sum(buffer_gets_delta) total_buffer_get,
          sum(disk_reads_delta) total_disk_reads
         from
            DBA_HIST_SQLSTAT natural join
            DBA_HIST_SNAPSHOT
         where
           begin_interval_time >= sysdate-31 and executions_delta >0
  group by sql_id   order by 7 desc) where rownum < 51 order by 8 desc;
spool off


Prompt RMAN backup check

 spool rman_bkup_check.csv
 
col START_TIME format a20
col END_TIME  format a20
col STATUS format a10
col operation format a34
select /*+ rule ordered */
b.INSTANCE_NAME,
--b.HOST_NAME,
  OPERATION,Object_type,
to_char(a.START_TIME,'dd-mon-yyyy hh24:mi:ss') start_time
  ,to_char(a.END_TIME,'dd-mon-yyyy hh24:mi:ss') end_time
  ,round(a.INPUT_BYTES/1048576/1024,2) input_g
  ,round(a.OUTPUT_BYTES/1048576/1024,2) output_g
  ,a.STATUS
  ,round((a.END_TIME-START_TIME)/(1/1440),1) elapsed_min
  ,round((a.OUTPUT_BYTES/1048576/1024)/((a.END_TIME-a.START_TIME)/(1/24)),2) gig_per_hour
  from v$rman_status a,v$instance b
  where a.start_time > trunc(sysdate -31) 
-- and a.OBJECT_TYPE like '%DB%'
  and a.OUTPUT_BYTES> 0
--and
--a.start_time in (select max(START_TIME) 
--from  v$rman_status where OBJECT_TYPE like '%DB%');

spool off

Prompt "RMAN IOs"
column snap_time format a30
column begin_snap_id format 9999999
column end_snap_id format 9999999

 
 

spool rman_io.csv
with io as
(  select     begin_snap_id, end_snap_id,  begin_interval_time,  
extract(hour from elapsed_time)*60*60 + extract( minute from elapsed_time)*60 +round(extract( second from elapsed_time) ) elapsed_seconds, delta_read_mgs read_mgs, delta_write_mgs write_mgs, delta_read_ios read_ios, delta_write_ios write_ios   from
(
select   begin_snap_id, end_snap_id, begin_interval_time,   
decode(sign(curr_read_mgs-prev_read_mgs), -1, curr_read_mgs, curr_read_mgs-prev_read_mgs) delta_read_mgs,
decode(sign(curr_write_mgs-prev_write_mgs), -1, curr_write_mgs, curr_write_mgs-prev_write_mgs) delta_write_mgs,
decode(sign(curr_read_ios-prev_read_ios), -1, curr_read_ios, curr_read_ios-prev_read_ios) delta_read_ios,
decode(sign(curr_write_ios-prev_write_ios), -1, curr_write_ios, curr_write_ios-prev_write_ios) delta_write_ios,
(end_interval_time-begin_interval_time)   elapsed_time 
from (
select   lag(snap_id) over (order by snap_id) begin_snap_id, snap_id end_snap_id, end_interval_time, lag(end_interval_time)  over (order by  snap_id) begin_interval_time, 
SMALL_READ_MEGABYTES+LARGE_READ_MEGABYTES curr_read_mgs,
SMALL_WRITE_MEGABYTES+LARGE_WRITE_MEGABYTES curr_write_mgs, SMALL_READ_REQS+LARGE_READ_REQS curr_read_ios,
SMALL_write_REQS+LARGE_write_REQS curr_write_ios,
NVL(LAG(SMALL_READ_MEGABYTES+LARGE_READ_MEGABYTES ) OVER (ORDER BY   snap_id),0)       prev_read_mgs,
NVL(LAG(SMALL_write_MEGABYTES+LARGE_write_MEGABYTES ) OVER (ORDER BY   snap_id),0)       prev_write_mgs,
NVL(LAG(SMALL_READ_REQS+LARGE_READ_REQS ) OVER (ORDER BY   snap_id),0)       prev_read_ios,
NVL(LAG(SMALL_write_REQS+LARGE_write_REQS ) OVER (ORDER BY   snap_id),0)       prev_write_ios
from DBA_HIST_IOSTAT_FUNCTION natural join
dba_hist_snapshot
where
end_interval_time > trunc(sysdate-31)
and function_name='RMAN'
and dbid = (select dbid from v$database)
and instance_number=(select instance_number from v$instance)
)
where end_interval_time  >= trunc(sysdate-31)
and begin_snap_id=end_snap_id-1
)
)
select begin_snap_id, end_snap_id, begin_interval_time snap_time, elapsed_seconds,read_mgs, write_mgs, read_ios, write_ios, round((read_mgs+write_mgs)/elapsed_seconds, 0) mgps,
round((read_ios+write_ios)/elapsed_seconds, 0) iops
from io
order by 1 ;


spool off



Prompt read/write requests workload

spool read_write_ios.csv
with io as
(  select     begin_snap_id, end_snap_id,  begin_interval_time,  
extract(hour from elapsed_time)*60*60 + extract( minute from elapsed_time)*60 +round(extract( second from elapsed_time) ) elapsed_seconds, delta_read_mgs read_mgs, delta_write_mgs write_mgs, delta_read_ios read_ios, delta_write_ios write_ios   from
(
select   begin_snap_id, end_snap_id, begin_interval_time,   
decode(sign(curr_read_mgs-prev_read_mgs), -1, curr_read_mgs, curr_read_mgs-prev_read_mgs) delta_read_mgs,
decode(sign(curr_write_mgs-prev_write_mgs), -1, curr_write_mgs, curr_write_mgs-prev_write_mgs) delta_write_mgs,
decode(sign(curr_read_ios-prev_read_ios), -1, curr_read_ios, curr_read_ios-prev_read_ios) delta_read_ios,
decode(sign(curr_write_ios-prev_write_ios), -1, curr_write_ios, curr_write_ios-prev_write_ios) delta_write_ios,
(end_interval_time-begin_interval_time)   elapsed_time 
from (
select   lag(snap_id) over (order by snap_id) begin_snap_id, snap_id end_snap_id, end_interval_time, lag(end_interval_time)  over (order by  snap_id) begin_interval_time, 
read_mgs curr_read_mgs,
write_mgs curr_write_mgs, 
read_ios curr_read_ios,
write_ios curr_write_ios,
NVL(LAG(read_mgs ) OVER (ORDER BY   snap_id),0)       prev_read_mgs,
NVL(LAG(write_mgs ) OVER (ORDER BY   snap_id),0)       prev_write_mgs,
NVL(LAG(read_ios) OVER (ORDER BY   snap_id),0)       prev_read_ios,
NVL(LAG(write_ios ) OVER (ORDER BY   snap_id),0)       prev_write_ios
from (
select snap_id, end_interval_time, sum(SMALL_READ_MEGABYTES+LARGE_READ_MEGABYTES ) read_mgs,
sum(SMALL_WRITE_MEGABYTES+LARGE_WRITE_MEGABYTES ) write_mgs,
sum(SMALL_READ_REQS+LARGE_READ_REQS ) read_ios,
sum(SMALL_WRITE_REQS+LARGE_WRITE_REQS ) write_ios 
from DBA_HIST_IOSTAT_FUNCTION natural join
dba_hist_snapshot
where function_name in ('RMAN','Others','LGWR','Buffer Cache Reads','DBWR','Direct Reads','Direct Writes')
and end_interval_time > trunc(sysdate-31)
and dbid = (select dbid from v$database)
and instance_number=(select instance_number from v$instance)
group by snap_id, end_interval_time
order by 1
)
)
where end_interval_time  >= trunc(sysdate-31)
and begin_snap_id=end_snap_id-1
)
)
select begin_snap_id, end_snap_id, begin_interval_time snap_time, elapsed_seconds,read_mgs, write_mgs, read_ios, write_ios, round((read_mgs+write_mgs)/elapsed_seconds, 0) mgps,
round((read_ios+write_ios)/elapsed_seconds, 0) iops
from io
order by 1 ;

spool off

Prompt Top application IO Programs and MOdules
spool top_app_io_by_program.csv

select * from (
select event, program, module, client_id, sql_opname,  count(1) from
dba_hist_active_sess_history  
where  session_type='FOREGROUND'
and wait_class like '%I/O%'
group by  event, program, module, client_id, sql_opname
order by 6 desc ) where rownum < 50;
spool off

Prompt Top IO queries by module/action
spool top_io_queires_by_module.csv
select * from (select trunc(begin_interval_time), module, action, parsing_schema_name, sum(physical_read_requests_delta) read_ios, round(sum(physical_read_bytes_delta)/1024/1024,0) read_mbs, sum(physical_write_requests_delta) write_ios, round(sum(physical_write_bytes_delta)/1024/1024,0) write_mbs,
round(sum(physical_read_bytes_delta)/1024/1024+ sum(physical_write_bytes_delta)/1024/1024,0) MBPs ,
RANK() OVER(
			PARTITION BY trunc(begin_interval_time)
			ORDER BY sum(physical_read_bytes_delta)+ sum(physical_write_bytes_delta) DESC) 
			ios_rank
from dba_hist_sqlstat natural join dba_hist_snapshot
group by trunc(begin_interval_time), module, action, parsing_schema_name)
where ios_rank < 21 
order by 1, 6;

spool off



Prompt Recent top queries (by average elapsed time)

set feedback off;
set linesize 255;
set pagesize 50000;
set timing off;
--
col address                   for a16            heading "Address"
col buffer_gets               for 99,999,999,999 heading "Buffer|Gets";
col buffer_gets_per_exec      for 9,999,999      heading "Buffer|Gets|Per Exec";
col disk_reads                for 999,999,999    heading "Disk|Reads";
col disk_reads_per_exec       for 9,999,999      heading "Disk|Reads|Per Exec";
col elapsed_seconds           for 999,999,999    heading "Elapsed|Seconds";
col elapsed_seconds_per_exec  for 999,999.999    heading "Elapsed|Seconds|Per Exec";
col executions                for 999,999,999    heading "Executions";
col last_load_time            for a20            heading "Last Load Time";
col hash_value                for 9999999999     heading "Hash|Value"
col plan_hash_value           for 9999999999     heading "Plan|Hash|Value"
col rows_processed            for 999,999,999    heading "Rows|Processed";
col rows_processed_per_exec   for 9,999,999      heading "Rows|Processed|Per Exec";
col module                     for a35           heading "Module";
col sql_text                  for a400           heading "SQL Text";
col users_executing          for 999,999          heading "Users Executing";
--
--
alter session set nls_date_format='mm/dd/yyyy hh24:mi:ss';
spool latest_top_queries_avg_elapsed.lst
 
 
select * from (
select
   last_load_time,
   last_active_time,
   sql_id,
   --address,
   --hash_value,
   plan_hash_value,
   executions,
   buffer_gets,
   round(buffer_gets/greatest(executions,1)) buffer_gets_per_exec,
   disk_reads,
   round(disk_reads/greatest(executions,1)) disk_reads_per_exec,
   rows_processed,
   round(rows_processed/greatest(executions,1)) rows_processed_per_exec,
   round(elapsed_time/1000000) elapsed_seconds,
   round(elapsed_time/1000000/greatest(executions,1),3) elapsed_seconds_per_exec,
   sql_text,
   sql_profile,
   module, users_executing,PX_SERVERS_EXECUTIONS
from
   v$sql
where
   last_active_time > sysdate - 1
   order by  round(elapsed_time/1000000/greatest(executions,1),3) desc) where rownum < 120;
spool off



spool latest_top_queries_total_elapsed.lst
 
 
select * from (
select
   last_load_time,
   last_active_time,
   sql_id,
   --address,
   --hash_value,
   plan_hash_value,
   executions,
   buffer_gets,
   round(buffer_gets/greatest(executions,1)) buffer_gets_per_exec,
   disk_reads,
   round(disk_reads/greatest(executions,1)) disk_reads_per_exec,
   rows_processed,
   round(rows_processed/greatest(executions,1)) rows_processed_per_exec,
   round(elapsed_time/1000000) elapsed_seconds,
   round(elapsed_time/1000000/greatest(executions,1),3) elapsed_seconds_per_exec,
   sql_text,
   sql_profile,
   module, users_executing,PX_SERVERS_EXECUTIONS
from
   v$sql
where
   last_active_time > sysdate - 1
   order by  round(elapsed_time/1000000)  desc) where rownum < 120;
spool off


