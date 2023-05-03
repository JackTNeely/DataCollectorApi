Write-Host "Starting script execution" -ForegroundColor Green

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

# Updated Convert-CsvToJson function
Function Convert-CsvToJson($FileSystemWatcher, $SourceDirectory, $DestinationDirectory, $CustomerId, $SharedKey, $LogType) {
    if (!(Test-Path -Path $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
    }

    $FileSystemWatcher.Path = $SourceDirectory
    $FileSystemWatcher.Filter = "*.csv"
    $FileSystemWatcher.EnableRaisingEvents = $true
    $FileSystemWatcher.IncludeSubdirectories = $false
    $FileSystemWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite

    # Initialize hashtable to track file processing status and debounce timers
    $FileStatus = @{}
    $DebounceTimers = @{}

    $Action = {
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

        $CsvFilePath = $Event.SourceEventArgs.FullPath
        $FileId = [Guid]::NewGuid().ToString()  # Generate unique identifier for the file
        Write-Host "Detected change in file: $CsvFilePath (File ID: $FileId)" -ForegroundColor Cyan
    
        # Check if the file is already being processed
        if ($FileStatus.ContainsKey($CsvFilePath)) {
            Write-Host "File is already being processed: $CsvFilePath (File ID: $FileId)" -ForegroundColor Yellow
            return
        }
    
        # Check if there is an existing debounce timer for the file
        if ($DebounceTimers.ContainsKey($CsvFilePath)) {
            $DebounceTimers[$CsvFilePath].Stop()
            $DebounceTimers[$CsvFilePath].Start()
        } else {
            # Create a new debounce timer for the file
            $DebounceTimers[$CsvFilePath] = New-Object System.Timers.Timer
            $DebounceTimers[$CsvFilePath].AutoReset = $false
            $DebounceTimers[$CsvFilePath].Interval = 2000  # Adjust the debounce interval (milliseconds) as needed
            $DebounceTimers[$CsvFilePath].Elapsed.Add({
                try {
                    # Add the file to the processing list
                    $FileStatus.Add($CsvFilePath, $true)
    
                    # Wait for the CSV file to be fully written and closed
                    Start-Sleep -Seconds 5
    
                    $CsvData = Import-Csv -Path $CsvFilePath
                    $JsonData = $CsvData | ConvertTo-Json
                    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                    $CsvFileName = [System.IO.Path]::GetFileNameWithoutExtension($CsvFilePath)
                    $UniqueIdentifier = (Get-Date).Ticks  # Generate unique identifier
                    $JsonFileName = "{0}-{1}-{2}.json" -f $CsvFileName, $Timestamp, $UniqueIdentifier
                    $JsonFilePath = Join-Path -Path $DestinationDirectory -ChildPath $JsonFileName
    
                    # Check if the JSON file already exists
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
            })
    
            # Start the debounce timer
            $DebounceTimers[$CsvFilePath].Start()
        }
    }

    # Pass the global variables to the $Action scriptblock using the ArgumentList parameter
    Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Changed" -Action $Action -ArgumentList $CustomerId, $SharedKey, $LogType, $DestinationDirectory    
}

# Create a FileSystemWatcher object outside the function
$FileSystemWatcher = New-Object System.IO.FileSystemWatcher

# Call Convert-CsvToJson function
Convert-CsvToJson -FileSystemWatcher $FileSystemWatcher -SourceDirectory $SourceDirectory -DestinationDirectory $DestinationDirectory -CustomerId $CustomerId -SharedKey $SharedKey -LogType $LogType

try {
    while ($true) {
        Start-Sleep -Seconds 5
    }
} finally {
    # Clean up the lock file
    Remove-LockFile
}

test