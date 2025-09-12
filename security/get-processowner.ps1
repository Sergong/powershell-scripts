$allprocesses = get-process 

$mypname = "code"
# $allprocesses | Get-Member
$allprocesses | Where-Object{$_.Name -like "*$mypname*"} | %{
    if ($null -ne $_.Parent){
        write-host "Name            = "$_.Name
        write-host "Product         = "$_.Product
        write-host "Product Version = "$_.ProductVersion
        write-host "Parent          = "$_.Parent
        write-host "`n"
    }
}
