#region classes
class DiscoveryProtocolPacket
{
    [string]$MachineName
    [datetime]$TimeCreated
    [int]$FragmentSize
    [byte[]]$Fragment

    DiscoveryProtocolPacket([string]$MachineName, [datetime]$TimeCreated, [int]$FragmentSize, [byte[]]$Fragment)
    {
        $this.MachineName  = $MachineName
        $this.TimeCreated  = $TimeCreated
        $this.FragmentSize = $FragmentSize
        $this.Fragment     = $Fragment

        Add-Member -InputObject $this -MemberType ScriptProperty -Name IsDiscoveryProtocolPacket -Value {
            if (
                [UInt16]0x2000 -eq [BitConverter]::ToUInt16($this.Fragment[21..20], 0) -or
                [UInt16]0x88CC -eq [BitConverter]::ToUInt16($this.Fragment[13..12], 0)
            ) { return [bool]$true } else { return [bool]$false }
        }

        Add-Member -InputObject $this -MemberType ScriptProperty -Name DiscoveryProtocolType -Value {
            if ([UInt16]0x2000 -eq [BitConverter]::ToUInt16($this.Fragment[21..20], 0)) {
                return [string]'CDP'
            }
            elseif ([UInt16]0x88CC -eq [BitConverter]::ToUInt16($this.Fragment[13..12], 0)) {
                return [string]'LLDP'
            }
            else {
                return [string]::Empty
            }
        }

        Add-Member -InputObject $this -MemberType ScriptProperty -Name SourceAddress -Value {
            [PhysicalAddress]::new($this.Fragment[6..11]).ToString()
        }
    }
}
#endregion

#region function Invoke-DiscoveryProtocolCapture
function Invoke-DiscoveryProtocolCapture {

<#

.SYNOPSIS

    Capture CDP or LLDP packets on local or remote computers

.DESCRIPTION

    Capture discovery protocol packets on local or remote computers. This function will start a packet capture and save the
    captured packets in a temporary ETL file. Only the first discovery protocol packet in the ETL file will be returned.

    Cisco devices will by default send CDP announcements every 60 seconds. Default interval for LLDP packets is 30 seconds.

    Requires elevation (Run as Administrator).
    WinRM and PowerShell remoting must be enabled on the target computer.

.PARAMETER ComputerName

    Specifies one or more computers on which to capture packets. Defaults to $env:COMPUTERNAME.

.PARAMETER Duration

    Specifies the duration for which the discovery protocol packets are captured, in seconds.

    If Type is LLDP, Duration defaults to 32. If Type is CDP or omitted, Duration defaults to 62.

.PARAMETER Type

    Specifies what type of packet to capture, CDP or LLDP. If omitted, both types will be captured,
    but only the first one will be returned.

    If Type is LLDP, Duration defaults to 32. If Type is CDP or omitted, Duration defaults to 62.

.OUTPUTS

    DiscoveryProtocolPacket

.EXAMPLE

    PS C:\> $Packet = Invoke-DiscoveryProtocolCapture -Type CDP -Duration 60
    PS C:\> Get-DiscoveryProtocolData -Packet $Packet

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

.EXAMPLE

    PS C:\> Invoke-DiscoveryProtocolCapture -Computer COMPUTER1 | Get-DiscoveryProtocolData

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

.EXAMPLE

    PS C:\> 'COMPUTER1', 'COMPUTER2' | Invoke-DiscoveryProtocolCapture | Get-DiscoveryProtocolData

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

    Port      : FastEthernet0/2
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 20
    Computer  : COMPUTER2
    Type      : CDP

#>

    [CmdletBinding()]
    [OutputType('DiscoveryProtocolPacket')]
    [Alias('Capture-CDPPacket', 'Capture-LLDPPacket')]
    param(
        [Parameter(Position=0,
            ValueFromPipeline=$true,
            ValueFromPipelineByPropertyName=$true)]
        [Alias('CN', 'Computer')]
        [String[]]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Position=1)]
        [Int16]$Duration = $(if ($Type -eq 'LLDP') { 32 } else { 62 }),

        [Parameter(Position=2)]
        [ValidateSet('CDP', 'LLDP')]
        [String]$Type
    )

    begin {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal $Identity
        if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
            throw 'Invoke-DiscoveryProtocolCapture requires elevation. Please run PowerShell as administrator.'
        }

        if ($MyInvocation.InvocationName -ne $MyInvocation.MyCommand) {
            if ($MyInvocation.InvocationName -eq 'Capture-CDPPacket') { $Type = 'CDP' }
            if ($MyInvocation.InvocationName -eq 'Capture-LLDPPacket') { $Type = 'LLDP' }
            $Warning = '{0} has been deprecated, please use {1}' -f $MyInvocation.InvocationName, $MyInvocation.MyCommand
            Write-Warning $Warning
        }
    }

    process {

        foreach ($Computer in $ComputerName) {

            $sessionParam = @{
                'Verbose'=$VerbosePreference
            }

            $cimParam = @{
                'Verbose'=$VerbosePreference
            }

            $CimSession = $null
            try {
                #$CimSession = New-CimSession -ComputerName $Computer -ErrorAction Stop
            } catch {
                #Write-Warning "Unable to create CimSession. Please make sure WinRM and PSRemoting is enabled on $Computer."
                #continue
            }

            if ($CimSession) {
                $cimParam.Add('CimSession',$CimSession)
            }

            $PSSession = $null 
            if ($Computer -notlike $env:COMPUTERNAME) {
                New-PSSession -ComputerName $Computer
            }
            if ($PSSession) {
                $sessionParam.Add('Session',$PSSession)
            }

            $ETLFilePath = Invoke-Command @sessionParam -ScriptBlock {
                $TempFile = New-TemporaryFile
                $ETLFile = Rename-Item -Path $TempFile.FullName -NewName $TempFile.FullName.Replace('.tmp', '.etl') -PassThru
                $ETLFile.FullName
            }

            $Adapter = Get-NetAdapter @cimParam -Physical |
                Where-Object {$_.Status -eq 'Up' -and $_.InterfaceType -eq 6} |
                Select-Object -First 1 Name, MacAddress

            $MACAddress = [PhysicalAddress]::Parse($Adapter.MacAddress).ToString()

            if ($Adapter) {
                $SessionName = 'Capture-{0}' -f (Get-Date).ToString('s')
                New-NetEventSession -Name $SessionName -LocalFilePath $ETLFilePath -CaptureMode SaveToFile @cimParam | Out-Null

                $LinkLayerAddress = switch ($Type) {
                    'CDP'   { '01-00-0c-cc-cc-cc' }
                    'LLDP'  { '01-80-c2-00-00-0e', '01-80-c2-00-00-03', '01-80-c2-00-00-00' }
                    Default { '01-00-0c-cc-cc-cc', '01-80-c2-00-00-0e', '01-80-c2-00-00-03', '01-80-c2-00-00-00' }
                }

                $PacketCaptureParams = @{
                    SessionName      = $SessionName
                    TruncationLength = 0
                    CaptureType      = 'Physical'
                    LinkLayerAddress = $LinkLayerAddress
                }
                if ($CimSession) {
                    $PacketCaptureParams.Add('CimSession', $CimSession)
                }

                Add-NetEventPacketCaptureProvider @PacketCaptureParams | Out-Null
                Add-NetEventNetworkAdapter -Name $Adapter.Name -PromiscuousMode $True @cimParam | Out-Null

                Start-NetEventSession -Name $SessionName @cimParam

                $Seconds = $Duration
                $End = (Get-Date).AddSeconds($Seconds)
                while ($End -gt (Get-Date)) {
                    $SecondsLeft = $End.Subtract((Get-Date)).TotalSeconds
                    $Percent = ($Seconds - $SecondsLeft) / $Seconds * 100
                    Write-Progress -Activity "Discovery Protocol Packet Capture" -Status "Capturing on $Computer..." -SecondsRemaining $SecondsLeft -PercentComplete $Percent
                    [System.Threading.Thread]::Sleep(500)
                }

                Stop-NetEventSession -Name $SessionName @cimParam

                $Events = Invoke-Command @sessionParam -ScriptBlock {
                    $Events = Get-WinEvent -Path $ETLFilePath -Oldest -FilterXPath "*[System[EventID=1001]]"

                    [string[]]$XpathQueries = @(
                        "Event/EventData/Data[@Name='FragmentSize']"
                        "Event/EventData/Data[@Name='Fragment']"
                    )

                    $PropertySelector = [System.Diagnostics.Eventing.Reader.EventLogPropertySelector]::new($XpathQueries)

                    foreach ($Event in $Events) {
                        $EventData = $Event | Select-Object MachineName, TimeCreated
                        $EventData | Add-Member -NotePropertyName FragmentSize -NotePropertyValue $null
                        $EventData | Add-Member -NotePropertyName Fragment -NotePropertyValue $null
                        $EventData.FragmentSize, $EventData.Fragment = $Event.GetPropertyValues($PropertySelector)
                        $EventData
                    }
                }

                $FoundPacket = $null

                foreach ($Event in $Events) {
                    $Packet = [DiscoveryProtocolPacket]::new(
                        $Event.MachineName,
                        $Event.TimeCreated,
                        $Event.FragmentSize,
                        $Event.Fragment
                    )

                    if ($Packet.IsDiscoveryProtocolPacket -and $Packet.SourceAddress -ne $MACAddress) {
                        $FoundPacket = $Packet
                        break
                    }
                }

                Remove-NetEventSession -Name $SessionName @cimParam

                Invoke-Command @sessionParam -ScriptBlock {
                    Remove-Item -Path $ETLFilePath -Force
                }

                if ($PSSession) {
                    Remove-PSSession @sessionParam
                }

                if ($FoundPacket) {
                    $FoundPacket
                } else {
                    Write-Warning "No discovery protocol packets captured on $Computer in $Seconds seconds."
                    return
                }
            } else {
                Write-Warning "Unable to find a connected wired adapter on $Computer."
                return
            }
        }
    }

    end {}
}
#endregion

#region function Get-DiscoveryProtocolData
function Get-DiscoveryProtocolData {

<#

.SYNOPSIS

    Parse CDP or LLDP packets captured by Invoke-DiscoveryProtocolCapture

.DESCRIPTION

    Gets computername, type and packet details from a DiscoveryProtocolPacket.

    Calls ConvertFrom-CDPPacket or ConvertFrom-LLDPPacket to extract packet details
    from a byte array.

.PARAMETER Packet

    Specifies an object of type DiscoveryProtocolPacket.

.EXAMPLE

    PS C:\> $Packet = Invoke-DiscoveryProtocolCapture
    PS C:\> Get-DiscoveryProtocolData -Packet $Packet

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

.EXAMPLE

    PS C:\> Invoke-DiscoveryProtocolCapture -Computer COMPUTER1 | Get-DiscoveryProtocolData

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

.EXAMPLE

    PS C:\> 'COMPUTER1', 'COMPUTER2' | Invoke-DiscoveryProtocolCapture | Get-DiscoveryProtocolData

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10
    Computer  : COMPUTER1
    Type      : CDP

    Port      : FastEthernet0/2
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 20
    Computer  : COMPUTER2
    Type      : CDP

#>

    [CmdletBinding()]
    [Alias('Parse-CDPPacket', 'Parse-LLDPPacket')]
    param(
        [Parameter(Position=0,
            Mandatory=$true,
            ValueFromPipeline=$true,
            ValueFromPipelineByPropertyName=$true)]
        [DiscoveryProtocolPacket[]]
        $Packet
    )

    begin {
        if ($MyInvocation.InvocationName -ne $MyInvocation.MyCommand) {
            $Warning = '{0} has been deprecated, please use {1}' -f $MyInvocation.InvocationName, $MyInvocation.MyCommand
            Write-Warning $Warning
        }
    }

    process {
        foreach ($item in $Packet) {
            switch ($item.DiscoveryProtocolType) {
                'CDP'   { $PacketData = ConvertFrom-CDPPacket -Packet $item.Fragment }
                'LLDP'  { $PacketData = ConvertFrom-LLDPPacket -Packet $item.Fragment }
                Default { throw 'No valid CDP or LLDP found in $Packet' }
            }

            $PacketData | Add-Member -NotePropertyName Computer -NotePropertyValue $item.MachineName
            $PacketData | Add-Member -NotePropertyName Type -NotePropertyValue $item.DiscoveryProtocolType
            $PacketData
        }
    }

    end {}
}
#endregion

#region function ConvertFrom-CDPPacket
function ConvertFrom-CDPPacket {

<#

.SYNOPSIS

    Parse CDP packet.

.DESCRIPTION

    Parse CDP packet to get port, device, model, ipaddress and vlan.

    This function is used by Get-DiscoveryProtocolData to parse the
    Fragment property of a DiscoveryProtocolPacket object.

.PARAMETER Packet

    Raw CDP packet as byte array.

    This function is used by Get-DiscoveryProtocolData to parse the
    Fragment property of a DiscoveryProtocolPacket object.

.EXAMPLE

    PS C:\> $Packet = Invoke-DiscoveryProtocolCapture -Type CDP
    PS C:\> ConvertFrom-CDPPacket -Packet $Packet.Fragment

    Port      : FastEthernet0/1
    Device    : SWITCH1.domain.example
    Model     : cisco WS-C2960-48TT-L
    IPAddress : 192.0.2.10
    VLAN      : 10

#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,
            Mandatory=$true)]
        [byte[]]$Packet
    )

    begin {}

    process {

        $Offset = 26
        $Hash = @{}

        while ($Offset -lt ($Packet.Length - 4)) {

            $Type   = [BitConverter]::ToUInt16($Packet[($Offset + 1)..$Offset], 0)
            $Length = [BitConverter]::ToUInt16($Packet[($Offset + 3)..($Offset + 2)], 0)

            switch ($Type)
            {
                1  { $Hash.Add('Device',    [System.Text.Encoding]::ASCII.GetString($Packet[($Offset + 4)..($Offset + $Length)])) }
                3  { $Hash.Add('Port',      [System.Text.Encoding]::ASCII.GetString($Packet[($Offset + 4)..($Offset + $Length)])) }
                6  { $Hash.Add('Model',     [System.Text.Encoding]::ASCII.GetString($Packet[($Offset + 4)..($Offset + $Length)])) }
                10 { $Hash.Add('VLAN',      [BitConverter]::ToUInt16($Packet[($Offset + 5)..($Offset + 4)], 0)) }
                22 { $Hash.Add('IPAddress', ([System.Net.IPAddress][byte[]]$Packet[($Offset + 13)..($Offset + 16)]).IPAddressToString) }
            }

            if ($Length -eq 0 ) {
                $Offset = $Packet.Length
            }

            $Offset = $Offset + $Length

        }

        return [PSCustomObject]$Hash

    }

    end {}

}
#endregion

#region function ConvertFrom-LLDPPacket
function ConvertFrom-LLDPPacket {

<#

.SYNOPSIS

    Parse LLDP packet.

.DESCRIPTION

    Parse LLDP packet to get port, description, device, model, ipaddress and vlan.

.PARAMETER Packet

    Raw LLDP packet as byte array.

    This function is used by Get-DiscoveryProtocolData to parse the
    Fragment property of a DiscoveryProtocolPacket object.

.EXAMPLE

    PS C:\> $Packet = Invoke-DiscoveryProtocolCapture -Type LLDP
    PS C:\> ConvertFrom-LLDPPacket -Packet $Packet.Fragment

    Model       : WS-C2960-48TT-L
    Description : HR Workstation
    VLAN        : 10
    Port        : Fa0/1
    Device      : SWITCH1.domain.example
    IPAddress   : 192.0.2.10

#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,
            Mandatory=$true)]
        [byte[]]$Packet
    )

    begin {
        $TlvType = @{
            PortId               = 2
            PortDescription      = 4
            SystemName           = 5
            ManagementAddress    = 8
            OrganizationSpecific = 127
        }
    }

    process {

        $Destination = [PhysicalAddress]::new($Packet[0..5])
        $Source      = [PhysicalAddress]::new($Packet[6..11])
        $LLDP        = [BitConverter]::ToUInt16($Packet[13..12], 0)

        Write-Verbose "Destination: $Destination"
        Write-Verbose "Source: $Source"
        Write-Verbose "LLDP: $LLDP"

        $Offset = 14
        $Mask = 0x01FF
        $Hash = @{}

        while ($Offset -lt $Packet.Length)
        {
            $Type = $Packet[$Offset] -shr 1
            $Length = [BitConverter]::ToUInt16($Packet[($Offset + 1)..$Offset], 0) -band $Mask
            $Offset += 2

            switch ($Type)
            {
                $TlvType.PortId {
                    $Subtype = $Packet[($Offset)]

                    if ($SubType -in (1, 2, 5, 6, 7)) {
                        $Hash.Add('Port', [System.Text.Encoding]::ASCII.GetString($Packet[($Offset + 1)..($Offset + $Length - 1)]))
                    }

                    if ($Subtype -eq 3) {
                        $Hash.Add('Port', [PhysicalAddress]::new($Packet[($Offset + 1)..($Offset + $Length - 1)]))
                    }

                    $Offset += $Length
                    break
                }

                $TlvType.PortDescription {
                    $Hash.Add('Description', [System.Text.Encoding]::ASCII.GetString($Packet[$Offset..($Offset + $Length - 1)]))
                    $Offset += $Length
                    break
                }

                $TlvType.SystemName {
                    $Hash.Add('Device', [System.Text.Encoding]::ASCII.GetString($Packet[$Offset..($Offset + $Length - 1)]))
                    $Offset += $Length
                    break
                }

                $TlvType.ManagementAddress {
                    $AddrLen = $Packet[($Offset)]
                    $Subtype = $Packet[($Offset + 1)]

                    if ($Subtype -eq 1)
                    {
                        $Hash.Add('IPAddress', ([System.Net.IPAddress][byte[]]$Packet[($Offset + 2)..($Offset + $AddrLen)]).IPAddressToString)
                    }

                    $Offset += $Length
                    break
                }

                $TlvType.OrganizationSpecific {
                    $OUI = [System.BitConverter]::ToString($Packet[($Offset)..($Offset + 2)])

                    if ($OUI -eq '00-12-BB') {
                        $Subtype = $Packet[($Offset + 3)]
                        if ($Subtype -eq 10) {
                            $Hash.Add('Model', [System.Text.Encoding]::ASCII.GetString($Packet[($Offset + 4)..($Offset + $Length - 1)]))
                            $Offset += $Length
                            break
                        }
                    }

                    if ($OUI -eq '00-80-C2') {
                        $Subtype = $Packet[($Offset + 3)]
                        if ($Subtype -eq 1) {
                            $Hash.Add('VLAN', [BitConverter]::ToUInt16($Packet[($Offset + 5)..($Offset + 4)], 0))
                            $Offset += $Length
                            break
                        }
                    }

                    $Tlv = [PSCustomObject] @{
                        Type = $Type
                        Value = [System.Text.Encoding]::ASCII.GetString($Packet[$Offset..($Offset + $Length)])
                    }
                    Write-Verbose $Tlv
                    $Offset += $Length
                    break
                }

                default {
                    $Tlv = [PSCustomObject] @{
                        Type = $Type
                        Value = [System.Text.Encoding]::ASCII.GetString($Packet[$Offset..($Offset + $Length)])
                    }
                    Write-Verbose $Tlv
                    $Offset += $Length
                    break
                }
            }
        }
        [PSCustomObject]$Hash
    }

    end {}
}
#endregion

#region function Export-Pcap
function Export-Pcap {

<#

.SYNOPSIS

    Export packets to pcap

.DESCRIPTION

    Export packets, captured using Invoke-DiscoveryProtocolCapture, to pcap format.

.PARAMETER Packet

    Specifies one or more objects of type DiscoveryProtocolPacket.

.PARAMETER Path

    Relative or absolute path to pcap file.

.PARAMETER Invoke

    If Invoke is set, exported file is opened in the program associated with pcap files.

.EXAMPLE

    PS C:\> $Packet = Invoke-DiscoveryProtocolCapture
    PS C:\> Export-Pcap -Packet $Packet -Path C:\Windows\Temp\captures.pcap -Invoke

    Export captured packet to C:\Windows\Temp\captures.pcap and open file in
    the program associated with pcap files.

.EXAMPLE

    PS C:\> 'COMPUTER1', 'COMPUTER2' | Invoke-DiscoveryProtocolCapture | Export-Pcap -Path captures.pcap

    Export captured packets to captures.pcap in current directory. Export-Pcap supports input from pipeline.

#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true,
            ValueFromPipeline=$true,
            ValueFromPipelineByPropertyName=$true)]
        [DiscoveryProtocolPacket[]]$Packet,

        [Parameter(Mandatory=$true)]
        [ValidateScript({
            if ([System.IO.Path]::IsPathRooted($_)) {
                $AbsolutePath = $_
            } else {
                $AbsolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_)
            }
            if (-not(Test-Path (Split-Path $AbsolutePath -Parent))) {
                throw "Folder does not exist"
            }
            if ($_ -notmatch '\.pcap$') {
                throw "Extension must be pcap"
            }
            return $true
        })]
        [System.IO.FileInfo]$Path,

        [Parameter(Mandatory=$false)]
        [switch]$Invoke
    )

    begin {
        [uint32]$magicNumber = '0xa1b2c3d4'
        [uint16]$versionMajor = 2
        [uint16]$versionMinor = 4
        [int32] $thisZone = 0
        [uint32]$sigFigs = 0
        [uint32]$snapLen = 65536
        [uint32]$network = 1

        $stream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter $stream

        $writer.Write($magicNumber)
        $writer.Write($versionMajor)
        $writer.Write($versionMinor)
        $writer.Write($thisZone)
        $writer.Write($sigFigs)
        $writer.Write($snapLen)
        $writer.Write($network)
    }

    process {
        foreach ($item in $Packet) {
            [uint32]$tsSec = ([DateTimeOffset]$item.TimeCreated).ToUnixTimeSeconds()
            [uint32]$tsUsec = $item.TimeCreated.Millisecond
            [uint32]$inclLen = $item.FragmentSize
            [uint32]$origLen = $inclLen

            $writer.Write($tsSec)
            $writer.Write($tsUsec)
            $writer.Write($inclLen)
            $writer.Write($origLen)
            $writer.Write($item.Fragment)
        }
    }

    end {
        $bytes = $stream.ToArray()

        $stream.Dispose()
        $writer.Dispose()

        if (-not([System.IO.Path]::IsPathRooted($Path))) {
            $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        }

        [System.IO.File]::WriteAllBytes($Path, $bytes)

        if ($Invoke) {
            Invoke-Item -Path $Path
        }
    }
}
#endregion
