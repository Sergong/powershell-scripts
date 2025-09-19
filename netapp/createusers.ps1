<#
  Wrapper script to create users
  Must be in the same directory as the Create-DynamicHomeDirectories.ps1 script.
#>

.\Create-DynamicHomeDirectories.ps1 -ClusterName "cluster1.company.com" `
                                    -SVMName "svm_cifs" `
                                    -VolumeName "user_homes" `
                                    -AggregateName "aggr1" `
                                    -VolumeSize "10GB" `
                                    -Domain "COMPANY" `
                                    -UserList @("jsmith","bmiller","sthomas")
