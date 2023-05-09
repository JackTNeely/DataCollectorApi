# This version of the script works, but has an issue where duplicate JSON files are sometimes created.
# For example, if lines are removed from the end of a CSV file using PowerShell like this:
# (Get-Content -Path "C:\CsvLogs\test.csv" | Select-Object -First ((Get-Content -Path "C:\CsvLogs\test.csv").Count - 1)) | Out-File -FilePath "C:\CsvLogs\test.csv" -Encoding UTF8
# then a duplicate JSON file is created.

# Specify your table name
$LogType = "<your-table-name>"

# Specify your source directory for CSV file monitoring and destination directory for converting to JSON and submitting to Log Analytics
$SourceDirectory      = "C:\CsvLogs" # replace with your source directory
$DestinationDirectory = "C:\ApiLogs" # replace with your destination directory

# Replace with your Workspace ID. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> workspace ID."
$CustomerId = "<your-customer-ID>"

# Replace with your Primary Key. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> primary key."
$SharedKey = "<your-primary-key>"

# Lock file path
$LockFilePath = "C:\ApiLogs\lock.txt"

# Check if the script is already running
if (Test-Path -Path $LockFilePath) {
    Write-Host "Script is already running." -ForegroundColor Yellow
    exit
}

# Create the lock file
try {
    New-Item -Path $LockFilePath -ItemType File -Force | Out-Null
}
catch {
    Write-Host "Failed to create the lock file." -ForegroundColor Red
    exit
}

# Function to remove the lock file
function Remove-LockFile {
    if (Test-Path -Path $LockFilePath) {
        Remove-Item -Path $LockFilePath -Force | Out-Null
    }
}

# Trap the script exit and remove the lock file
trap {
    Remove-LockFile
    exit
}

$DebounceTime = 5 # Time in seconds to wait after the last detected event

# Create the function to create the authorization signature
Function Build-Signature ($CustomerId, $SharedKey, $Date, $ContentLength, $Method, $ContentType, $Resource)
{
    $XHeaders = "x-ms-date:" + $Date
    $StringToHash = $Method + "`n" + $ContentLength + "`n" + $ContentType + "`n" + $XHeaders + "`n" + $Resource

    $BytesToHash = [Text.Encoding]::UTF8.GetBytes($StringToHash)
    $KeyBytes = [Convert]::FromBase64String($SharedKey)

    $Sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $Sha256.Key = $KeyBytes
    $CalculatedHash = $Sha256.ComputeHash($BytesToHash)
    $EncodedHash = [Convert]::ToBase64String($CalculatedHash)
    $Authorization = 'SharedKey {0}:{1}' -f $CustomerId,$EncodedHash
    return $Authorization
}

# Create the function to create and post the request
Function Submit-LogAnalyticsData($CustomerId, $SharedKey, $Body, $LogType) {
    $Method = "POST"
    $ContentType = "application/json"
    $Resource = "/api/logs"
    $Rfc1123Date = [DateTime]::UtcNow.ToString("r")
    $ContentLength = ([System.Text.Encoding]::UTF8.GetBytes($Body)).Length
    $Signature = Build-Signature `
        -CustomerId $CustomerId `
        -SharedKey $SharedKey `
        -Date $Rfc1123Date `
        -ContentLength $ContentLength `
        -Method $Method `
        -ContentType $ContentType `
        -Resource $Resource
    $Uri = "https://" + $CustomerId + ".ods.opinsights.azure.com" + $Resource + "?api-version=2016-04-01"

    $Headers = @{
        "Authorization" = $Signature;
        "Log-Type" = $LogType;
        "x-ms-date" = $Rfc1123Date;
    }

    $Response = Invoke-WebRequest -Uri $Uri -Method $Method -ContentType $ContentType -Headers $Headers -Body $Body -UseBasicParsing
    return $Response.StatusCode
}

Function Convert-CsvToJson($SourceDirectory, $DestinationDirectory, $CustomerId, $SharedKey, $LogType) {
    if (!(Test-Path -Path $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
    }

    $FileSystemWatcher = New-Object System.IO.FileSystemWatcher
    $FileSystemWatcher.Path = $SourceDirectory
    $FileSystemWatcher.Filter = "*.csv"
    $FileSystemWatcher.EnableRaisingEvents = $true
    $FileSystemWatcher.IncludeSubdirectories = $false
    $FileSystemWatcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite

    # Initialize hashtable to track file processing status
    $FileStatus = @{}

    $Action = {
        $CsvFilePath = $Event.SourceEventArgs.FullPath
        $FileId = [Guid]::NewGuid().ToString()  # Generate unique identifier for the file
        Write-Host "Detected change in file: $CsvFilePath (File ID: $FileId)" -ForegroundColor Cyan
    
        # Check if the file is already being processed or if the debounce time has not passed
        $CurrentTime = Get-Date
        if ($FileStatus.ContainsKey($CsvFilePath) -and (($CurrentTime - $FileStatus[$CsvFilePath]).TotalSeconds -lt $DebounceTime)) {
            Write-Host "File is already being processed or debounce time has not passed: $CsvFilePath (File ID: $FileId)" -ForegroundColor Yellow
            return
        }
    
        # Update the file event timestamp in the processing list
        $FileStatus[$CsvFilePath] = $CurrentTime
    
        try {
            # Wait for the CSV file to be fully written and closed
            Start-Sleep -Seconds 5
    
            $CsvData = Import-Csv -Path $CsvFilePath
            $JsonData = $CsvData | ConvertTo-Json
            $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $CsvFileName = [System.IO.Path]::GetFileNameWithoutExtension($CsvFilePath)
            $UniqueIdentifier = (Get-Date).Ticks  # Generate unique identifier
            $JsonFileName = "{0}-{1}-{2}.json" -f $CsvFileName, $Timestamp, $UniqueIdentifier
            $JsonFilePath = Join-Path -Path $DestinationDirectory -ChildPath $JsonFileName
    
            if (Test-Path -Path $JsonFilePath) {
                Write-Host "JSON file with the same name already exists: $JsonFilePath. `nUnique ID: $UniqueIdentifier" -ForegroundColor Yellow
            } else {
                $JsonData | Set-Content -Path $JsonFilePath
                Write-Host "Created JSON file: $JsonFilePath. `nUnique ID: $UniqueIdentifier" -ForegroundColor Cyan
    
                $StatusCode = Submit-LogAnalyticsData -CustomerId $CustomerId -SharedKey $SharedKey -Body $JsonData -LogType $LogType
                if ($StatusCode -eq 200) {
                    Write-Host "Data successfully submitted to Log Analytics. Status code: $StatusCode" -ForegroundColor Green
                } else {
                    Write-Host "Failed to submit data to Log Analytics. Status code: $StatusCode" -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "An error occurred while processing the file: $CsvFilePath" -ForegroundColor Red
            Write-Host "Error: $_" -ForegroundColor Red
        } finally {
            # No changes in the finally block
        }
    }    

    # Use only the "Changed" event
    Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Changed" -Action $Action
}

Convert-CsvToJson -SourceDirectory $SourceDirectory -DestinationDirectory $DestinationDirectory -CustomerId $CustomerId -SharedKey $SharedKey -LogType $LogType

while ($true) {
    Start-Sleep -Seconds 5
}
