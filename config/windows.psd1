@{
    SchemaVersion    = 1
    Edition          = 'Pro'
    Architecture     = 'x64'

    Deployment       = @{
        ComputerNamePrefix = 'DT-'
        Disk = @{
            WindowsFraction = 0.125
            WindowsSizesGiB = @(128, 256, 512, 1024)
            EfiMiB          = 512
            MsrMiB          = 16
            RecoveryMiB     = 2048
            AlignmentMiB    = 1
        }
    }

    Localization     = @{
        # Keep the Windows display language in English.
        UiLanguage   = 'en-US'

        # The first entry is the default input locale. Add layouts here.
        # Additional input locales do not change the Windows display language.
        InputLocales = @(
            'en-US'
            # 'ru-RU' # Example: uncomment to add the default Russian layout.
        )
    }

    OptionalFeatures = @{
        # Identifiers are selected from the pinned Pro image catalog.
        # Enabling platform features alone does not install a WSL distribution.
        'Microsoft-Windows-Subsystem-Linux'   = 'Enabled'
        'VirtualMachinePlatform'              = 'Enabled'
        'Microsoft-Hyper-V-All'               = 'Enabled'
        # Native Windows container platform; a runtime is selected separately.
        'Containers'                          = 'Enabled'

        # Unused desktop function that is enabled in the source image.
        'WorkFolders-Client'                  = 'Disabled' # Corporate Work Folders synchronization.

        # Keep unused server roles disabled; these are already off in the source.
        'IIS-WebServerRole'                   = 'Disabled'
        'IIS-FTPServer'                       = 'Disabled'
        'IIS-HostableWebCore'                 = 'Disabled'
        'WAS-WindowsActivationService'        = 'Disabled'
        'MSMQ-Container'                      = 'Disabled'
        'DirectoryServices-ADAM-Client'       = 'Disabled'
        'ClientForNFS-Infrastructure'         = 'Disabled'
        'ServicesForNFS-ClientOnly'           = 'Disabled'
        'NFS-Administration'                  = 'Disabled'

        # Keep legacy protocols and optional print formats disabled.
        # Normal SMB file sharing, network printing, and Print to PDF remain available.
        'SMB1Protocol'                        = 'Disabled'
        'SMB1Protocol-Client'                 = 'Disabled'
        'SMB1Protocol-Server'                 = 'Disabled'
        'SimpleTCP'                           = 'Disabled'
        'TelnetClient'                        = 'Disabled'
        'TFTP'                                = 'Disabled'
        'Printing-Foundation-LPDPrintService' = 'Disabled'
        'Printing-Foundation-LPRPortMonitor'  = 'Disabled'
        'Printing-XPSServices-Features'       = 'Disabled'
        'DirectPlay'                          = 'Disabled'
        'Recall'                              = 'Disabled'
    }

    # A known capability may still require a separate matching payload source.
    Capabilities     = @{
        # Removing the legacy player capability also removes its Optional Feature identifier.
        # Keep modern Media Player; do not add a duplicate WindowsMediaPlayer feature rule.
        'Media.WindowsMediaPlayer~~~~0.0.12.0' = 'Absent'
    }

    # Local GPO files are compiled into the WIM by build-image.ps1.
    # Verification covers GPO delivery and registry state, not all advertising behavior.
    Policies         = @{
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-system#allowtelemetry
        RequiredDiagnosticDataOnly = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            Name         = 'AllowTelemetry'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-system#allowlocation
        DisableLocation = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
            Name         = 'DisableLocation'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience#allowfindmydevice
        DisableFindMyDevice = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice'
            Name         = 'AllowFindMyDevice'
            Kind         = 'DWord'
            Value        = 0
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-privacy#allowinputpersonalization
        DisableOnlineSpeech = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'
            Name         = 'AllowInputPersonalization'
            Kind         = 'DWord'
            Value        = 0
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-privacy#disableadvertisingid
        DisableAdvertisingId = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'
            Name         = 'DisabledByGroupPolicy'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience#donotshowfeedbacknotifications
        DisableFeedbackNotifications = @{
            Path         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            Name         = 'DoNotShowFeedbackNotifications'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience#allowtailoredexperienceswithdiagnosticdata
        DisableTailoredExperiences = @{
            Path         = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            Name         = 'DisableTailoredExperiencesWithDiagnosticData'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
        # https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience#allowthirdpartysuggestionsinwindowsspotlight
        DisableThirdPartySuggestions = @{
            Path         = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            Name         = 'DisableThirdPartySuggestions'
            Kind         = 'DWord'
            Value        = 1
            Editions     = @('Professional', 'Enterprise')
            Verification = 'LocalGpo'
        }
    }

    # Desktop removal proposal; validate servicing and dependencies in the test VM.
    # Omitted apps keep their image defaults. Do not remove shared frameworks.
    InboxApps        = @{
        # Consumer content and additional productivity apps.
        'Clipchamp.Clipchamp_4.5.10920.0_neutral_~_yxz26nhyzhsrt'                    = 'Absent' # Video editor.
        'Microsoft.BingNews_4.11.6001.0_neutral_~_8wekyb3d8bbwe'                     = 'Absent'
        'Microsoft.BingWeather_4.54.63038.0_neutral_~_8wekyb3d8bbwe'                 = 'Absent'
        'Microsoft.MicrosoftOfficeHub_19.2506.56051.0_neutral_~_8wekyb3d8bbwe'       = 'Absent' # Office/Microsoft 365 hub.
        'Microsoft.OutlookForWindows_1.0.0.0_neutral__8wekyb3d8bbwe'                 = 'Absent'
        'Microsoft.PowerAutomateDesktop_11.2511.178.0_neutral_~_8wekyb3d8bbwe'       = 'Absent'
        'Microsoft.Todos_2.176.7601.0_neutral_~_8wekyb3d8bbwe'                       = 'Absent'
        'Microsoft.Windows.DevHome_0.100.128.0_neutral_~_8wekyb3d8bbwe'              = 'Absent'
        'Microsoft.WindowsFeedbackHub_2.2607.201.0_neutral_~_8wekyb3d8bbwe'          = 'Absent'
        'Microsoft.YourPhone_1.26062.148.0_neutral_~_8wekyb3d8bbwe'                  = 'Absent' # Phone Link.
        'MSTeams_1.0.0.1_x64__8wekyb3d8bbwe'                                         = 'Absent'

        # Gaming apps, Xbox sign-in UI, and Game Bar are excluded from this profile.
        'Microsoft.MicrosoftSolitaireCollection_4.25.4290.0_neutral_~_8wekyb3d8bbwe' = 'Absent'
        'Microsoft.GamingApp_2026.514.51.0_neutral_~_8wekyb3d8bbwe'                  = 'Absent'
        'Microsoft.Xbox.TCUI_1.23.28005.0_neutral_~_8wekyb3d8bbwe'                   = 'Absent'
        'Microsoft.XboxGamingOverlay_7.325.7221.0_neutral_~_8wekyb3d8bbwe'           = 'Absent'
        'Microsoft.XboxIdentityProvider_12.130.2510.6003_neutral_~_8wekyb3d8bbwe'    = 'Absent'
        'Microsoft.XboxSpeechToTextOverlay_1.123.11001.0_neutral_~_8wekyb3d8bbwe'    = 'Absent'
    }
}
