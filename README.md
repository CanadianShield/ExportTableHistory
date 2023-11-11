## Export historical data from Log Analtyics to a Blob Container

Scenario used for this proof of concept: You have data retention set to 360 days (or any number of days > 90 days) in your workpace (or on a specific table). You want to reduce that number to 90 days as a way to limit cost of retention. But you want to keep the data you have for your current retention period for compliance reasons or for hunting scenarios.

The script [`Export-History.ps1`](https://github.com/CanadianShield/ExportTableHistory/blob/main/Export-History.ps1) is creating a blob container on a specified Storage Account on which you have the Storage Blob Data Contributor role. Because the Log Analytics API has [some limits][(://learn.microsoft.com/en-us/azure/azure-monitor/service-limits#log-analytics-workspaces), the script will split the historical data in bin of 15 minutes, download the results and upload it to a container you specified. 

It also generates a log file in a CSV format:
```
Time;StartFormated;EndFormated;Query;BlobFile;TempJson;ResultCount;Error
2023-11-10 20:33:08;2023-11-09T00:45:00Z;2023-11-09T01:00:00Z;Syslog | where TimeGenerated between ( datetime('2023-11-09T00:45:00Z').. datetime('2023-11-09T01:00:00Z')) | project-away TenantId, MG, Type;y=2023/m=11/d=09/h=00/m=45/backup.json;C:\Users\piaudonn\AppData\Local\Temp\tmp2159.tmp;65;
2023-11-10 20:33:08;2023-11-09T00:15:00Z;2023-11-09T00:30:00Z;Syslog | where TimeGenerated between ( datetime('2023-11-09T00:15:00Z').. datetime('2023-11-09T00:30:00Z')) | project-away TenantId, MG, Type;y=2023/m=11/d=09/h=00/m=15/backup.json;C:\Users\piaudonn\AppData\Local\Temp\tmp2148.tmp;3;
2023-11-10 20:33:08;2023-11-09T00:30:00Z;2023-11-09T00:45:00Z;Syslog | where TimeGenerated between ( datetime('2023-11-09T00:30:00Z').. datetime('2023-11-09T00:45:00Z')) | project-away TenantId, MG, Type;y=2023/m=11/d=09/h=00/m=30/backup.json;C:\Users\piaudonn\AppData\Local\Temp\tmp215A.tmp;8;
```
Note that the log might not be ordered by time, you can use any CSV viewer to order and display the things you want (like Excel).

## Use the data from Azure Data Explorer

You can create a SAS to access the container with the historical data (with `Read` and `List` rights) with an external table in ADX (adjust the name of the table and the schema if necessary):

```
.create-or-alter external table SyslogArchive (TimeGenerated:datetime, EventTime:datetime, SourceSystem:string, Computer:string, Facility:string, HostName:string, SeverityLevel:string, SyslogMessage:string, ProcessID:string, HostIP:string, ProcessName:string, CollectorHostName:string, _ResourceId:string)
    kind=storage 
    partition by (Date:datetime = bin(TimeGenerated, 15m))
    pathformat = (datetime_pattern ("y={yyyy}/m={MM}/d={dd}/h={HH}/m={mm}", Date))
    dataformat = json 
    (
        h@"https://seen.blob.core.windows.net/syslog-backup?sv=2021-10-04&st=2023-11-11T01%3A18%3A13Z&se=2023-11-12T01%3A18%3A13Z&sr=c&sp=rl&sig=<SIG>"
    )
```
Then you can access the data with the `external_table` function:

```
external_table('SyslogArchive')
| where TimeGenerated > ago(180d)
| summarize count(), min(TimeGenerated), max(TimeGenerated)
```

If you already have a table with simmilar data, you can union the two in a parser (function):
```
union external_table('SyslogArchive'), Syslog
```
