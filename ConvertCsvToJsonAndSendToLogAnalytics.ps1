# Specify your table name for log file ingestion
$LogType = "New_Api_Test01" # Replace with your table name

# Specify the full path to your CSV file
$CsvFilePath = "C:\CsvLogs\test.csv" # Replace with your CSV file path

# Specify the destination directory for your JSON file to be output
$DestinationDirectory = "C:\ApiLogs" # Replace with your destination directory

# Replace with your Workspace ID. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> workspace ID."
$CustomerId = "<your-customer-ID>"

# Replace with your Primary Key. This is under "Azure Portal -> your Azure Monitor workspace -> Agents -> primary key."
$SharedKey = "<your-primary-key>"

# Convert CSV file to JSON and output to destination directory with timestamp appended to the JSON file name
$CsvData = Import-Csv -Path $CsvFilePath
$JsonData = $CsvData | ConvertTo-Json
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CsvFileName = [System.IO.Path]::GetFileNameWithoutExtension($CsvFilePath)
$JsonFileName = "{0}-{1}.json" -f $CsvFileName, $Timestamp
$JsonFilePath = Join-Path -Path $DestinationDirectory -ChildPath $JsonFileName
$JsonData | Set-Content -Path $JsonFilePath

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

$JsonData | Set-Content -Path $JsonFilePath

$StatusCode = Submit-LogAnalyticsData -CustomerId $CustomerId -SharedKey $SharedKey -Body $JsonData -LogType $LogType

if ($StatusCode -eq 200) {
    Write-Host "Data successfully submitted to Log Analytics. Status code: $StatusCode" -ForegroundColor Green
} else {
    Write-Host "Failed to submit data to Log Analytics. Status code: $StatusCode" -ForegroundColor Red
}
