# Replace with your Workspace ID. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> workspace ID."
$CustomerId = "60ce9b54-7056-42c0-8d92-db98df5549be"

# Replace with your Primary Key. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> primary key."
$SharedKey = "+uxQT1KuYTbq8+flEVGnM+M9cqc6VRPtddFfsrYyYDDYCmX2yGJqrZNyseLrz56NtuZKzlTDIfbqmgVUL9Rf8Q=="

# Specify the name of the record type that you'll be creating
$LogType = "ApiTest09"

# Specify your source directory for CSV file monitoring and destination directory for converting to JSON and submitting to Log Analytics
$SourceDirectory      = "C:\CsvLogs"
$DestinationDirectory = "C:\ApiLogs"

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

# Include the required functions from the original script here:
# Build-Signature, Submit-LogAnalyticsData

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
    
        # Check if the file is already being processed
        if ($FileStatus.ContainsKey($CsvFilePath)) {
            Write-Host "File is already being processed: $CsvFilePath (File ID: $FileId)" -ForegroundColor Yellow
            return
        }
    
        # Add the file to the processing list
        $FileStatus.Add($CsvFilePath, $true)

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
            # Remove the file from the processing list
            $FileStatus.Remove($CsvFilePath)
        }
    }

    Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Changed" -Action $Action
}

Convert-CsvToJson -SourceDirectory $SourceDirectory -DestinationDirectory $DestinationDirectory -CustomerId $CustomerId -SharedKey $SharedKey -LogType $LogType

while ($true) {
    Start-Sleep -Seconds 5
}