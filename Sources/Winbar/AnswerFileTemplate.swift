import Foundation

// The answer file's template and the first-logon script, as the renderer ships them. Their source of truth is
// the Autounattend.template.xml and FirstLogon.ps1 that the Python reference renderer reads.
// Tests/WinbarTests/Fixtures/answerfile holds copies of both, and a test compares them with these
// literals, so neither side can be edited alone: change the oracle, take fresh fixtures, then change this.
//
// Both are ASCII. FirstLogon.ps1 is static: the same bytes for every VM, no placeholders, never a password;
// the ticked options reach it as the launcher's switches. It must stay valid Windows PowerShell 5.1.

extension AnswerFile {
    /// Autounattend.template.xml: `{{VALUE}}` placeholders and `<!--IF id-->` blocks (see `AnswerFile.render`).
    static let template = #"""
<?xml version="1.0" encoding="utf-8"?>
<!--
  Winbar "winbar create" answer file: Windows 11 24H2/25H2 ARM64, fresh install into a new UTM (QEMU virt) VM.
  Target: UEFI, one new blank NVMe disk (DiskID 0), no TPM, no Secure Boot keys, and no NIC driver during Setup
  (UTM's aarch64 NIC is virtio-net-pci; Windows has no inbox driver), so Setup and OOBE run offline.
  Delivered as \Autounattend.xml at the root of the answer CD (ISO9660+Joliet, volume label WINBAR_SETUP), next to
  \FirstLogon.ps1 and the pinned UTM Guest Tools installer (utm-guest-tools-<version>.exe). Setup finds it by its
  implicit search ("removable read-only media, in order of drive letter"); no other answer file is ever attached.

  TEMPLATE CONVENTIONS (resolved by the renderer; nothing of this comment survives rendering):
    {{NAME}}                  a value, XML-escaped by the renderer (& < > " ').
    {{PASSWORD_B64}}          base64(UTF-16LE(password + "Password")), the Windows SIM "hide sensitive data" form
                              (the suffix is the element name, "Password" for both elements that use it). Computed in
                              memory from the hidden prompt; never logged, never on a command line.
    {{SEQ}}                   numbered 1,2,3... per RunSynchronous / FirstLogonCommands list, after conditionals.
    IF/END comment markers    block form: markers alone on their own lines; inline form: inside one line (used only
                              in the first-logon CommandLine). "!id" keeps the content when the option is OFF.
                              Besides the ids below there is one MODIFIER, no_visual_tweaks (CLI no-visual-tweaks
                              flag, meaningful only with winbar_tuning); it is not a checklist row.
                              Blocks of different ids may nest. Unknown ids are a renderer error.
    Every other comment is stripped. Empty RunSynchronous lists and empty components are removed.
  OPTION IDS (contract between jobs; the defaults and the locks live with the renderer):
    Rufus parity: bypass_requirements (locked on), no_online_account, local_account (required), regional_from_mac,
                  skip_privacy, no_bitlocker, qol
    Winbar extras: autologon, remote_desktop, guest_tools (locked on), winbar_tuning, computer_name (text field;
                  the renderer turns it on when the value is non-empty)
    Derived by the renderer, not a checklist row: time_zone (regional_from_mac on and a Windows zone id known)
  Every component is processorArchitecture="arm64": the ARM64 image holds only arm64_ component manifests and the
  25H2 ARM64 Setup (sources\UnattendMgr.dll) queries component[...][processorArchitecture=arm64].
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <!-- ============ windowsPE: Setup running from the Windows ISO (WinPE, X:) ============ -->
  <settings pass="windowsPE">
    <!--
      Skips Setup's language page. PE_LANGUAGE = <LANGUAGES><DEFAULT> of boot.wim image 2 (en-US on
      Win11_25H2_English_Arm64_v2.iso). Always the image language, never the Mac's: nobody types in WinPE, and a
      language WinPE does not have would stop Setup.
    -->
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>{{PE_LANGUAGE}}</UILanguage>
      </SetupUILanguage>
      <InputLocale>{{PE_LANGUAGE}}</InputLocale>
      <SystemLocale>{{PE_LANGUAGE}}</SystemLocale>
      <UILanguage>{{PE_LANGUAGE}}</UILanguage>
      <UserLocale>{{PE_LANGUAGE}}</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <!--IF skip_privacy-->
      <!-- Setup's own diagnostic-data opt-in (UnattendMgr reads Diagnostics\OptIn; UTM's answer file sets it too). -->
      <Diagnostics>
        <OptIn>false</OptIn>
      </Diagnostics>
      <!--END skip_privacy-->
      <!-- Always: WinPE has no NIC driver, this only stops Setup from trying (UnattendMgr reads DynamicUpdate\Enable). -->
      <DynamicUpdate>
        <Enable>false</Enable>
        <WillShowUI>Never</WillShowUI>
      </DynamicUpdate>
      <!--
        Rufus 4.15 "silent erase and install" layout, implicit in Winbar (the VM disk is new and empty), minus Rufus's
        "Disk 1 / RUFUS_BOOT" tripwire (it guards extra physical disks; the VM has exactly one disk, and CDs are not
        DiskConfiguration disks). ESP 300 MB (Microsoft minimum is 200 MB on 512e, 300 MB on 4Kn). No recovery
        partition: Setup places WinRE itself (Rufus issue 2960).
      -->
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <!--IF no_bitlocker-->
        <DisableEncryptedDiskProvisioning>true</DisableEncryptedDiskProvisioning>
        <!--END no_bitlocker-->
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>300</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>EFI</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <!--
        Edition by /IMAGE/INDEX, as Rufus does. IMAGE_INDEX comes from sources\install.wim's XML of the ISO actually
        attached, read right before the answer CD is built (Win11_25H2_English_Arm64_v2.iso: 1 Home,
        2 Home Single Language, 3 Pro). Default Pro.
      -->
      <ImageInstall>
        <OSImage>
          <WillShowUI>OnError</WillShowUI>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>{{IMAGE_INDEX}}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <!--IF bypass_requirements-->
      <!--
        The same three LabConfig values Rufus 4.15 sets, studied in its wue.c and written here as answer-file
        commands rather than in C. The key path and the value names are Windows Setup's own, so there is one way
        to spell them, and only these three exist in the 25H2 ARM64 setupcompat.dll/winsetup.dll (BypassCPUCheck
        and BypassStorageCheck are no-ops). Locked on: UTM scripting cannot add a TPM, and UTM's firmware has no
        Secure Boot keys enrolled.
      -->
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <!--END bypass_requirements-->
      <UserData>
        <AcceptEula>true</AcceptEula>
        <!-- Empty key + the /IMAGE/INDEX selector = no product-key page (Rufus 4.15). Activation happens later. -->
        <ProductKey>
          <Key />
        </ProductKey>
      </UserData>
    </component>
  </settings>

  <!-- ============ specialize: first boot of the installed OS, runs as SYSTEM ============ -->
  <settings pass="specialize">
    <!--
      Computer name, also the DNS host name. Renderer-validated: 1-15 of A-Z a-z 0-9 and "-", no leading/trailing
      "-", not all digits, not equal to the user name. A blank field renders "*" (Windows' documented random name),
      never an omitted element, so OOBE never has a naming step to show.
    -->
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <!--IF computer_name-->
      <ComputerName>{{COMPUTER_NAME}}</ComputerName>
      <!--END computer_name-->
      <!--IF !computer_name-->
      <ComputerName>*</ComputerName>
      <!--END !computer_name-->
    </component>
    <!--IF no_bitlocker-->
    <!--
      Rufus's pair, moved from oobeSystem to specialize: Microsoft Learn lists specialize as a valid pass for both,
      and oobeSystem is NOT listed for TCGSecurityActivationDisabled. FirstLogon.ps1 -NoBitLocker re-checks C:.
    -->
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
    <component name="Microsoft-Windows-EnhancedStorage-Adm" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>
    </component>
    <!--END no_bitlocker-->
    <!--IF remote_desktop-->
    <!--
      Remote Desktop host on, NLA on (UserAuthentication 1), TLS security layer (2, what winbar doctor G6 checks),
      "Remote Desktop" firewall group by its language-neutral resource id. Set here so RDP works even if the
      first-logon script never runs. Pro and higher only: the renderer switches this off for Home editions.
    -->
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAuthentication>1</UserAuthentication>
      <SecurityLayer>2</SecurityLayer>
    </component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active>
          <Group>@FirewallAPI.dll,-28752</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
    <!--END remote_desktop-->
    <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <!--IF no_online_account-->
        <!--
          The same OOBE\BypassNRO value Rufus 4.15 sets (wue.c); the name and the 1 are what Windows reads, so
          there is one way to write it. With a pre-created local account and HideOnlineAccountScreens (always on
          below) OOBE never asks for a Microsoft account, and Microsoft neutralised this value in Insider
          26220.6772: kept for parity, harmless where ignored.
        -->
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <!--END no_online_account-->
        <!--IF qol-->
        <!-- Rufus 4.15's quality-of-life settings, machine-wide half, as specialize RunSynchronous commands (wue.c). -->
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>reg add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>PowerShell -NonInteractive -WindowStyle Hidden -Command "Remove-Item -Path $env:SystemRoot\System32\OneDriveSetup.exe -Force -Confirm:$false; Remove-Item -Path $env:SystemRoot\SysWOW64\OneDriveSetup.exe -Force -Confirm:$false;"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>PowerShell -NonInteractive -WindowStyle Hidden -Command "Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like '*Outlook*'} | Remove-AppxProvisionedPackage -Online"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>PowerShell -NonInteractive -WindowStyle Hidden -Command "Get-AppxPackage -AllUsers *Outlook* | Remove-AppxPackage -AllUsers"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>PowerShell -NonInteractive -WindowStyle Hidden -Command "Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like '*Teams*'} | Remove-AppxProvisionedPackage -Online"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Path>PowerShell -NonInteractive -WindowStyle Hidden -Command "Get-AppxPackage -AllUsers *Teams* | Remove-AppxPackage -AllUsers"</Path>
        </RunSynchronousCommand>
        <!--END qol-->
      </RunSynchronous>
    </component>
  </settings>

  <!-- ============ oobeSystem: OOBE, then the first (automatic) logon ============ -->
  <settings pass="oobeSystem">
    <!--
      Always emitted: a complete locale set is what lets OOBE skip its region and keyboard pages (25H2 keyboard-page
      stall report, NTLite 2026-05). UI_LANGUAGE is always the image language (it must be installed). With
      regional_from_mac the renderer fills INPUT_LOCALE (LCID:KLID of the Mac keyboard), SYSTEM_LOCALE and
      USER_LOCALE (the Mac region, as a Windows locale name); without it all four are the image language. Any of
      the three the Mac can't supply (no Windows keyboard or locale to match) is the image language too.
    -->
    <component name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>{{INPUT_LOCALE}}</InputLocale>
      <SystemLocale>{{SYSTEM_LOCALE}}</SystemLocale>
      <UILanguage>{{UI_LANGUAGE}}</UILanguage>
      <UserLocale>{{USER_LOCALE}}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <!--
        The four Hide* values are what Rufus's silent mode adds so no page appears without a network; Winbar is
        always silent, so they are unconditional. ProtectYourPC needs SOME value or the privacy page waits for a
        click: 3 = everything off (skip_privacy), 1 = Windows' own recommended settings.
        Not used: SkipMachineOOBE / SkipUserOOBE (deprecated, break OOBE on 24H2+).
      -->
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <!--IF skip_privacy-->
        <ProtectYourPC>3</ProtectYourPC>
        <!--END skip_privacy-->
        <!--IF !skip_privacy-->
        <ProtectYourPC>1</ProtectYourPC>
        <!--END !skip_privacy-->
      </OOBE>
      <!--IF time_zone-->
      <!--
        Windows zone ID mapped from the Mac's IANA zone through CLDR windowsZones.xml. time_zone is derived by the
        renderer: on when regional_from_mac is on and the Mac's zone has a Windows id. Otherwise the element is left
        out and Windows uses its default zone (OOBE doesn't ask).
      -->
      <TimeZone>{{TIME_ZONE}}</TimeZone>
      <!--END time_zone-->
      <!--IF local_account-->
      <!--
        Local administrator with a real, non-empty password (a blank one cannot sign in over RDP:
        LimitBlankPasswordUse). Differences from Rufus: no "net user /logonpasswordchg:yes" (it would stop the
        unattended sign-in), group "Administrators" only (Shell-Setup maps this English name to the localized
        group). Windows keeps only the NT hash of this password (SAM).
      -->
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>{{USERNAME}}</Name>
            <DisplayName>{{DISPLAY_NAME}}</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>{{PASSWORD_B64}}</Value>
              <PlainText>false</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <!--
        Present whatever the autologon option says: FirstLogonCommands only run when someone signs in, and nobody
        is at the console. Shell-Setup stores this password as the LSA secret DefaultPassword (LsaStorePrivateData
        in shsetup.dll), not as a registry value. Windows adds 1 to a LogonCount above 0 (Microsoft known issue);
        FirstLogon.ps1 then makes autologon permanent (-Autologon) or applies Microsoft's AutoLogonCount=0 fix.
      -->
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>{{USERNAME}}</Username>
        <Password>
          <Value>{{PASSWORD_B64}}</Value>
          <PlainText>false</PlainText>
        </Password>
      </AutoLogon>
      <!--END local_account-->
      <!--
        One list only. Microsoft: these commands now all START AT ONCE and do not wait for each other, so every
        entry is order-independent; all ordered Winbar work is inside FirstLogon.ps1 on the WINBAR_SETUP CD, which
        is found by volume label (CD drive letters depend on enumeration order) and writes the status file last.
      -->
      <FirstLogonCommands>
        <!--IF local_account-->
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Description>Local passwords never expire (Rufus)</Description>
          <CommandLine>net accounts /maxpwage:unlimited</CommandLine>
        </SynchronousCommand>
        <!--END local_account-->
        <!--IF qol-->
        <!-- The same settings' per-user and policy half, as FirstLogonCommands (wue.c). -->
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\System\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowCopilotButton /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarModeCache /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Windows\Windows Feeds" /v EnableFeeds /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\Communications" /v ConfigureChatAutoInstall /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_Layout /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <CommandLine>PowerShell -NonInteractive -WindowStyle Hidden -Command "Set-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'VisiblePlaces' -Value $([convert]::FromBase64String('ztU0LVr6Q0WC8iLm6vd3PC+zZ+PeiVVDv85h83sYqTe8JIoUDNaJQqCAbtm7okiCRIF1/g0IrkKL2jTtl7ZjlEqwvXRK+WhPi9ZDmAcdqLyGCHNSqlFDQp97J3ZYRlnU')) -Type 'Binary'"</CommandLine>
        </SynchronousCommand>
        <!--END qol-->
        <!--
          Always: the Winbar first-logon script. Waits up to 2 minutes for the answer CD, found by its volume label
          WINBAR_SETUP or, should the label read differently, by \FirstLogon.ps1 at its root. Runs that script with
          one switch per ticked Winbar option (inline conditionals). If the CD never shows up, or the script can't
          run (a parse or parameter error, anything it doesn't catch itself), the launcher writes the status file
          itself (result=failed, status.tmp renamed to status.txt as the script does), so a console or agent reader
          sees why. At most 1024 characters with every switch, which the renderer checks.
        -->
        <SynchronousCommand wcm:action="add">
          <Order>{{SEQ}}</Order>
          <Description>Winbar first-logon script</Description>
          <CommandLine>powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$e = 'WINBAR_SETUP CD not found'; $v = $null; for ($i = 0; $i -lt 60 -and -not $v; $i++) { $v = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' -and $_.IsReady -and ($_.VolumeLabel -eq 'WINBAR_SETUP' -or (Test-Path ($_.Name + 'FirstLogon.ps1'))) })[0]; if (-not $v) { Start-Sleep 2 } }; if ($v) { try { &amp; ($v.Name + 'FirstLogon.ps1')<!--IF guest_tools--> -GuestTools<!--END guest_tools--><!--IF autologon--> -Autologon<!--END autologon--><!--IF remote_desktop--> -RemoteDesktop<!--END remote_desktop--><!--IF no_bitlocker--> -NoBitLocker<!--END no_bitlocker--><!--IF winbar_tuning--> -Tuning<!--IF no_visual_tweaks--> -NoVisualTweaks<!--END no_visual_tweaks--><!--END winbar_tuning-->; $e = $null } catch { $e = 'launcher: ' + $_ } }; if ($e) { $o = $env:SystemRoot + '\Temp\winbar-install'; $r = 'off'; if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0) { $r = 'on' }; $null = New-Item $o -ItemType Directory -Force; $t = $o + '\status.tmp'; Set-Content $t @('result=failed', 'guest_tools=-1', ('rdp=' + $r), ('error=' + ($e -replace '\s+', ' '))) -Encoding Ascii; Move-Item $t ($o + '\status.txt') -Force }"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>

"""#

    /// FirstLogon.ps1, copied verbatim to the root of the WINBAR_SETUP CD.
    static let firstLogonScript = #"""
# Winbar "winbar create" first-logon script. Lives at \FirstLogon.ps1 on the answer CD (volume label WINBAR_SETUP).
#
# Started once by the answer file's FirstLogonCommands, as the new local administrator, elevated, in the first
# automatic sign-in. The file is STATIC (identical for every VM, ASCII only, so Windows PowerShell 5.1 reads it the
# same with or without a BOM): the ticked options arrive as switches written by the answer-file renderer.
#   -GuestTools     install UTM Guest Tools silently: utm-guest-tools*.exe next to this script (guest_tools, locked on)
#   -Autologon      keep signing in automatically (autologon); without it, only the setup sign-in happens
#   -RemoteDesktop  Remote Desktop with NLA, same values as winbar doctor G6 (remote_desktop)
#   -NoBitLocker    make sure C: is not encrypted (no_bitlocker)
#   -Tuning         Winbar's performance tuning, winbar doctor G1-G4 (winbar_tuning)
#   -NoVisualTweaks with -Tuning: skip G4 visual effects (the --no-visual-tweaks modifier, as in winbar setup)
#
# It never receives the account password and never reads it into output. Autologon uses the copy Windows Setup
# already stored as the LSA secret DefaultPassword; this script only reads Winlogon's non-secret values. Without
# -Autologon it deletes that secret through LsaStorePrivateData(NULL), which writes and never reads.
#
# CONTRACT: the LAST thing it does is write C:\Windows\Temp\winbar-install\status.txt (ASCII, CRLF, key=value, written
# to status.tmp first and renamed). The first three lines are always, in this order:
#   result=ok|failed      ok only if every requested step succeeded
#   guest_tools=<n>       installer exit code; -1 installer not found, -2 still running after the timeout (a
#                         warning when the guest agent runs anyway), -3 not requested
#   rdp=on|off            the actual state (fDenyTSConnections = 0), whatever was requested
# Extra keys follow (readers must ignore keys they do not know). Winbar polls for the file through the QEMU guest agent
# that step "guest_tools" installs; nothing here restarts Windows. Log: C:\Windows\Temp\winbar-install\firstlogon.log.
# If this script can't run at all, the answer file's launcher writes the same file itself (result=failed).
# Nothing here writes a password or any other secret value to the log, progress.txt or status.txt: only counts,
# booleans and states.
# progress.txt in the same folder holds the name of the step in progress (for the host's progress view).

[CmdletBinding()]
param(
  [switch]$GuestTools,
  [switch]$Autologon,
  [switch]$RemoteDesktop,
  [switch]$NoBitLocker,
  [switch]$Tuning,
  [switch]$NoVisualTweaks,
  [int]$GuestToolsTimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '2'

# ---- Constants shared with Winbar (Tuning.swift / GuestScripts.swift; a unit test keeps them equal) --------------
$BalancedScheme   = '381b4222-f694-41f0-9685-ff5bb260df2e'
$GuidPattern      = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$RdpFirewallGroup = '@FirewallAPI.dll,-28752'
$HomeEditions     = @('Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific')
$GuestAgentName   = 'QEMU-GA'
$Winlogon         = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$TermServer       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

# ---- Plumbing ------------------------------------------------------------------------------------------------------
$OutDir = Join-Path $env:SystemRoot 'Temp\winbar-install'
$StatusFile = Join-Path $OutDir 'status.txt'
$StatusTmp = Join-Path $OutDir 'status.tmp'
$LogFile = Join-Path $OutDir 'firstlogon.log'
$ProgressFile = Join-Path $OutDir 'progress.txt'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Remove-Item -LiteralPath $StatusFile, $StatusTmp -Force -ErrorAction SilentlyContinue

$Failed = New-Object System.Collections.Generic.List[string]
$Info = [ordered]@{}
$GuestToolsExit = -3

function Log([string]$Message) {
  try { Add-Content -LiteralPath $LogFile -Encoding Ascii -Value ((Get-Date).ToString('s') + ' ' + $Message) } catch { }
}
function Step([string]$Name, [scriptblock]$Body) {
  Log ('begin ' + $Name)
  try { [System.IO.File]::WriteAllText($ProgressFile, $Name, [System.Text.Encoding]::ASCII) } catch { }
  try { & $Body; Log ('ok ' + $Name) }
  catch {
    $Failed.Add($Name)
    if (-not $Info.Contains('error')) { $Info['error'] = $Name + ': ' + $_.Exception.Message }
    Log ('FAILED ' + $Name + ': ' + $_.Exception.Message)
  }
}
function RegValue([string]$Path, [string]$Name) {
  try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function HasValue([string]$Path, [string]$Name) {
  try { @((Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueNames()) -contains $Name } catch { $false }
}
function Guids($Lines) {
  @([regex]::Matches((@($Lines) -join ' '), $GuidPattern) | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
}
function SetUserValue([string]$Key, [string]$Name, [string]$Kind, $Value) {
  # This script runs as the new user, so HKCU is that user's hive (winbar setup writes HKEY_USERS\<SID> instead).
  $path = 'HKCU:\' + $Key
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $Name -PropertyType $Kind -Value $Value -Force | Out-Null
}
function ClearLsaSecret([string]$Name) {
  # Deletes an LSA private secret: LsaStorePrivateData with PrivateData = NULL. Write-only on purpose: nothing here
  # can read a secret (no LsaRetrievePrivateData). Returns a Win32 error code, 0 = deleted.
  if (-not ('WinbarLsa' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinbarLsa {
  [StructLayout(LayoutKind.Sequential)]
  struct LsaUnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)]
  struct LsaObjectAttributes { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaObjectAttributes attributes, uint access, out IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LsaUnicodeString keyName, IntPtr privateData);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
  public static int Delete(string name) {
    LsaObjectAttributes attributes = new LsaObjectAttributes();
    attributes.Length = Marshal.SizeOf(typeof(LsaObjectAttributes));
    IntPtr policy;
    uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policy);   // POLICY_CREATE_SECRET
    if (status != 0) { return LsaNtStatusToWinError(status); }
    IntPtr buffer = Marshal.StringToHGlobalUni(name);
    try {
      LsaUnicodeString key = new LsaUnicodeString();
      key.Buffer = buffer;
      key.Length = (ushort)(name.Length * 2);
      key.MaximumLength = (ushort)((name.Length + 1) * 2);
      status = LsaStorePrivateData(policy, ref key, IntPtr.Zero);
      return status == 0 ? 0 : LsaNtStatusToWinError(status);
    } finally {
      Marshal.FreeHGlobal(buffer);
      LsaClose(policy);
    }
  }
}
'@
  }
  [WinbarLsa]::Delete($Name)
}
function WriteStatus {
  $rdp = 'off'
  if ((RegValue $TermServer 'fDenyTSConnections') -eq 0) { $rdp = 'on' }
  $result = 'failed'
  if ($Failed.Count -eq 0) { $result = 'ok' }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('result=' + $result)
  $lines.Add('guest_tools=' + $GuestToolsExit)
  $lines.Add('rdp=' + $rdp)
  $Info['failed_steps'] = ($Failed -join ',')
  $Info['log'] = $LogFile
  $Info['winbar_firstlogon'] = $ScriptVersion
  foreach ($k in $Info.Keys) {
    $lines.Add($k + '=' + (([string]$Info[$k]) -replace '[\r\n]+', ' '))
  }
  [System.IO.File]::WriteAllText($StatusTmp, (($lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
  Move-Item -LiteralPath $StatusTmp -Destination $StatusFile -Force
  Log ('status written: ' + $lines[0])
}

Log ('Winbar FirstLogon.ps1 v' + $ScriptVersion + ' from ' + $PSScriptRoot + ' switches:' +
     $(if ($GuestTools) { ' GuestTools' }) + $(if ($Autologon) { ' Autologon' }) + $(if ($RemoteDesktop) { ' RemoteDesktop' }) +
     $(if ($NoBitLocker) { ' NoBitLocker' }) + $(if ($Tuning) { ' Tuning' }) + $(if ($NoVisualTweaks) { ' NoVisualTweaks' }))

try {
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $Edition = [string]$cv.EditionID

  # ---- 1. Setup's leftovers that could hold the password ---------------------------------------------------------
  # Setup scrubs passwords from its cached answer file at the end of each pass; check, and delete any cached file that
  # still holds a password value. Both Setup engines' folders, recursively: %WINDIR%\Panther (with Unattend and
  # UnattendGC) and the ConX engine's C:\$WINDOWS.~BT (25H2 ships both). Values are only compared with Setup's
  # marker, never logged or reported: the status carries counts only.
  Step 'panther' {
    $marker = '*SENSITIVE*DATA*DELETED*'
    $deleted = 0; $checked = 0
    $files = @()
    foreach ($dir in @((Join-Path $env:SystemRoot 'Panther'), (Join-Path $env:SystemDrive '$WINDOWS.~BT'))) {
      if (Test-Path -LiteralPath $dir) {
        $files += @(Get-ChildItem -LiteralPath $dir -Filter '*.xml' -File -Recurse -Force -ErrorAction SilentlyContinue)
      }
    }
    foreach ($f in $files) {
      $doc = New-Object System.Xml.XmlDocument
      try { $doc.Load($f.FullName) } catch { continue }
      $checked++
      $values = @($doc.SelectNodes("//*[local-name()='Password' or local-name()='AdministratorPassword']/*[local-name()='Value']"))
      $open = @($values | Where-Object { $_.InnerText -ne '' -and $_.InnerText -ne $marker }).Count
      $doc = $null
      if ($open -gt 0) { Remove-Item -LiteralPath $f.FullName -Force; $deleted++; Log ('deleted unscrubbed ' + $f.FullName) }
    }
    $Info['panther_scrub'] = $(if ($deleted) { 'deleted:' + $deleted } else { 'clean:' + $checked })

    # Shell-Setup stages its answers under UnattendSettings (shsetup.dll strings) and deletes them after use.
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UnattendSettings\Microsoft-Windows-Shell-Setup'
    $residue = 'none'
    if (Test-Path -LiteralPath $root) {
      $keys = @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq 'Password' -or $_.PSChildName -eq 'AdministratorPassword' })
      foreach ($k in $keys) {
        try { Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop; $residue = 'removed' }
        catch { $residue = 'present'; Log ('cannot remove ' + $k.Name) }
      }
    }
    $Info['password_residue'] = $residue
  }

  # ---- 2. Automatic sign-in --------------------------------------------------------------------------------------------
  Step 'autologon' {
    $plain = HasValue $Winlogon 'DefaultPassword'
    # shsetup.dll logs "[Shell Unattend] AutoLogon Password saved" after LsaStorePrivateData succeeds.
    $saved = $false
    foreach ($gcLog in @((Join-Path $env:SystemRoot 'Panther\UnattendGC\setupact.log'), (Join-Path $env:SystemRoot 'Panther\setupact.log'))) {
      if (-not $saved -and (Test-Path -LiteralPath $gcLog)) {
        $saved = [bool](Select-String -LiteralPath $gcLog -SimpleMatch -Quiet -Pattern '[Shell Unattend] AutoLogon Password saved')
      }
    }
    if ($Autologon) {
      # No AutoLogonCount = Winlogon never counts down to "off". The password stays where Setup put it.
      Remove-ItemProperty -LiteralPath $Winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
      Set-ItemProperty -LiteralPath $Winlogon -Name 'AutoAdminLogon' -Value '1' -Type String
      Set-ItemProperty -LiteralPath $Winlogon -Name 'DefaultUserName' -Value $env:USERNAME -Type String
      Set-ItemProperty -LiteralPath $Winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String
      if ($plain -and $saved) {
        # A plaintext copy next to the LSA secret is redundant: drop it.
        Remove-ItemProperty -LiteralPath $Winlogon -Name 'DefaultPassword' -Force
        $Info['autologon_secret'] = 'lsa'
      } elseif ($plain) {
        # Not expected (shsetup.dll stores the LSA secret). Leave it so autologon keeps working; winbar setup G8
        # (netplwiz) converts it to the LSA secret. Reported, not failed.
        $Info['autologon_secret'] = 'plaintext'
      } else {
        # This very sign-in was automatic, and with no plaintext value Winlogon can only have used the LSA secret.
        $Info['autologon_secret'] = $(if ($saved) { 'lsa' } else { 'lsa-inferred' })
      }
      # "Only allow Windows Hello sign-in" would hide netplwiz's checkbox, should anyone need it later (G8).
      $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
      if (-not (Test-Path -LiteralPath $pl)) { New-Item -Path $pl -Force | Out-Null }
      Set-ItemProperty -LiteralPath $pl -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord
      $Info['autologon'] = 'on'
    } else {
      # Microsoft's documented LogonCount fix: exactly this one automatic sign-in. At the next start Winlogon turns
      # autologon off, and it would delete the stored password itself; delete it now instead of relying on that.
      Set-ItemProperty -LiteralPath $Winlogon -Name 'AutoLogonCount' -Value 0 -Type DWord
      Remove-ItemProperty -LiteralPath $Winlogon -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
      $Info['autologon'] = 'off'
      $Info['autologon_secret'] = 'cleared-at-next-start'
      try {
        $code = ClearLsaSecret 'DefaultPassword'
        # 2 = ERROR_FILE_NOT_FOUND: there was no secret to delete.
        if ($code -eq 0 -or $code -eq 2) { $Info['autologon_secret'] = 'cleared' }
        else { Log ('LsaStorePrivateData: error ' + $code + '; Winlogon clears the secret at the next start') }
      } catch { Log ('LsaStorePrivateData: ' + $_.Exception.Message + '; Winlogon clears the secret at the next start') }
    }
  }

  # ---- 3. Remote Desktop with NLA (GuestScripts.applyRemoteDesktop) ---------------------------------------------------
  if ($RemoteDesktop) {
    Step 'rdp' {
      if ($HomeEditions -contains $Edition) { throw ('Windows ' + $Edition + ' cannot host Remote Desktop sessions') }
      $tcp = $TermServer + '\WinStations\RDP-Tcp'
      Set-ItemProperty -Path $TermServer -Name 'fDenyTSConnections' -Value 0 -Type DWord
      Set-ItemProperty -Path $tcp -Name 'UserAuthentication' -Value 1 -Type DWord
      Set-ItemProperty -Path $tcp -Name 'SecurityLayer' -Value 2 -Type DWord
      Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 1 -Type DWord
      Enable-NetFirewallRule -Group $RdpFirewallGroup
      $svc = Get-Service -Name 'TermService'
      if ("$($svc.Status)" -ne 'Running') { Start-Service -Name 'TermService' }
    }
  }

  # ---- 4. BitLocker off ---------------------------------------------------------------------------------------------------
  if ($NoBitLocker) {
    Step 'bitlocker' {
      $bl = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
      if (-not (Test-Path -LiteralPath $bl)) { New-Item -Path $bl -Force | Out-Null }
      Set-ItemProperty -LiteralPath $bl -Name 'PreventDeviceEncryption' -Value 1 -Type DWord
      $vol = $null
      try { $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop } catch { Log ('Get-BitLockerVolume: ' + $_.Exception.Message) }
      if ($vol -and "$($vol.VolumeStatus)" -ne 'FullyDecrypted') {
        Disable-BitLocker -MountPoint 'C:' | Out-Null
        Log ('BitLocker was ' + $vol.VolumeStatus + '; decryption started')
      }
    }
  }

  # ---- 5. UTM Guest Tools (drivers incl. NetKVM, SPICE agent, QEMU guest agent) -------------------------------------
  # Before the tuning steps, so nothing slow or stuck there can keep the guest agent from appearing: once it answers,
  # Winbar starts polling for the status file. The NSIS installer's /S is silent and skips its 3D page (viogpudo, not
  # viogpu3d); it never reboots. Winbar puts the pinned installer at the root of the WINBAR_SETUP CD, next to this
  # script; any other CD's root is only a fallback.
  if ($GuestTools) {
    Step 'guest_tools' {
      $exe = $null
      for ($i = 0; $i -lt 60 -and -not $exe; $i++) {
        $roots = @()
        if ($PSScriptRoot) { $roots += $PSScriptRoot }
        $roots += @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
        foreach ($root in $roots) {
          # The pinned file is utm-guest-tools-<version>.exe; the shortest matching name wins.
          $f = Get-ChildItem -LiteralPath $root -Filter 'utm-guest-tools*.exe' -File -ErrorAction SilentlyContinue |
               Sort-Object { $_.Name.Length } | Select-Object -First 1
          if ($f) { $exe = $f.FullName; break }
        }
        if (-not $exe) { Start-Sleep -Seconds 2 }
      }
      if (-not $exe) { $script:GuestToolsExit = -1; throw 'UTM Guest Tools installer not found on any CD' }
      try { $Info['guest_tools_media'] = [string](New-Object System.IO.DriveInfo -ArgumentList $exe).VolumeLabel } catch { }
      Log ('running ' + $exe + ' /S')
      $p = Start-Process -FilePath $exe -ArgumentList '/S' -PassThru
      $null = $p.Handle   # keeps the process handle so ExitCode is available after the wait
      if (-not $p.WaitForExit($GuestToolsTimeoutMinutes * 60000)) {
        # Not a failure by itself: step guest_agent below decides (the host shows a warning for -2).
        $script:GuestToolsExit = -2
        Log ('installer still running after ' + $GuestToolsTimeoutMinutes + ' minutes; carrying on')
      } else {
        $script:GuestToolsExit = $p.ExitCode
        if ($p.ExitCode -ne 0) { throw ('installer exit code ' + $p.ExitCode) }
      }
    }
    Step 'guest_agent' {
      $running = $false
      for ($i = 0; $i -lt 30 -and -not $running; $i++) {
        $svc = Get-Service -Name $GuestAgentName -ErrorAction SilentlyContinue
        if ($svc -and "$($svc.Status)" -eq 'Running') { $running = $true; break }
        if ($svc -and "$($svc.Status)" -eq 'Stopped') { Start-Service -Name $GuestAgentName -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
      }
      if (-not $running) { throw ('service ' + $GuestAgentName + ' is not running') }
    }
  }

  # ---- 6. Winbar tuning (GuestScripts.applyPower / applyPowerButton / applyServices / applyVisualEffects) -------------
  if ($Tuning) {
    Step 'power' {
      if (-not ((Guids (powercfg /list)) -contains $BalancedScheme)) { powercfg /duplicatescheme $BalancedScheme $BalancedScheme | Out-Null }
      powercfg /setactive $BalancedScheme
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFINCPOL 2
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFINCTHRESHOLD 30
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFDECTHRESHOLD 20
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR CPMINCORES 10
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR CPMAXCORES 100
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PROCTHROTTLEMIN 5
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PROCTHROTTLEMAX 100
      powercfg /change monitor-timeout-ac 5
      powercfg /change standby-timeout-ac 0
      powercfg /change disk-timeout-ac 20
      powercfg /setactive $BalancedScheme
      powercfg /hibernate off
    }
    Step 'power_button' {
      powercfg -attributes SUB_BUTTONS PBUTTONACTION -ATTRIB_HIDE
      $active = [regex]::Match(((powercfg /getactivescheme) -join ' '), $GuidPattern).Value
      foreach ($s in (Guids (powercfg /list))) {
        powercfg /setacvalueindex $s SUB_BUTTONS PBUTTONACTION 3
        powercfg /setdcvalueindex $s SUB_BUTTONS PBUTTONACTION 3
      }
      if ($active) { powercfg /setactive $active }
    }
    Step 'services' {
      foreach ($name in @('SysMain', 'WSearch', 'DiagTrack')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
          Set-Service -Name $name -StartupType Disabled
          if ("$($svc.Status)" -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        }
      }
    }
    if (-not $NoVisualTweaks) { Step 'visual_effects' {
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 'DWord' 3
      SetUserValue 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'DragFullWindows' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'FontSmoothing' 'String' '2'
      SetUserValue 'Control Panel\Desktop' 'MenuShowDelay' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'UserPreferencesMask' 'Binary' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 'DWord' 0
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 'DWord' 0
    } }
  }

} catch {
  $Failed.Add('script')
  Log ('FAILED script: ' + $_.Exception.Message)
} finally {
  # ---- 7. Facts for the host, then the status file: ALWAYS the last write ----------------------------------------------
  try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $Info['edition'] = $cv.EditionID
    $Info['build'] = ('{0}.{1}' -f $cv.CurrentBuild, $cv.UBR)
    $Info['computer_name'] = $env:COMPUTERNAME
    $Info['dns_host'] = [System.Net.Dns]::GetHostName()
    $Info['user'] = $env:USERNAME
    $nla = RegValue ($TermServer + '\WinStations\RDP-Tcp') 'UserAuthentication'
    $Info['nla'] = $(if ($nla -eq 1) { 'on' } else { 'off' })
    if (-not $Info.Contains('autologon')) { $Info['autologon'] = $(if ((RegValue $Winlogon 'AutoAdminLogon') -eq '1') { 'on' } else { 'off' }) }
    $Info['plaintext_password'] = $(if (HasValue $Winlogon 'DefaultPassword') { 'yes' } else { 'no' })
    $bitlocker = 'unavailable'
    try {
      $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
      $bitlocker = $(if ("$($vol.VolumeStatus)" -eq 'FullyDecrypted') { 'off' } elseif ("$($vol.VolumeStatus)" -eq 'DecryptionInProgress') { 'decrypting' } else { 'on' })
    } catch { }
    $Info['bitlocker'] = $bitlocker
    $ga = Get-Service -Name $GuestAgentName -ErrorAction SilentlyContinue
    $Info['guest_agent'] = $(if ($ga) { [string]$ga.Status } else { 'missing' })
    foreach ($u in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\SpiceGuestTools',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SpiceGuestTools')) {
      $ver = RegValue $u 'DisplayVersion'
      if ($ver) { $Info['guest_tools_version'] = $ver; break }
    }
  } catch { Log ('facts: ' + $_.Exception.Message) }
  try { [System.IO.File]::WriteAllText($ProgressFile, 'done', [System.Text.Encoding]::ASCII) } catch { }
  try { WriteStatus } catch { Log ('FAILED status: ' + $_.Exception.Message) }
}

"""#
}
