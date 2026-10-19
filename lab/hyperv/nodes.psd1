@{
    # VM disks, images and seed ISOs live here, outside the repo.
    Root      = 'C:\IronCloud'
    NatPrefix = '10.20.0.0/16'
    DnsServers = @('1.1.1.1', '8.8.8.8')

    # First switch is management (VM default route), second is the Neutron provider network.
    Switches = @(
        @{ Name = 'IronCloud-Mgmt';     HostIp = '10.20.0.1' }
        @{ Name = 'IronCloud-Provider'; HostIp = '10.20.1.1' }
    )

    # MACs are locally administered (02:...) so they never collide with Hyper-V's dynamic pool.
    Nodes = @(
        @{ Name = 'ctl1'; Cpu = 4; MemoryGB = 9;  OsDiskGB = 40; OsdDiskGB = 15; MgmtIp = '10.20.0.11'; MgmtMac = '022000000011'; ProviderMac = '022000000111'; ServiceMac = '022000000211' }
        @{ Name = 'cmp1'; Cpu = 4; MemoryGB = 4;  OsDiskGB = 25; OsdDiskGB = 15; MgmtIp = '10.20.0.12'; MgmtMac = '022000000012'; ProviderMac = '022000000112' }
        @{ Name = 'cmp2'; Cpu = 4; MemoryGB = 4;  OsDiskGB = 25; OsdDiskGB = 15; MgmtIp = '10.20.0.13'; MgmtMac = '022000000013'; ProviderMac = '022000000113' }
    )
}
