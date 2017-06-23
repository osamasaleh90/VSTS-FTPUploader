param(
    [string][Parameter(Mandatory=$true)]$sourcePath,
    [string][Parameter(Mandatory=$true)]$serverName,
    [string][Parameter(Mandatory=$true)]$username,
    [string][Parameter(Mandatory=$true)]$password,
    [string][Parameter(Mandatory=$true)]$remotePath,
    [string][Parameter(Mandatory=$true)]$useBinary,
    [string]$excludeFilter,
    [string]$ignoreUnchangedFiles,
    [string][Parameter(Mandatory=$true)]$deleteOldFiles,
    [string][Parameter(Mandatory=$true)]$deploymentFilesOnly
)

Write-Verbose "Starting FTPUpload Script" -Verbose
Write-Verbose "sourcePath = $sourcePath" -Verbose
Write-Verbose "username = $username" -Verbose
Write-Verbose "serverName = $serverName" -Verbose
Write-Verbose "remotePath = $remotePath" -Verbose
Write-Verbose "useBinary = $useBinary" -Verbose
Write-Verbose "ignoreUnchangedFiles = $ignoreUnchangedFiles" -Verbose
Write-Verbose "deleteOldFiles = $deleteOldFiles" -Verbose
Write-Verbose "deploymentFilesOnly = $deploymentFilesOnly" -Verbose


function Upload-File {
    Param ($Path, $File, $Filename)

    Write-Host $Filename
    Add-FTPItem -Path $Path -LocalPath $File.FullName -Overwrite -RemoteFileName $Filename
}

function Has-Changes {
    Param ($Path, $File, $Filename)

    $FtpPath = $Path + $Filename

    # Check and compare file sizes locally and remotally
    $RemoteSize = Get-FTPItemSize -Path $FtpPath
    if ([int]$RemoteSize -ne [int]$File.Length) {
        return $true;
    }

    # Check and compare modification dates locally and remotally
    $RemoteDate = Get-FTPItemTimestamp -Path $FtpPath
    if ([DateTime]$RemoteDate -lt [DateTime]$File.LastWriteTime) {
        return $true;
    }

    # if all the same, understand that this file has no changes
    return $false;
}

function Is-Deployment-File {
    Param ($name)
    
    if ($name.ToLower().StartsWith('/obj/') -eq $true) {
        return $false
    }

    if ($name.ToLower().StartsWith('/my project/') -eq $true) {
        return $false
    }

    # Retrieving the filee xstension
    $fileExtension = [System.IO.Path]::GetExtension($name).toLower()

    # Checking to see if known extensions are found.
    if ($fileExtension -eq '.vb') { return $false }
    if ($fileExtension -eq '.cs') { return $false }
    if ($fileExtension -eq '.vbproj') { return $false }
    if ($fileExtension -eq '.csproj') { return $false }
    if ($fileExtension -eq '.user') { return $false }
    if ($fileExtension -eq '.vspscc') { return $false }

    # Extension was not excluded.
    return $true
}

function Create-Directory {
    Param ($directory, $remotePath, $deleteOldFiles)

    Write-Host $directory
    if ($deleteOldFiles -eq $true) {
        Add-FTPDirectory -path $remotePath -NewFolder $directory
    } else {
        Add-FTPDirectory -path $remotePath -NewFolder $directory -SuppressErrors $true
    }    
}

try {
    if ([string]::IsNullOrEmpty($sourcePath) -eq $true) {
        Throw "Mandatory parameter sourcePath is missing. Script halted."
    }

    if ([string]::IsNullOrEmpty($serverName) -eq $true) {
        Throw "Mandatory parameter serverName is missing. Script halted."
    } else {
        if ($serverName.StartsWith("ftp://") -eq $false) {
            $serverName = "ftp://" + $serverName
        }
    }

    if ([string]::IsNullOrEmpty($remotePath) -eq $true) {
        Throw "Mandatory parameter remotePath is empty or missing. Script halted."
    } else {
      if ($remotePath.EndsWith("/") -eq $false) {
        # Make sure that remote path ends with slash.
        $remotePath = $remotePath + "/"
      }
    }
} catch {
    Throw
}

Import-Module -force "$PSScriptRoot\library\PSFTP.psm1"


$Session = $null

if ([string]::IsNullOrEmpty($username) -eq $false) {
    #Encrypts password
    $secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
    $creds = new-object System.Management.Automation.PSCredential($username, $secpasswd)

    # Sets the ftp connection and creates a session
    if ($useBinary -eq $true) {
	    Set-FTPConnection -Credentials $creds -Server $serverName -Session DefaultFTPSession -UsePassive -UseBinary -ignoreCert -KeepAlive
	  } else {
	    Set-FTPConnection -Credentials $creds -Server $serverName -Session DefaultFTPSession -UsePassive -ignoreCert -KeepAlive
	  }
    $Session = Get-FTPConnection -Session DefaultFTPSession
} else {
    if ($useBinary -eq $true) {
    	Set-FTPConnection -Server $serverName -Session DefaultFTPSession -UsePassive -UseBinary -ignoreCert -KeepAlive
    } else {
    	Set-FTPConnection -Server $serverName -Session DefaultFTPSession -UsePassive -ignoreCert -KeepAlive
    }
    $Session = Get-FTPConnection -Session DefaultFTPSession
}

# If flag is set - old destination files are deleted.
if ($deleteOldFiles -eq $true) {
    #Remove-FTPDirectory -path $remotePath -Session $Session
    Remove-FTPItem -Session $Session -Path $remotePath -Recurse 
    Add-FTPDirectory -path $remotePath
}

Write-Host "Creating new directories..."

# Makes sure that the destination folder has all folders created in the correct structure.
# All folders are created.
foreach($dir in (Get-ChildItem -Recurse -path "$sourcePath" | ?{ $_.PSIsContainer })) {
    $directory = $dir.FullName.Substring($sourcePath.Length)
    $directory = [regex]::Replace($directory, '\\', '/')  

    # call for deployment files validation
    if ($deploymentFilesOnly -eq $true) {
        if ((Is-Deployment-File -name $directory) -eq $false) {
            continue
        }
    }

    $parentDir = ($remotePath +  $directory);
    $parentDir = $parentDir.Substring(0, $parentDir.LastIndexOf('/'));

    $alreadyExists = Get-FTPChildItem -path $parentDir -Filter "$directory"

    if(!$alreadyExists) {
        Create-Directory -directory $directory -remotePath $remotePath -deleteOldFiles $deleteOldFiles;
    }
}
	
$fileList = $null

# Finding files that needs to be uploaded.
if ([String]::IsNullOrEmpty($excludeFilter) -eq $false) {
    $fileList = (Get-ChildItem -path "$sourcePath" -Recurse | ? { !$_.PSIsContainer })
} else {
    $fileList = (Get-ChildItem -path "$sourcePath" -Recurse -Exclude $excludeFilter | ? { !$_.PSIsContainer })
}

Write-Host "Uploading files..."

if ($ignoreUnchangedFiles -eq $true) {
    Write-Host "Ignoring unchanged files..."
}

# All files are uploaded.
foreach ($item in $fileList) { 
    $filename = $item.FullName.Substring($sourcePath.Length)
    $filename = [regex]::Replace($filename, '\\', '/')  

    # call for deployment files validation
    if ($deploymentFilesOnly -eq $true) {
        if ((Is-Deployment-File -name $filename) -eq $false) {
            continue
        }
    }

    # call for changed files validation
    if ($ignoreUnchangedFiles -eq $true) {
        if ((Has-Changes -Path $remotePath -File $item -Filename $filename) -eq $false) {
            continue
        }
    }

    # upload the file
    Upload-File -Path $remotePath -File $item -Filename $filename
}