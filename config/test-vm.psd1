@{
    Name                           = 'Windows11-Pro-Test'
    ComputerName                   = 'WIN11-TEST'
    ProcessorCount                 = 4
    MemoryBytes                    = 8GB
    DiskBytes                      = 80GB
    AccountName                    = 'vmadmin'
    TimeZone                       = 'UTC'
    # The baseline VM has a disconnected network adapter and static memory.
    # Guest Hyper-V/WSL tests need the host virtualization extensions exposed.
    ExposeVirtualizationExtensions = $true
}
