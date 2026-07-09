# Windows: Get Hardware ID for whitelisting
Get-PnpDevice -Class USB | Where-Object { $_.Status -eq "OK" } | Select-Object FriendlyName, InstanceId, HardwareID
