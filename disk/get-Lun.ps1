$disks = Get-Disk
$diskInfo = @()
foreach ($disk in $disks){
    $luns = get-WmiObject -Class Win32_DiskDrive | Select-Object SerialNumber, SCSILogicalUnit, SCSIPort, SCSITargetId, Size 
    $lun = $luns | where {$_.SerialNumber -EQ $disk.SerialNumber}
    $driveLetter = (get-disk -Number $disk.Number | Get-Partition | where DriveLetter -Match '^[a-z]$').DriveLetter

    $record = "" | Select-Object DiskNumber, DriveLetter, FriendlyName, LunSerial, LunNumber, LunSizeGB
    $record.FriendlyName = $($disk.FriendlyName)
    $record.DiskNumber = $($disk.Number)
    $record.DriveLetter = $driveLetter
    $record.LunSerial = $lun.SerialNumber
    $record.LunNumber = $lun.SCSILogicalUnit
    $record.LunSizeGB = $lun.Size / 1GB

    $diskInfo += $record
}
$diskInfo | ft