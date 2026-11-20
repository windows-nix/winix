# autounattend.xml for Windows 10 22H2 Pro x64.
#   metal: no disk config (partition by hand, or after disko-windows.nix).
#   vm:    wipes disk 0 into EFI/MSR/C (200 GiB)/D (rest), loads virtio
#          storage drivers from the config CD.
# No password is stored: the local admin is created with an empty password and
# Windows asks for a new one at first logon (spec "No secrets").
{
  lib,
  writeText,
  variant ? "vm",
  user ? "user",
}:
assert lib.elem variant [
  "metal"
  "vm"
];
let
  vm = variant == "vm";
  comp =
    name: body:
    ''<component name="${name}" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">${body}</component>'';

  # Drive letters on the config CD are unknown; scan for apply.cmd.
  copyCmd = ''cmd /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %d:\apply.cmd (robocopy %d:\ C:\ProgramData\machine-config /E &amp; start "" /wait cmd /c C:\ProgramData\machine-config\apply.cmd)'';

  disk = ''
    <DiskConfiguration>
      <Disk wcm:action="add">
        <DiskID>0</DiskID>
        <WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Size>204800</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>4</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>4</Order><PartitionID>4</PartitionID><Format>NTFS</Format><Label>Games</Label><Letter>D</Letter></ModifyPartition>
        </ModifyPartitions>
      </Disk>
    </DiskConfiguration>
    <ImageInstall><OSImage>
      <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
      <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 10 Pro</Value></MetaData></InstallFrom>
    </OSImage></ImageInstall>'';

  # Without a disk section setup still needs the edition; it asks for the target.
  imageOnly = ''
    <ImageInstall><OSImage>
      <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 10 Pro</Value></MetaData></InstallFrom>
    </OSImage></ImageInstall>'';

  # E:..Z: cover wherever the config CD lands next to the install CD.
  driverPaths = lib.concatImapStrings (
    i: l: ''<PathAndCredentials wcm:action="add" wcm:keyValue="${toString i}"><Path>${l}:\drivers\vm</Path></PathAndCredentials>''
  ) (lib.stringToCharacters "DEFGHIJ");
in
writeText "autounattend-${variant}.xml" ''
  <?xml version="1.0" encoding="utf-8"?>
  <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="windowsPE">
      ${comp "Microsoft-Windows-International-Core-WinPE" ''
        <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
        <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale>
        <UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>''}
      ${comp "Microsoft-Windows-Setup" ''
        ${if vm then disk else imageOnly}
        <UserData>
          <AcceptEula>true</AcceptEula>
          <!-- Microsoft's public generic install key for Pro: selects the edition, does not activate. -->
          <ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>
        </UserData>''}
      ${lib.optionalString vm (comp "Microsoft-Windows-PnpCustomizationsWinPE" "<DriverPaths>${driverPaths}</DriverPaths>")}
    </settings>
    <settings pass="specialize">
      ${comp "Microsoft-Windows-Deployment" ''
        <RunSynchronous>
          <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        </RunSynchronous>''}
    </settings>
    <settings pass="oobeSystem">
      ${comp "Microsoft-Windows-Shell-Setup" ''
        <OOBE>
          <HideEULAPage>true</HideEULAPage>
          <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
          <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
          <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
          <ProtectYourPC>3</ProtectYourPC>
        </OOBE>
        <UserAccounts>
          <LocalAccounts>
            <LocalAccount wcm:action="add">
              <Name>${user}</Name>
              <Group>Administrators</Group>
              <Password><Value></Value><PlainText>true</PlainText></Password>
            </LocalAccount>
          </LocalAccounts>
        </UserAccounts>
        <AutoLogon>
          <Enabled>true</Enabled><LogonCount>1</LogonCount><Username>${user}</Username>
          <Password><Value></Value><PlainText>true</PlainText></Password>
        </AutoLogon>
        <FirstLogonCommands>
          <SynchronousCommand wcm:action="add">
            <Order>1</Order>
            <Description>Require a password at next logon</Description>
            <CommandLine>net user ${user} /logonpasswordchg:yes</CommandLine>
          </SynchronousCommand>
          <SynchronousCommand wcm:action="add">
            <Order>2</Order>
            <Description>Copy machine-config from the CD and apply it</Description>
            <CommandLine>${copyCmd}</CommandLine>
            <RequiresUserInput>true</RequiresUserInput>
          </SynchronousCommand>
        </FirstLogonCommands>''}
    </settings>
  </unattend>
''
