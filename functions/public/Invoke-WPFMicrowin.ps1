function Invoke-WPFMicrowin {
    <#
        .DESCRIPTION
        Invoke MicroWin routines...
    #>

	if($sync.ProcessRunning) {
        $msg = "GetIso process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

	# Define the constants for Windows API
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class PowerManagement {
	[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
	public static extern EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags);

	[FlagsAttribute]
	public enum EXECUTION_STATE : uint {
		ES_SYSTEM_REQUIRED = 0x00000001,
		ES_DISPLAY_REQUIRED = 0x00000002,
		ES_CONTINUOUS = 0x80000000,
	}
}
"@

	# Prevent the machine from sleeping
	[PowerManagement]::SetThreadExecutionState([PowerManagement]::EXECUTION_STATE::ES_CONTINUOUS -bor [PowerManagement]::EXECUTION_STATE::ES_SYSTEM_REQUIRED -bor [PowerManagement]::EXECUTION_STATE::ES_DISPLAY_REQUIRED)

    # Ask the user where to save the file
    $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $SaveDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $SaveDialog.Filter = "ISO images (*.iso)|*.iso"
    $SaveDialog.ShowDialog() | Out-Null

    if ($SaveDialog.FileName -eq "") {
        Write-Host "No file name for the target image was specified"
        return
    }

    Write-Host "Target ISO location: $($SaveDialog.FileName)"

	$index = $sync.MicrowinWindowsFlavors.SelectedValue.Split(":")[0].Trim()
	Write-Host "Index chosen: '$index' from $($sync.MicrowinWindowsFlavors.SelectedValue)"

	$keepPackages = $sync.WPFMicrowinKeepProvisionedPackages.IsChecked
	$keepProvisionedPackages = $sync.WPFMicrowinKeepAppxPackages.IsChecked
	$keepDefender = $sync.WPFMicrowinKeepDefender.IsChecked
	$keepEdge = $sync.WPFMicrowinKeepEdge.IsChecked
	$copyToUSB = $sync.WPFMicrowinCopyToUsb.IsChecked
	$injectDrivers = $sync.MicrowinInjectDrivers.IsChecked

    $mountDir = $sync.MicrowinMountDir.Text
    $scratchDir = $sync.MicrowinScratchDir.Text

	# Detect if the Windows image is an ESD file and convert it to WIM
	if (-not (Test-Path -Path $mountDir\sources\install.wim -PathType Leaf) -and (Test-Path -Path $mountDir\sources\install.esd -PathType Leaf))
	{
		Write-Host "Exporting Windows image to a WIM file, keeping the index we want to work on. This can take several minutes, depending on the performance of your computer..."
		Export-WindowsImage -SourceImagePath $mountDir\sources\install.esd -SourceIndex $index -DestinationImagePath $mountDir\sources\install.wim -CompressionType "Max"
		if ($?)
		{
            Remove-Item -Path $mountDir\sources\install.esd -Force
			# Since we've already exported the image index we wanted, switch to the first one
			$index = 1
		}
		else
		{
            $msg = "The export process has failed and MicroWin processing cannot continue"
            Write-Host "Failed to export the image"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
		}
	}

    $imgVersion = (Get-WindowsImage -ImagePath $mountDir\sources\install.wim -Index $index).Version

    # Detect image version to avoid performing MicroWin processing on Windows 8 and earlier
    if ((Test-CompatibleImage $imgVersion $([System.Version]::new(10,0,10240,0))) -eq $false)
    {
		$msg = "This image is not compatible with MicroWin processing. Make sure it isn't a Windows 8 or earlier image."
        $dlg_msg = $msg + "`n`nIf you want more information, the version of the image selected is $($imgVersion)`n`nIf an image has been incorrectly marked as incompatible, report an issue to the developers."
		Write-Host $msg
		[System.Windows.MessageBox]::Show($dlg_msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Exclamation)
        return
    }

	$mountDirExists = Test-Path $mountDir
    $scratchDirExists = Test-Path $scratchDir
	if (-not $mountDirExists -or -not $scratchDirExists) 
	{
        Write-Error "Required directories '$mountDirExists' '$scratchDirExists' and do not exist."
        return
    }

	try {

		Write-Host "Mounting Windows image. This may take a while."
        Mount-WindowsImage -ImagePath "$mountDir\sources\install.wim" -Index $index -Path "$scratchDir"
        if ($?)
        {
		    Write-Host "Mounting complete! Performing removal of applications..."
        }
        else
        {
            Write-Host "Could not mount image. Exiting..."
            return
        }

		if ($injectDrivers)
		{
			$driverPath = $sync.MicrowinDriverLocation.Text
			if (Test-Path $driverPath)
			{
				Write-Host "Adding Windows Drivers image($scratchDir) drivers($driverPath) "
				dism /English /image:$scratchDir /add-driver /driver:$driverPath /recurse | Out-Host
			}
			else 
			{
				Write-Host "Path to drivers is invalid continuing without driver injection"
			}
		}

		Write-Host "Remove Features from the image"
		Remove-Features -keepDefender:$keepDefender
		Write-Host "Removing features complete!"

		Write-Host "Removing Appx Bloat"
		if (!$keepPackages)
		{
			Remove-Packages
		}
		if (!$keepProvisionedPackages)
		{
			Remove-ProvisionedPackages -keepSecurity:$keepDefender
		}

		# special code, for some reason when you try to delete some inbox apps
		# we have to get and delete log files directory. 
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\LogFiles\WMI\RtBackup" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\WebThreatDefSvc" -Directory

		# Defender is hidden in 2 places we removed a feature above now need to remove it from the disk
		if (!$keepDefender) 
		{
			Write-Host "Removing Defender"
			Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Defender" -Directory
			Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Defender"
		}
		if (!$keepEdge)
		{
			Write-Host "Removing Edge"
			Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Microsoft" -mask "*edge*" -Directory
			Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Microsoft" -mask "*edge*" -Directory
			Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*edge*" -Directory
		}

		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\DiagTrack" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\InboxApps" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\SecurityHealthSystray.exe"
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\LocationNotificationWindows.exe" 
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Photo Viewer" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Photo Viewer" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Media Player" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Media Player" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Mail" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Mail" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Internet Explorer" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Internet Explorer" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\GameBarPresenceWriter"
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\OneDriveSetup.exe"
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\OneDrive.ico"
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*Windows.Search*" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*narratorquickstart*" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*Xbox*" -Directory
		Remove-FileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*ParentalControls*" -Directory
		Write-Host "Removal complete!"

		Write-Host "Create unattend.xml"
		New-Unattend
		Write-Host "Done Create unattend.xml"
		Write-Host "Copy unattend.xml file into the ISO"
		New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\Panther"
		Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\Windows\Panther\unattend.xml" -force
		New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\System32\Sysprep"
		Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\Windows\System32\Sysprep\unattend.xml" -force
		Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\unattend.xml" -force
		Write-Host "Done Copy unattend.xml"

		Write-Host "Create FirstRun"
		New-FirstRun
		Write-Host "Done create FirstRun"
		Write-Host "Copy FirstRun.ps1 into the ISO"
		Copy-Item "$env:temp\FirstStartup.ps1" "$($scratchDir)\Windows\FirstStartup.ps1" -force
		Write-Host "Done copy FirstRun.ps1"

		Write-Host "Copy link to winutil.ps1 into the ISO"
		$desktopDir = "$($scratchDir)\Windows\Users\Default\Desktop"
		New-Item -ItemType Directory -Force -Path "$desktopDir"
	    dism /English /image:$($scratchDir) /set-profilepath:"$($scratchDir)\Windows\Users\Default"
		$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://christitus.com/win | iex'"
		$shortcutPath = "$desktopDir\WinUtil.lnk"
		$shell = New-Object -ComObject WScript.Shell
		$shortcut = $shell.CreateShortcut($shortcutPath)

		if (Test-Path -Path "$env:TEMP\cttlogo.png")
		{
			$pngPath = "$env:TEMP\cttlogo.png"
			$icoPath = "$env:TEMP\cttlogo.ico"
			ConvertTo-Icon -bitmapPath $pngPath -iconPath $icoPath
			Write-Host "ICO file created at: $icoPath"
			Copy-Item "$env:TEMP\cttlogo.png" "$($scratchDir)\Windows\cttlogo.png" -force
			Copy-Item "$env:TEMP\cttlogo.ico" "$($scratchDir)\Windows\cttlogo.ico" -force
			$shortcut.IconLocation = "c:\Windows\cttlogo.ico"
		}

		$shortcut.TargetPath = "powershell.exe"
		$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
		$shortcut.Save()
		Write-Host "Shortcut to winutil created at: $shortcutPath"
		# *************************** Automation black ***************************

		Write-Host "Copy checkinstall.cmd into the ISO"
		New-CheckInstall
		Copy-Item "$env:temp\checkinstall.cmd" "$($scratchDir)\Windows\checkinstall.cmd" -force
		Write-Host "Done copy checkinstall.cmd"

		Write-Host "Creating a directory that allows to bypass Wifi setup"
		New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\System32\OOBE\BYPASSNRO"

		Write-Host "Loading registry"
		reg load HKLM\zCOMPONENTS "$($scratchDir)\Windows\System32\config\COMPONENTS"
		reg load HKLM\zDEFAULT "$($scratchDir)\Windows\System32\config\default"
		reg load HKLM\zNTUSER "$($scratchDir)\Users\Default\ntuser.dat"
		reg load HKLM\zSOFTWARE "$($scratchDir)\Windows\System32\config\SOFTWARE"
		reg load HKLM\zSYSTEM "$($scratchDir)\Windows\System32\config\SYSTEM"

		Write-Host "Disabling Teams"
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v "ConfigureChatAutoInstall" /t REG_DWORD /d 0 /f   >$null 2>&1
		reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 2 /f                             >$null 2>&1
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f        >$null 2>&1  
		reg query "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v "ConfigureChatAutoInstall"                      >$null 2>&1
		# Write-Host Error code $LASTEXITCODE
		Write-Host "Done disabling Teams"

		Write-Host "Bypassing system requirements (system image)"
		reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
		reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f

		if (!$keepEdge)
		{
			Write-Host "Removing Edge icon from taskbar"
			reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband" /v "Favorites" /f 		  >$null 2>&1
			reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband" /v "FavoritesChanges" /f   >$null 2>&1
			reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband" /v "Pinned" /f             >$null 2>&1
			reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband" /v "LayoutCycle" /f        >$null 2>&1
			Write-Host "Edge icon removed from taskbar"
		}

		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f
		Write-Host "Setting all services to start manually"
		reg add "HKLM\zSOFTWARE\CurrentControlSet\Services" /v Start /t REG_DWORD /d 3 /f
		# Write-Host $LASTEXITCODE

		Write-Host "Enabling Local Accounts on OOBE"
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d "1" /f

		Write-Host "Disabling Sponsored Apps"
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "OemPreInstalledAppsEnabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "PreInstalledAppsEnabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SilentInstalledAppsEnabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v ContentDeliveryAllowed /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v FeatureManagementEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v OemPreInstalledAppsEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEverEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v RotatingLockScreenEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v RotatingLockScreenOverlayEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContentEnabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-202913Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-202914Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280797Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280811Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280812Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280813Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280814Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280815Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280810Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-280817Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310091Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310092Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310094Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314558Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314559Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314562Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314563Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314566Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-314567Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338380Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338387Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338381Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338382Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338386Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338393Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-346480Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-346481Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353694Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353695Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353696Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353697Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353698Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353699Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000044Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000045Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000105Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000106Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000161Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000162Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000163Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000164Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000165Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-88000166Enabled /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v "ConfigureStartPins" /t REG_SZ /d '{\"pinnedList\": [{}]}' /f
		Write-Host "Done removing Sponsored Apps"
		
		Write-Host "Disabling Reserved Storage"
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v "ShippedWithReserves" /t REG_DWORD /d 0 /f
	
		Write-Host "Enabling Rounded Corners, Acrylic and mica by default"
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\Dwm" /v "ForceEffectMode" /t REG_DWORD /d 2 /f
		
		Write-Host "Configuring Application Compatibility...."
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\AppCompat" /v "DisablePCA" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "AITEnable" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "DisableEngine" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "DisableInventory" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "DisablePCA" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "SbEnable" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\AppCompat" /v "VDMDisallowed" /t REG_DWORD /d "1" /f
	
		Write-Host "Restrict Communication for Current User...."
		reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoOnlinePrintsWizard" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoPublishingWizard" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoWebServices" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Assistance\Client\1.0" /v "NoExplicitFeedback" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Assistance\Client\1.0" /v "NoImplicitFeedback" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Assistance\Client\1.0" /v "NoOnlineAssist" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\InternetManagement" /v "RestrictCommunication" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Messenger\Client" /v "CEIP" /t REG_DWORD /d "2" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" /v "AllowWindowsEntitlementReactivation" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" /v "NoGenTicket" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows NT\Printers" /v "DisableHTTPPrinting" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows NT\Printers" /v "DisableWebPnPDownload" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\HandwritingErrorReports" /v "PreventHandwritingErrorReports" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\TabletPC" /v "PreventHandwritingDataSharing" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\WindowsMovieMaker" /v "CodecDownload" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\WindowsMovieMaker" /v "WebHelp" /t REG_DWORD /d "1" /f
		reg add "HKLM\zNTUSER\Software\Policies\Microsoft\WindowsMovieMaker" /v "WebPublish" /t REG_DWORD /d "1" /f
	
		Write-Host "Restrict Communication for Local Machine...."
		reg add "HKLM\zSoftware\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoOnlinePrintsWizard" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoPublishingWizard" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoWebServices" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\EventViewer" /v "MicrosoftEventVwrDisableLinks" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\InternetManagement" /v "RestrictCommunication" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Messenger\Client" /v "CEIP" /t REG_DWORD /d "2" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\PCHealth\ErrorReporting" /v "DoReport" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\PCHealth\HelpSvc" /v "Headlines" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\PCHealth\HelpSvc" /v "MicrosoftKBSearch" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\SearchCompanion" /v "DisableContentFileUpdates" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\SQMClient\Windows" /v "CEIPEnable" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\SystemCertificates\AuthRoot" /v "DisableRootAutoUpdate" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows NT\CurrentVersion\zSoftware Protection Platform" /v "AllowWindowsEntitlementReactivation" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows NT\CurrentVersion\zSoftware Protection Platform" /v "NoGenTicket" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows NT\Printers" /v "DisableHTTPPrinting" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows NT\Printers" /v "DisableWebPnPDownload" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\DriverSearching" /v "DontSearchWindowsUpdate" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\HandwritingErrorReports" /v "PreventHandwritingErrorReports" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\Internet Connection Wizard" /v "ExitOnMSICW" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\Registration Wizard Control" /v "NoRegistration" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\TabletPC" /v "PreventHandwritingDataSharing" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\WindowsMovieMaker" /v "CodecDownload" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\WindowsMovieMaker" /v "WebHelp" /t REG_DWORD /d "1" /f
		reg add "HKLM\zSoftware\Policies\Microsoft\WindowsMovieMaker" /v "WebPublish" /t REG_DWORD /d "1" /f
	
		Write-Host "Configuring Diagnostics\DiagTrack...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "TimeStampInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastKnownProcessorModeStateIsController" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "DiagTrackStatus" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "Capabilities" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "DiagTrackAuthorization" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LaunchCount" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastFreeNetworkLossTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastConnectivityHeartBeatTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastConnectivityState" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "ConnectivityNoNetworkTime" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "ConnectivityRestrictedNetworkTime" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastPersistedEventTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LatencyDataLastUploadTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "TriggerCount" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "HttpRequestCount" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "TriggerLatency" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "HttpRequestLatency" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastSuccessfulUploadTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastSuccessfulRealtimeUploadTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastSuccessfulNormalUploadTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "LastSuccessfulCostDeferredUploadTime" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" /v "UploadEtlFileConsent" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation" /v "LastRemoteProcessPid" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation" /v "LastRemoteProcessEpoch" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation" /v "LastSettingsFiles" /t REG_SZ /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\CodeIntegrityAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\CodeIntegrityAggregator\{3EB30880-CC91-5EB0-24A0-50A6A52315FC}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\CodeIntegrityAggregator\{3EB30880-CC91-5EB0-24A0-50A6A52315FC}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\CompatAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\CompatAggregator\{18608E62-A628-49D9-8C02-55972E097D24}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\CompatAggregator\{18608E62-A628-49D9-8C02-55972E097D24}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\CompatAggregator\{18608E62-A628-49D9-8C02-55972E097D24}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{206BA7A1-88E8-4ABB-B6B8-28937E82C72B}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{206BA7A1-88E8-4ABB-B6B8-28937E82C72B}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{206BA7A1-88E8-4ABB-B6B8-28937E82C72B}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{8EFF71C4-CB3E-5664-86BF-7E15BD6F9FA4}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{8EFF71C4-CB3E-5664-86BF-7E15BD6F9FA4}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{8EFF71C4-CB3E-5664-86BF-7E15BD6F9FA4}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{9CAC2D9B-E081-4AB7-8C3E-30D117BCEF93}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{9CAC2D9B-E081-4AB7-8C3E-30D117BCEF93}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{9CAC2D9B-E081-4AB7-8C3E-30D117BCEF93}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{FBDC4594-A4A9-5F04-AF86-7BD18A7938B9}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{FBDC4594-A4A9-5F04-AF86-7BD18A7938B9}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\MediaFoundationAggregator\{FBDC4594-A4A9-5F04-AF86-7BD18A7938B9}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\PwdlessAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\PwdlessAggregator\{fb3cd94d-95ef-5a73-b35c-6c78451095ef}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\PwdlessAggregator\{fb3cd94d-95ef-5a73-b35c-6c78451095ef}" /v "EnableHold" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\PwdlessAggregator\{fb3cd94d-95ef-5a73-b35c-6c78451095ef}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{025d2741-697b-5e0e-7e77-9a36140251f7}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{025d2741-697b-5e0e-7e77-9a36140251f7}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{2504bc27-0e8b-5fed-7a9f-d86972086285}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{2504bc27-0e8b-5fed-7a9f-d86972086285}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{46b13027-2dfd-46e1-832d-e41e2810e6e5}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{46b13027-2dfd-46e1-832d-e41e2810e6e5}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{59dd67cc-7ce1-52f8-cf74-fe8a257a2b6b}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{59dd67cc-7ce1-52f8-cf74-fe8a257a2b6b}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{6d925246-8771-5ba9-515d-62b322d5f992}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{6d925246-8771-5ba9-515d-62b322d5f992}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{a7116549-1568-584f-9d0b-06cd5de15555}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{a7116549-1568-584f-9d0b-06cd5de15555}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{a8b932c2-51ec-5c22-63fc-0115fd79b9e0}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{a8b932c2-51ec-5c22-63fc-0115fd79b9e0}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{cee50f59-e321-4691-9bb7-9b75494f6aab}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{cee50f59-e321-4691-9bb7-9b75494f6aab}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{d48679eb-8aa3-4138-be24-f1648C874e49}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{d48679eb-8aa3-4138-be24-f1648C874e49}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{da65932c-0b7f-51d8-8d86-a4e5ae55392b}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateHeartbeatScan\{da65932c-0b7f-51d8-8d86-a4e5ae55392b}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{025d2741-697b-5e0e-7e77-9a36140251f7}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{025d2741-697b-5e0e-7e77-9a36140251f7}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{59dd67cc-7ce1-52f8-cf74-fe8a257a2b6b}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{59dd67cc-7ce1-52f8-cf74-fe8a257a2b6b}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{a7116549-1568-584f-9d0b-06cd5de15555}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{a7116549-1568-584f-9d0b-06cd5de15555}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{a8b932c2-51ec-5c22-63fc-0115fd79b9e0}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{a8b932c2-51ec-5c22-63fc-0115fd79b9e0}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{e77a560c-3696-4ac0-911c-545ceca6be3c}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdatePolicyScenarioReliabilityAggregator\{e77a560c-3696-4ac0-911c-545ceca6be3c}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
	
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\UpdateReboot...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{18D6CBEB-1E21-500A-27E2-8BA2BEAC7C00}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{18D6CBEB-1E21-500A-27E2-8BA2BEAC7C00}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{3D6120A6-0986-51C4-213A-E2975903051D}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{3D6120A6-0986-51C4-213A-E2975903051D}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{59DD67CC-7CE1-52F8-CF74-FE8A257A2B6B}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{59DD67CC-7CE1-52F8-CF74-FE8A257A2B6B}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{8BE48F34-1F58-4180-8C12-DBE6E6E71A81}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{8BE48F34-1F58-4180-8C12-DBE6E6E71A81}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{AC8D9176-9EB4-5047-9B60-1AABC45281B8}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{AC8D9176-9EB4-5047-9B60-1AABC45281B8}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{B39B8CEA-EAAA-5A74-5794-4948E222C663}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{B39B8CEA-EAAA-5A74-5794-4948E222C663}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{BBC9A2C9-EEED-58D4-9483-6C87118F9EC6}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{BBC9A2C9-EEED-58D4-9483-6C87118F9EC6}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{CEE50F59-E321-4691-9BB7-9B75494F6AAB}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{CEE50F59-E321-4691-9BB7-9B75494F6AAB}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{D059A021-6947-44FB-976A-B18C9B73D1D8}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UpdateReboot\{D059A021-6947-44FB-976A-B18C9B73D1D8}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\UusCoreHealthAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusCoreHealthAggregator\{b6acef34-fab6-5909-6b6b-b1c2cc84057f}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusCoreHealthAggregator\{b6acef34-fab6-5909-6b6b-b1c2cc84057f}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\ControlGroups\UusFailover...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{1377561d-9312-452c-ad13-c4a1c9c906e0}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{1377561d-9312-452c-ad13-c4a1c9c906e0}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{1a1dfad0-6d37-5521-1d72-1f87dd20423c}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{1a1dfad0-6d37-5521-1d72-1f87dd20423c}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{3E0D88DE-AE5C-438A-BB1C-C2E627F8AECB}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{3E0D88DE-AE5C-438A-BB1C-C2E627F8AECB}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{76AD4308-DF7C-5F43-E668-FCEA4FA1179D}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{76AD4308-DF7C-5F43-E668-FCEA4FA1179D}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{ad031b74-9ced-5a36-5961-956127af5b77}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{ad031b74-9ced-5a36-5961-956127af5b77}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{b6acef34-fab6-5909-6b6b-b1c2cc84057f}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{b6acef34-fab6-5909-6b6b-b1c2cc84057f}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{B7AFA6AF-AAAB-4F50-B7DC-B61D4DDBE34F}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{B7AFA6AF-AAAB-4F50-B7DC-B61D4DDBE34F}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{D1094A14-063E-7A21-A301-F2FE3BA23F62}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{D1094A14-063E-7A21-A301-F2FE3BA23F62}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{EC4BA041-1DFE-5F76-EF6D-0251DA19D178}" /v "Enabled" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\ControlGroups\UusFailover\{EC4BA041-1DFE-5F76-EF6D-0251DA19D178}" /v "MatchAnyKeyword" /t REG_BINARY /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\Host...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Host\0" /v "Status" /t REG_DWORD /d "0" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\Instrumentation...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\CodeIntegrityAggregator" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\MediaFoundationAggregator" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\PwdlessAggregator" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateHeartbeatScan" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePlatformAggregators" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdatePolicyScenarioReliabilityAggregator" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UpdateReboot" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusCoreHealthAggregator" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbInactiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbActiveMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbErrorMillis" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbSeq" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbStart" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbStop" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbErr" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbNonTelEventsEnabled" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbProcessed" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\Instrumentation\UusFailover" /v "HbConsumed" /t REG_QWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Aggregation\PwdlessAggregator...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Aggregation\PwdlessAggregator" /v "FirstTaskRunEpochDay" /t REG_DWORD /d "0" /f
	
	
		Write-Host "Configuring Diagnostics DiagTrack\AsimovUploader\CostDeferredBandwidthMonitor...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\AsimovUploader\CostDeferredBandwidthMonitor" /v "StartOfDayTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\AsimovUploader\CostDeferredBandwidthMonitor" /v "LastUploadIndex" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\AsimovUploader\CostDeferredBandwidthMonitor" /v "Data" /t REG_BINARY /d 0 /f
	
	
		Write-Host "Configuring Diagnostics DiagTrack\DeviceDeleteRequest...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\DeviceDeleteRequest" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\DeviceDeleteRequest" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\ETWEncryptionKey....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\ETWEncryptionKey" /v "CurrentUtcCertETag" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\ETWEncryptionKey" /v "ETWEncryptionCert" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\EventMonitors...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "MonitorSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "EventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "FirstEventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "ConsumerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "TriggerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "EventStoreEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "UploadedEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "SentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "FirstSentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CostDeferred_0" /v "FireCount" /t REG_DWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "MonitorSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "EventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "FirstEventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "ConsumerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "TriggerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "EventStoreEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "UploadedEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "SentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "FirstSentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.CriticalPersistence_0" /v "FireCount" /t REG_DWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "MonitorSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "EventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "FirstEventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "ConsumerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "TriggerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "EventStoreEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "UploadedEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "SentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "FirstSentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Normal_0" /v "FireCount" /t REG_DWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "MonitorSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "EventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "FirstEventSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "ConsumerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "TriggerEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "EventStoreEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "UploadedEventCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "SentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "FirstSentinelSn" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventMonitors\Microsoft.Windows.Sentinels.Realtime_0" /v "FireCount" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\EventTranscriptKey...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey" /v "EnableEventTranscript" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\exporters...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\exporters" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\exporters" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\FailFastCounters....."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\FailFastCounters" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\FailFastCounters" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Features....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Features" /v "EventTagDropUserIds" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\HeartBeats\Aria...."
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "LastHeartBeatTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "HeartBeatSequenceNumber" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventDroppedUploader" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "CompressedBytesUploaded" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "InvalidHttpCodes" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "LastInvalidHttpCode" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "LastEventSizeOffender" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "SettingsHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "SettingsHttpFailures" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexHttpFailures4xx" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexHttpFailures5xx" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexFailuresTimeout" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventsUploaded" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexHttpResponsesWithDroppedEvents" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "VortexHttpResponseFailures" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "RepeatedUploadFailureDropped" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "CriticalEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventDroppedFullDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventDroppedFailureDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventStoreLifetimeReset" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventStoreReset" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EventStoreResetSizeSum" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "CriticalOverflowEntersCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "EnteringCriticalOverflowDroppedCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "CriticalDataEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Aria" /v "PrivacyBlockedCounter" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\HeartBeats\Default...."
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "LastHeartBeatTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "HeartBeatSequenceNumber" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedEtw" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "BuffersDroppedEtw" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedConsumer" /t REG_QWORD /d "0" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedDecoding" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventsDroppedFullTriggerBuffer" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "CriticalDataEventDroppedThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventsPersistedCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedUploader" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "CompressedBytesUploaded" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "InvalidHttpCodes" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "LastInvalidHttpCode" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "LastEventSizeOffender" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "SettingsHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "SettingsHttpFailures" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexHttpFailures4xx" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexHttpFailures5xx" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexFailuresTimeout" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventsUploaded" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexHttpResponsesWithDroppedEvents" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "VortexHttpResponseFailures" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "RepeatedUploadFailureDropped" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "MaxInUseScenarios" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "CriticalEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedFullDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventDroppedFailureDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventStoreLifetimeReset" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventStoreReset" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EventStoreResetSizeSum" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "CriticalOverflowEntersCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "EnteringCriticalOverflowDroppedCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "CriticalDataEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "PrivacyBlockedCounter" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "MaxActiveAgentConnections" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "HostConnectionErrors" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Default" /v "LastHostConnectionError" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\HeartBeats\DevHealthMon....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\DevHealthMon" /v "LastHeartBeatTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\DevHealthMon" /v "HeartBeatSequenceNumber" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\HeartBeats\EndpointErrors...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors" /v "InputCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors" /v "SlotCount" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\0" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\0" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\1" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\1" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\2" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\2" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\3" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\3" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\4" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\4" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\5" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\5" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\6" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\6" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\7" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\7" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\8" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\8" /v "Value" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\9" /v "Name" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\EndpointErrors\9" /v "Value" /t REG_DWORD /d 0 /f
	
	
		Write-Host "Configuring Diagnostics DiagTrack\HeartBeats\Seville...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "LastHeartBeatTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "HeartBeatSequenceNumber" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedEtw" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "BuffersDroppedEtw" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedConsumer" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedDecoding" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedThrottled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventsDroppedFullTriggerBuffer" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "CriticalDataEventDroppedThrottled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventsPersistedCounter" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedUploader" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "CompressedBytesUploaded" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "InvalidHttpCodes" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "LastInvalidHttpCode" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "LastEventSizeOffender" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "SettingsHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "SettingsHttpFailures" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexHttpAttempts" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexHttpFailures4xx" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexHttpFailures5xx" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexFailuresTimeout" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventsUploaded" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexHttpResponsesWithDroppedEvents" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "VortexHttpResponseFailures" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "RepeatedUploadFailureDropped" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "CriticalEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedFullDb" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventDroppedFailureDb" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventStoreLifetimeReset" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventStoreReset" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EventStoreResetSizeSum" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "CriticalOverflowEntersCounter" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "EnteringCriticalOverflowDroppedCounter" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "CriticalDataEventDroppedDb" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HeartBeats\Seville" /v "PrivacyBlockedCounter" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\HwDebugRegisters...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HwDebugRegisters" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\HwDebugRegisters" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\LocalSettings...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\LocalSettings" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\LocalSettings" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\OmittedIds...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\OmittedIds" /v "w:1D22C9CD-FAC9-88A4-FE53-D5953E4913DA" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\OmittedIds" /v "w:B04E2543-63EB-D3C6-4722-FBFE64FA31C0" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\OmittedIds" /v "w:5B08FD5C-0859-F5E6-7503-0D19552D498E" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\ProviderControl...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\ProviderControl" /v "DiagnosticsAndFeedbackSettingsApp" /t REG_BINARY /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\ProviderControl" /v "DiagnosticsAndFeedbackSettingsApp" /t REG_MULTI_SZ /d "" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\RegionalSettings...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\RegionalSettings" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\RegionalSettings" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Scenarios....."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Scenarios" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Scenarios" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\SettingsRequests....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests" /v "LastDownloadTime" /t REG_QWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests" /v "LastTelSettingsRingId" /t REG_DWORD /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests" /v "LastTelSettingsRingName" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests" /v "LastTelSettingsBranchName" /t REG_SZ /d "" /f
	
		Write-Host "Configuring Diagnostics P-ARIA Telemetry....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.ASM-WindowsDefault" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\TELEMETRY.ASM-WINDOWSSQ" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\telemetry.P-Eco3PTelDefault" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.aggregators" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.allow" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.app" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.cert" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.privacy" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\utc.tracing" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.DIAGNOSTICS" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKESCALATIONS" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.PERFTRACKPOINTDATA" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsPriority" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsRegistrationType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsPayloadType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsParseType" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "SettingsVersion" /t REG_SZ /d "v3.0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "ETag" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "ETagQueryParameters" /t REG_SZ /d "0" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "RefreshInterval" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "LastDownloadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "DownloadScheduled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "OverrideDownloadPolicies" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "LastFileWrittenPath" /t REG_SZ /d "" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SettingsRequests\WINDOWS.SIUF" /v "LastFileWrittenTime" /t REG_QWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\SevilleEventlogManager....."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "EventsUploaded" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "EventsDropped" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "LastEventlogWrittenTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "SuccessfulConnections" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "FailedConnections" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "LastHttpError" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "ProxySettingDetected" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "SslCertValidationFailures" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\SevilleEventlogManager" /v "LastSslCertError" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\TelemetryNamespaces...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TelemetryNamespaces" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TelemetryNamespaces" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Tenants...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA" /v "DailyUploadQuotaInBytes" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA" /v "DiskSizeInBytes" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA" /v "LastNormalUploadTime" /t REG_QWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA" /v "LastRealtimeUploadTime" /t REG_QWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\Tenants\P-ARIA...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-160f0649efde47b7832f05ed000fc453-ac622e33-42e6-4279-a90c-c663615692af-7288" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-194626ba46434f9ab441dd7ebda2aa64-5f64bebb-ac28-4cc7-bd52-570c8fe077c9-7717" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-218d658af29e41b6bc37144bd03f018d-5812f91d-33bc-462f-846a-923d073364cb-7442" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-218d658af29e41b6bc37144bd03f018d-6bd1d102-d792-414e-a9d8-315e766da244-7471" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-218d658af29e41b6bc37144bd03f018d-e58bdc4b-f0d5-4aa5-a319-2625ec445428-7527" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-25a114a7ee0643298e6aa851bfafafbd-81fb6016-ccc1-4763-8aca-8620acbe1e59-7185" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-412a111ab07348379f4fe26cbf4d6982-c0aed341-cab8-493a-8db7-6d2a47338352-7215" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-412a111ab07348379f4fe26cbf4d6982-c32c5650-13bb-4713-9b0f-7535a96075b2-6810" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-412a111ab07348379f4fe26cbf4d6982-e35d1556-f3ca-44ed-86b4-f77fc57651c1-7032" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-4bb4d6f7cafc4e9292f972dca2dcde42-bd019ee8-e59c-4b0f-a02c-84e72157a3ef-7485" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-5476d0c4a7a347909c4b8a13078d4390-f8bdcecf-243f-40f8-b7c3-b9c44a57dead-7230" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-6660cc65b74b4291b30536aea7ed6ead-5a228f6e-723e-4098-8ed2-3554f184fd67-7451" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-7005b72804a64fa4b2138faab88f877b-14cf798a-05a4-4b7b-9d02-4d99259ebd4a-7553" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-754de735ccd546b28d0bfca8ac52c3de-91d2c728-3032-4f0a-b161-1bb18085f42e-7285" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-7e1cd04ad2694f1d89fd94ad5005a8e2-a696c450-a52d-45b4-844d-bb5b45de5f0c-7607" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-80494971f8a54ffaa0463528b190001b-2fe3a3a0-1d51-48a9-ab38-1a00857bc0eb-6971" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-8255342a9a4d4b069b7adbf4798cf544-bf74f026-b3db-4745-a135-a4ad2ba90b51-7489" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-944a343d50be481390e2e8c462701e4f-0a96ffb5-e187-46d5-a85f-86909812f218-7313" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-a1bde8e78ab14b6198caa18be9d3126e-9277d376-40b1-48ec-92f5-b2ee3f44345b-7212" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-ac279d3495274f1681e7e87dd94f8e71-4d50d9d3-47ae-4eae-8fe0-416b9e14e4d6-7128" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-adbf3ecc867c4460947181289afdc0f1-1b4a5f10-9f67-419d-a578-a99987ac383b-6868" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-af397ef28e484961ba48646a5d38cf54-77418283-d6f6-4a90-b0c8-37e0f5e7b087-7425" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-b45ad090ea0a42fd891b8310c74e385c-cd0918fe-8ece-4648-a2b5-93c3adc1c7b9-7017" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-d5a8f02229be41efb047bd8f883ba799-59258264-451c-4459-8c09-75d7d721219a-7112" /v "Enabled" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\Tenants\P-ARIA\P-ARIA-faab4ead691e451eb230afc98a28e0f2-4089b390-5e4a-4a54-ac5c-6be4f2ea9321-7247" /v "Enabled" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\TestHooks...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TestHooks" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TestHooks" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\TestHooks\Volatile...."
		reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TestHooks\Volatile" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TestHooks\Volatile" /f
	
		Write-Host "Configuring Diagnostics DiagTrack\TraceManager...."
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "MiniTraceSlotContentPermitted" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "MiniTraceSlotEnabled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceScenarioId" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceStartTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceSessionStartTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceStopTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceMinTraceDurationFiletime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceHasStopTime" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTracePriority" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceIsExclusive" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceIsAutoLogger" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceProfileHash" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceIsThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceRequiredBufferSpace" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "alternativeTraceThrottleState" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotScenarioId" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotStartTime" /t REG_QWORD /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotSessionStartTime" /t REG_QWORD /d "0" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotStopTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotMinTraceDurationFiletime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotHasStopTime" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotPriority" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotIsExclusive" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotIsAutoLogger" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotProfileHash" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotIsThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotRequiredBufferSpace" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "aotThrottleState" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceScenarioId" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceStartTime" /t REG_QWORD /d "0" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceSessionStartTime" /t REG_QWORD /d "0" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceStopTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceMinTraceDurationFiletime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceHasStopTime" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTracePriority" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceIsExclusive" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceIsAutoLogger" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceProfileHash" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceIsThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceRequiredBufferSpace" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "miniTraceThrottleState" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagScenarioId" /t REG_SZ /d "" /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagStartTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagSessionStartTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagStopTime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagMinTraceDurationFiletime" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagHasStopTime" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagPriority" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagIsExclusive" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagIsAutoLogger" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagProfileHash" /t REG_QWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagIsThrottled" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagRequiredBufferSpace" /t REG_DWORD /d 0 /f
		reg add "HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TraceManager" /v "diagThrottleState" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Diagnostics DiagTrack\TriggerListener...."
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TriggerListener" /v "MatchEngineBufferSize" /t REG_DWORD /d 0 /f
	
		Write-Host "Configuring Windows Update to delay Feature Update to 365 days and security update to 20 days....."
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DeferFeatureUpdatesPeriodInDays" /t REG_DWORD /d "365" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DeferFeatureUpdates" /t REG_DWORD /d "1" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "BranchReadinessLevel" /t REG_DWORD /d "20" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DeferQualityUpdates" /t REG_DWORD /d "1" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DeferQualityUpdatesPeriodInDays" /t REG_DWORD /d "20" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "TargetReleaseVersion" /t REG_DWORD /d "1" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ProductVersion" /t REG_SZ /d "Windows 11" /f
		reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "TargetReleaseVersionInfo" /t REG_SZ /d "23H2" /f
	
		# Common Apps / Client editions all
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingNews_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingWeather_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsStore_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.StorePurchaseApp_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.VCLibs.140.00_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Photos_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsCamera_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsNotepad_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Paint_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsTerminal_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsAlarms_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsCalculator_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsMaps_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ScreenSketch_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.windowscommunicationsapps_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.People_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.GetHelp_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Getstarted_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Todos_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxSpeechToTextOverlay_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxGameOverlay_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxIdentityProvider_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.549981C3F5F10_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.OutlookForWindows_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftTeams_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.DevHome_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingSearch_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ApplicationCompatibilityEnhancements_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.CrossDevice_cw5n1h2txyewy" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MSTeams_8wekyb3d8bbwe" /f
	
		# Media Apps / Client non-N editions
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneMusic_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneVideo_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.YourPhone_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.GamingApp_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxGamingOverlay_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Xbox.TCUI_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Clipchamp.Clipchamp_yxz26nhyzhsrt" /f
	
		# Media Codecs / Client non-N editions, Team edition
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WebMediaExtensions_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.RawImageExtension_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.HEIFImageExtension_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.HEVCVideoExtension_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.VP9VideoExtensions_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WebpImageExtension_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.DolbyAudioExtensions_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.AVCEncoderVideoExtension_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MPEG2VideoExtension_8wekyb3d8bbwe" /f
	
		# Surface Hub Apps / Team edition
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Whiteboard_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.microsoftskydrive_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftTeamsforSurfaceHub_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MailforSurfaceHub_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftPowerBIForWindows_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SkypeApp_kzf8qxf38zg5c" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Excel_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.PowerPoint_8wekyb3d8bbwe" /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Word_8wekyb3d8bbwe" /f

		Write-Host "Changing theme to dark. This only works on Activated Windows"
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f

	} catch {
        Write-Error "An unexpected error occurred: $_"
    } finally {
		Write-Host "Unmounting Registry..."
		reg unload HKLM\zCOMPONENTS
		reg unload HKLM\zDEFAULT
		reg unload HKLM\zNTUSER
		reg unload HKLM\zSOFTWARE
		reg unload HKLM\zSYSTEM

		Write-Host "Cleaning up image..."
		dism /English /image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
		Write-Host "Cleanup complete."

		Write-Host "Unmounting image..."
        Dismount-WindowsImage -Path $scratchDir -Save
	} 
	
	try {

		Write-Host "Exporting image into $mountDir\sources\install2.wim"
        Export-WindowsImage -SourceImagePath "$mountDir\sources\install.wim" -SourceIndex $index -DestinationImagePath "$mountDir\sources\install2.wim" -CompressionType "Max"
		Write-Host "Remove old '$mountDir\sources\install.wim' and rename $mountDir\sources\install2.wim"
		Remove-Item "$mountDir\sources\install.wim"
		Rename-Item "$mountDir\sources\install2.wim" "$mountDir\sources\install.wim"

		if (-not (Test-Path -Path "$mountDir\sources\install.wim"))
		{
			Write-Error "Something went wrong and '$mountDir\sources\install.wim' doesn't exist. Please report this bug to the devs"
			return
		}
		Write-Host "Windows image completed. Continuing with boot.wim."

		# Next step boot image		
		Write-Host "Mounting boot image $mountDir\sources\boot.wim into $scratchDir"
        Mount-WindowsImage -ImagePath "$mountDir\sources\boot.wim" -Index 2 -Path "$scratchDir"

		if ($injectDrivers)
		{
			$driverPath = $sync.MicrowinDriverLocation.Text
			if (Test-Path $driverPath)
			{
				Write-Host "Adding Windows Drivers image($scratchDir) drivers($driverPath) "
				dism /English /image:$scratchDir /add-driver /driver:$driverPath /recurse | Out-Host
			}
			else 
			{
				Write-Host "Path to drivers is invalid continuing without driver injection"
			}
		}
	
		Write-Host "Loading registry..."
		reg load HKLM\zCOMPONENTS "$($scratchDir)\Windows\System32\config\COMPONENTS" >$null
		reg load HKLM\zDEFAULT "$($scratchDir)\Windows\System32\config\default" >$null
		reg load HKLM\zNTUSER "$($scratchDir)\Users\Default\ntuser.dat" >$null
		reg load HKLM\zSOFTWARE "$($scratchDir)\Windows\System32\config\SOFTWARE" >$null
		reg load HKLM\zSYSTEM "$($scratchDir)\Windows\System32\config\SYSTEM" >$null
		Write-Host "Bypassing system requirements on the setup image"
		reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
		reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
		reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f
		reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f
		# Fix Computer Restarted Unexpectedly Error on New Bare Metal Install
		reg add "HKLM\zSYSTEM\Setup\Status\ChildCompletion" /v "setup.exe" /t REG_DWORD /d 3 /f
	} catch {
        Write-Error "An unexpected error occurred: $_"
    } finally {
		Write-Host "Unmounting Registry..."
		reg unload HKLM\zCOMPONENTS
		reg unload HKLM\zDEFAULT
		reg unload HKLM\zNTUSER
		reg unload HKLM\zSOFTWARE
		reg unload HKLM\zSYSTEM

		Write-Host "Unmounting image..."
        Dismount-WindowsImage -Path $scratchDir -Save

		Write-Host "Creating ISO image"

		# if we downloaded oscdimg from github it will be in the temp directory so use it
		# if it is not in temp it is part of ADK and is in global PATH so just set it to oscdimg.exe
		$oscdimgPath = Join-Path $env:TEMP 'oscdimg.exe'
		$oscdImgFound = Test-Path $oscdimgPath -PathType Leaf
		if (!$oscdImgFound)
		{
			$oscdimgPath = "oscdimg.exe"
		}

		Write-Host "[INFO] Using oscdimg.exe from: $oscdimgPath"
		#& oscdimg.exe -m -o -u2 -udfver102 -bootdata:2#p0,e,b$mountDir\boot\etfsboot.com#pEF,e,b$mountDir\efi\microsoft\boot\efisys.bin $mountDir $env:temp\microwin.iso
		#Start-Process -FilePath $oscdimgPath -ArgumentList "-m -o -u2 -udfver102 -bootdata:2#p0,e,b$mountDir\boot\etfsboot.com#pEF,e,b$mountDir\efi\microsoft\boot\efisys.bin $mountDir $env:temp\microwin.iso" -NoNewWindow -Wait
		#Start-Process -FilePath $oscdimgPath -ArgumentList '-m -o -u2 -udfver102 -bootdata:2#p0,e,b$mountDir\boot\etfsboot.com#pEF,e,b$mountDir\efi\microsoft\boot\efisys.bin $mountDir `"$($SaveDialog.FileName)`"' -NoNewWindow -Wait
        $oscdimgProc = New-Object System.Diagnostics.Process
        $oscdimgProc.StartInfo.FileName = $oscdimgPath
        $oscdimgProc.StartInfo.Arguments = "-m -o -u2 -udfver102 -bootdata:2#p0,e,b$mountDir\boot\etfsboot.com#pEF,e,b$mountDir\efi\microsoft\boot\efisys.bin $mountDir `"$($SaveDialog.FileName)`""
        $oscdimgProc.StartInfo.CreateNoWindow = $True
        $oscdimgProc.StartInfo.WindowStyle = "Hidden"
        $oscdimgProc.StartInfo.UseShellExecute = $False
        $oscdimgProc.Start()
        $oscdimgProc.WaitForExit()

		if ($copyToUSB)
		{
			Write-Host "Copying target ISO to the USB drive"
			#Copy-ToUSB("$env:temp\microwin.iso")
			Copy-ToUSB("$($SaveDialog.FileName)")
			if ($?) { Write-Host "Done Copying target ISO to USB drive!" } else { Write-Host "ISO copy failed." }
		}
		
		Write-Host " _____                       "
		Write-Host "(____ \                      "
		Write-Host " _   \ \ ___  ____   ____    "
		Write-Host "| |   | / _ \|  _ \ / _  )   "
		Write-Host "| |__/ / |_| | | | ( (/ /    "
		Write-Host "|_____/ \___/|_| |_|\____)   "

		# Check if the ISO was successfully created - CTT edit
		if ($LASTEXITCODE -eq 0) {
			Write-Host "`n`nPerforming Cleanup..."
				Remove-Item -Recurse -Force "$($scratchDir)"
				Remove-Item -Recurse -Force "$($mountDir)"
			#$msg = "Done. ISO image is located here: $env:temp\microwin.iso"
			$msg = "Done. ISO image is located here: $($SaveDialog.FileName)"
			Write-Host $msg
			[System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
		} else {
			Write-Host "ISO creation failed. The "$($mountDir)" directory has not been removed."
		}
		
		$sync.MicrowinOptionsPanel.Visibility = 'Collapsed'
		
		#$sync.MicrowinFinalIsoLocation.Text = "$env:temp\microwin.iso"
        $sync.MicrowinFinalIsoLocation.Text = "$($SaveDialog.FileName)"
		# Allow the machine to sleep again (optional)
		[PowerManagement]::SetThreadExecutionState(0)
		$sync.ProcessRunning = $false
	}
}