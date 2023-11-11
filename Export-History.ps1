$SubscriptionId = "<SubscriptionId>"
$WorkspaceId = "<WorkspaceId>" #Workspace ID of Sentinel
$Table = "Syslog" #Table to export
$StorageAccountName = "<StorageAccountName>" #Need Storage Blob Data Contributor role on the StorageAccountName
$ContainerName = "syslog-backup" #Name of the Container that will be created in StorageAccountName
$BackInDays = 360 

Connect-AzAccount -Subscription $SubscriptionId 

$AzStorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName  
$WorkingContainer = Get-AzStorageContainer -Context $AzStorageContext | Where-Object { $_.Name -eq $ContainerName }

#Stop if the ContainerName provided already exists 
if( $WorkingContainer ) {
    throw "Sorry, $ContainerName already exist in $StorageAccountName"
}

#Create container
New-AzStorageContainer -Context $AzStorageContext -Name $ContainerName

#Config the log file
$LogFile = New-TemporaryFile 
$LogFileTimeFormat = "yyyy-MM-dd HH:mm:ss"
Write-Output "Time;StartFormated;EndFormated;Query;BlobFile;TempJson;ResultCount;Error" | Out-File $LogFile
$Logs = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new() #Thread-safe collection
Write-Output "LogFile $($LogFile.FullName)"

$PSStyle.Progress.View = 'Classic' #Style for the progress bar
$Now = (Get-Date).Date #Date of reference (Today but starting at 00:00) 

#Loop for all the days until now (-1). You can adjust the -1 to 90 days as long as the BackInDays >90 days too. 
#-$BackInDays .. -1 | ForEach-Object { 
-$BackInDays .. 90 | ForEach-Object {    
    $Day = $_
    $DayTracking = $($Now.AddDays($Day))
    Write-Progress -Activity "Query for $DayTracking" -PercentComplete (( $BackInDays + 1 + $Day ) / $BackInDays * 100 ) -Id 0
    Write-Output "Day $DayTracking"
    0 .. 23 | ForEach-Object {
        $Hour = $_
        #Divide in blocks of 15-minute and run in different workspaces to optimize collection time
        Write-Progress -Activity "Hour $Hour" -PercentComplete (($Hour + 1) / 24 * 100 ) -Id 1 -ParentId 0
        #Can be adjsuted to run for bins of 5-minute if we hit the API limit for bins of 15-minutes
        #0,5,10,15,20,25,30,35,40,45,50,55 | Foreach-Object -ThrottleLimit 6 -Parallel
        0,15,30,45 | Foreach-Object -ThrottleLimit 4 -Parallel {
            $Minute = $_
            $Start = ($using:Now).AddDays($using:Day).AddHours($using:Hour).AddMinutes($Minute)
            $YearNumber = $Start.Year
            $MonthNumber = $Start.Month
            $DayNumber = $Start.Day
            $StartFormated = $Start.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $EndFormated = ($using:Now).AddDays($using:Day).AddHours($using:Hour).AddMinutes($Minute+15).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $Query = "$using:Table | where TimeGenerated between ( datetime('$StartFormated').. datetime('$EndFormated')) | project-away TenantId, MG, Type"
            #Name partitionning to allow easy ADX external table partitionning mapping 
            #$BlobFile = "y=$YearNumber/m=" + "{0:D2}" -f $MonthNumber + "/d=" + "{0:D2}" -f $DayNumber + "/h=" + "{0:D2}" -f $using:Hour + "/m=" + "{0:D2}" -f $Minute + "/backup.json"
            $BlobFile = "y=$YearNumber/m={0:D2}/d={1:D2}/h={2:D2}/m={3:D2}/PT15M.json" -f $MonthNumber, $DayNumber, $using:Hour, $Minute 
            $TempJson = New-TemporaryFile  #To store the results of the query
            $AddToLogs = $using:Logs #Get a reference for writing the Logs
            $Kql = Invoke-AzOperationalInsightsQuery -WorkspaceId $using:WorkspaceId -Query $Query -ErrorAction SilentlyContinue #Silently fails as error mgmt is hectic with that cmdLet
            #If the Kql returns results (-ne $null) and if the errror message is empty (when we exceed the limit in size Kql is set but the error message too)
            if ($Kql -ne $null -and $Kql.Error.Details.InnerError.Message -eq $null) {
                $ResultCount = 0
                $Kql.Results | ForEach-Object {
                    $_ | ConvertTo-Json -Compress | Out-File $TempJson -Append
                    $ResultCount += 1
                }
                if ( $ResultCount -gt 0 ) {
                    #Upload the TempJson into the container
                    $WriteBlob = Set-AzStorageBlobContent -Context $using:AzStorageContext -Container $using:ContainerName -Blob $BlobFile -File $TempJson -Force
                    Write-Output "`tStart: $StartFormated End: $EndFormated - Name: $using:ContainerName/$($WriteBlob.Name) Size:$($WriteBlob.Length) bytes Records: $ResultCount" 
                } else {
                    Write-Output "`tStart: $StartFormated End: $EndFormated - No results, skiping the export."
                }
                Remove-Item  $TempJson #Remove the temp file, even if not uploaded, you can review the log to know which query to retry later
                $AddToLogs.Add("$((Get-Date).ToString($using:LogFileTimeFormat));$StartFormated;$EndFormated;$Query;$BlobFile;$TempJson;$ResultCount;")
            } Else {
                $AddToLogs.Add("$((Get-Date).ToString($using:LogFileTimeFormat));$StartFormated;$EndFormated;$Query;$BlobFile;-;0;$($Kql.Error.Details.InnerError.Message)")
            }
        }
        #Write the logs to disk
        $Logs | Out-File -Append $LogFile  
    }
}

#Open the log file for review
Write-Output "Opening $($LogFile.FullName) for review"
notepad $LogFile.FullName
