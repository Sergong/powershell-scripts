<#
  Simple function to get a human readable directory listing
#>
function Get-Dir {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    function Get-HumanReadableSize {
        param([long]$bytes)

        switch -regex ($bytes) {
            { $_ -ge 1GB } { return "{0,10:N2} GB" -f ($bytes / 1GB) }
            { $_ -ge 1MB } { return "{0,10:N2} MB" -f ($bytes / 1MB) }
            { $_ -ge 1KB } { return "{0,10:N2} KB" -f ($bytes / 1KB) }
            default { return "{0,10} Bytes" -f $bytes }
        }
    }

    if (Test-Path $Path) {
        # Create custom object with pre-formatted size string
        $items = Get-ChildItem -Path $Path | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Size = Get-HumanReadableSize $_.Length
            }
        }

        # Output with Format-Table and manual column width for header alignment
        $items | Format-Table -Property @{Label="Name";Expression={$_.Name}}, @{Label="Size".PadLeft(10);Expression={$_.Size}} -AutoSize
    }
    else {
        Write-Error "The path '$Path' does not exist."
    }
}

