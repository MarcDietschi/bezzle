; Bezzle's installer for Windows, compiled by Inno Setup 6 (ISCC). make-installer.ps1 lays the app
; out and passes what this needs:
;
;   Name     "Bezzle", or "Bezzle Test" for a copy that leaves Bezzle's own installation alone
;   Arch     arm64 or x64, the architecture of the app laid out
;   Version  the version people see (1.4.2), Build the one updates compare (20261108.1200)
;   Source   the app laid out, as it will be in its folder
;   Runtime  the Windows App Runtime's installer for Arch, from Microsoft
;   Icon     Bezzle's icon (Resources/make-icons.sh), Output the folder the installer goes into
;
; It installs for the person running it alone, without administrator rights, into
; %LOCALAPPDATA%\Programs\Bezzle: a Start menu entry, an entry in Settings › Apps to remove it, the
; bezzle: links that shared designs arrive by, Open in Bezzle on a design's folder in Explorer, and
; the Windows App Runtime that WinUI needs when it is not there yet. Run with /SILENT /UPDATE=1 (as
; updates are), it opens Bezzle again once it is done.

#ifndef Name
  #define Name "Bezzle"
#endif
#ifndef Arch
  #define Arch "arm64"
#endif
#ifndef Version
  #define Version "0.0"
#endif
#ifndef Build
  #define Build "0"
#endif
#if Name == "Bezzle"
  #define Id "com.erik.Bezzle"
#else
  #define Id "com.erik.Bezzle.test"
#endif

[Setup]
AppId={#Id}
AppName={#Name}
AppVersion={#Version}
AppVerName={#Name} {#Version}
VersionInfoVersion={#Version}
VersionInfoProductVersion={#Version}
VersionInfoDescription={#Name} Setup
AppPublisher=Erik Muffler
AppCopyright=© 2026 Erik Muffler
AppPublisherURL=https://bezzle.ch/
AppSupportURL=https://bezzle.ch/
AppUpdatesURL=https://bezzle.ch/download.html
; For the person installing alone, so Windows asks for no administrator: {autopf} is then
; %LOCALAPPDATA%\Programs, and the Start menu, the uninstall entry and the links are theirs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#Name}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; An x64 Bezzle runs on Arm PCs too, through Windows' emulation.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Windows 11, as WinUI and the Windows App Runtime that Bezzle is built with are tested there.
MinVersion=10.0.22000
SetupIconFile={#Icon}
UninstallDisplayIcon={app}\Bezzle.exe
UninstallDisplayName={#Name}
WizardStyle=modern
WizardSizePercent=100
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage
; A Bezzle still open is asked to close (Restart Manager); an update closes it first itself.
CloseApplications=yes
RestartApplications=no
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
OutputDir={#Output}
OutputBaseFilename={#Name == "Bezzle" ? "Bezzle" : "Bezzle-Test"}-{#Version}-Setup-{#Arch}
; The same bytes from the same files: no time of its own in the installer.
TimeStampsInUTC=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"

; Bezzle's own words on the screens the installer shows, in the app's voice (German with du, French
; with vous, Italian with tu, as the app speaks), with no dashes as punctuation.
[Messages]
en.SetupWindowTitle=%1 Setup
de.SetupWindowTitle=%1 installieren
fr.SetupWindowTitle=Installation de %1
it.SetupWindowTitle=Installazione di %1
en.UninstallAppFullTitle=Remove %1
de.UninstallAppFullTitle=%1 entfernen
fr.UninstallAppFullTitle=Supprimer %1
it.UninstallAppFullTitle=Rimuovi %1
en.WizardReady=Ready to install
de.WizardReady=Bereit zum Installieren
fr.WizardReady=Prêt à installer
it.WizardReady=Pronto per l'installazione
en.ReadyLabel1=[name] is installed for you alone, in your own folder, so Windows needs no administrator to allow it.
de.ReadyLabel1=[name] wird nur für dich installiert, in deinem eigenen Ordner. Darum braucht Windows dafür keine Administratorrechte.
fr.ReadyLabel1=[name] est installé pour vous seul, dans votre propre dossier : Windows n'a donc besoin d'aucun droit d'administrateur.
it.ReadyLabel1=[name] viene installato solo per te, nella tua cartella. Per questo Windows non chiede i diritti di amministratore.
en.ReadyLabel2b=Click Install to begin.
de.ReadyLabel2b=Klicke auf „Installieren“, um zu beginnen.
fr.ReadyLabel2b=Cliquez sur Installer pour commencer.
it.ReadyLabel2b=Fai clic su Installa per iniziare.
en.WizardInstalling=Installing
de.WizardInstalling=Wird installiert
fr.WizardInstalling=Installation en cours
it.WizardInstalling=Installazione in corso
en.InstallingLabel=[name] is being put in place. This takes a moment.
de.InstallingLabel=[name] wird eingerichtet. Das dauert einen Moment.
fr.InstallingLabel=[name] est en cours d'installation. Cela prend un instant.
it.InstallingLabel=[name] viene installato. Ci vuole un momento.
en.FinishedHeadingLabel=[name] is installed
de.FinishedHeadingLabel=[name] ist installiert
fr.FinishedHeadingLabel=[name] est installé
it.FinishedHeadingLabel=[name] è installato
en.FinishedLabelNoIcons=You find [name] in the Start menu. It looks for new versions by itself.
de.FinishedLabelNoIcons=Du findest [name] im Startmenü. Neue Versionen sucht es von selbst.
fr.FinishedLabelNoIcons=Vous trouvez [name] dans le menu Démarrer. Il cherche lui-même les nouvelles versions.
it.FinishedLabelNoIcons=Trovi [name] nel menu Start. Cerca da solo le nuove versioni.
en.FinishedLabel=You find [name] in the Start menu. It looks for new versions by itself.
de.FinishedLabel=Du findest [name] im Startmenü. Neue Versionen sucht es von selbst.
fr.FinishedLabel=Vous trouvez [name] dans le menu Démarrer. Il cherche lui-même les nouvelles versions.
it.FinishedLabel=Trovi [name] nel menu Start. Cerca da solo le nuove versioni.
en.ClickFinish=Click Finish to close this window.
de.ClickFinish=Klicke auf „Fertigstellen“, um dieses Fenster zu schließen.
fr.ClickFinish=Cliquez sur Terminer pour fermer cette fenêtre.
it.ClickFinish=Fai clic su Fine per chiudere questa finestra.
en.ConfirmUninstall=Remove %1 from this computer? Your designs stay where they are.
de.ConfirmUninstall=%1 von diesem Computer entfernen? Deine Designs bleiben, wo sie sind.
fr.ConfirmUninstall=Supprimer %1 de cet ordinateur ? Vos designs restent là où ils sont.
it.ConfirmUninstall=Vuoi rimuovere %1 da questo computer? I tuoi design restano dove sono.
en.UninstallStatusLabel=%1 is being removed.
de.UninstallStatusLabel=%1 wird entfernt.
fr.UninstallStatusLabel=%1 est en cours de suppression.
it.UninstallStatusLabel=%1 viene rimosso.
en.UninstalledAll=%1 is removed. Your designs are still in their folder.
de.UninstalledAll=%1 ist entfernt. Deine Designs sind noch in ihrem Ordner.
fr.UninstalledAll=%1 est supprimé. Vos designs sont toujours dans leur dossier.
it.UninstalledAll=%1 è stato rimosso. I tuoi design sono ancora nella loro cartella.
en.ApplicationsFound=Bezzle is open. It saves your designs and closes when you go on.
de.ApplicationsFound=Bezzle ist offen. Es sichert deine Designs und schließt sich, wenn du weitermachst.
fr.ApplicationsFound=Bezzle est ouvert. Il enregistre vos designs et se ferme quand vous continuez.
it.ApplicationsFound=Bezzle è aperto. Salva i tuoi design e si chiude quando prosegui.
en.ApplicationsFound2=Bezzle is open. It saves your designs and closes when you go on.
de.ApplicationsFound2=Bezzle ist offen. Es sichert deine Designs und schließt sich, wenn du weitermachst.
fr.ApplicationsFound2=Bezzle est ouvert. Il enregistre vos designs et se ferme quand vous continuez.
it.ApplicationsFound2=Bezzle è aperto. Salva i tuoi design e si chiude quando prosegui.
en.CloseApplications=&Close Bezzle now
de.CloseApplications=Bezzle jetzt &schließen
fr.CloseApplications=&Fermer Bezzle maintenant
it.CloseApplications=&Chiudi Bezzle ora
en.DontCloseApplications=&Leave it open (Windows then restarts first)
de.DontCloseApplications=&Offen lassen (Windows startet dann zuerst neu)
fr.DontCloseApplications=&Le laisser ouvert (Windows redémarre alors d'abord)
it.DontCloseApplications=&Lascialo aperto (Windows si riavvia prima)

[CustomMessages]
en.OpenBezzle=Open Bezzle
de.OpenBezzle=Bezzle öffnen
fr.OpenBezzle=Ouvrir Bezzle
it.OpenBezzle=Apri Bezzle
en.OpenInBezzle=Open in Bezzle
de.OpenInBezzle=In Bezzle öffnen
fr.OpenInBezzle=Ouvrir dans Bezzle
it.OpenInBezzle=Apri in Bezzle
en.Runtime=Installing the Windows App Runtime, which Bezzle's windows are made with…
de.Runtime=Die Windows App Runtime wird installiert, mit der Bezzles Fenster gemacht sind …
fr.Runtime=Installation du Windows App Runtime, avec lequel les fenêtres de Bezzle sont faites…
it.Runtime=Installazione del Windows App Runtime, con cui sono fatte le finestre di Bezzle…
en.RuntimeFailed=Bezzle is installed, but the Windows App Runtime it needs could not be installed (%1). Bezzle offers to fetch it when it opens; or install it from Microsoft's page for the Windows App SDK and open Bezzle again.
de.RuntimeFailed=Bezzle ist installiert, aber die Windows App Runtime, die es braucht, liess sich nicht installieren (%1). Bezzle bietet beim Öffnen an, sie zu holen. Oder installiere sie von Microsofts Seite zum Windows App SDK und öffne Bezzle noch einmal.
fr.RuntimeFailed=Bezzle est installé, mais le Windows App Runtime dont il a besoin n'a pas pu être installé (%1). Bezzle propose de le télécharger à son ouverture ; vous pouvez aussi l'installer depuis la page de Microsoft sur le Windows App SDK, puis rouvrir Bezzle.
it.RuntimeFailed=Bezzle è installato, ma non è stato possibile installare il Windows App Runtime di cui ha bisogno (%1). Bezzle si offre di scaricarlo quando lo apri; oppure installalo dalla pagina di Microsoft sul Windows App SDK e apri di nuovo Bezzle.

[InstallDelete]
; What an earlier version left that this one no longer has (the app is laid out anew each time;
; nothing of the person's is kept here: designs live in their own folder, settings elsewhere).
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.exe"
Type: filesandordirs; Name: "{app}\fonts"
Type: filesandordirs; Name: "{app}\licenses"
Type: filesandordirs; Name: "{app}\Bezzle.resources"

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Runtime}"; DestDir: "{tmp}"; DestName: "WindowsAppRuntimeInstall.exe"; Flags: deleteafterinstall; Check: NeedsRuntime

[Icons]
Name: "{autoprograms}\{#Name}"; Filename: "{app}\Bezzle.exe"; WorkingDir: "{app}"

[Registry]
; bezzle: links, which a shared design's page on the web hands to Bezzle (Bezzle keeps them
; pointing at itself when it starts: Sources/Bezzle/Links.swift).
Root: HKCU; Subkey: "Software\Classes\bezzle"; ValueType: string; ValueName: ""; ValueData: "URL:Bezzle"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\bezzle"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\bezzle\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Bezzle.exe"",0"
Root: HKCU; Subkey: "Software\Classes\bezzle\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Bezzle.exe"" ""%1"""
; Open in Bezzle on a folder whose name ends in .bezzle: a design is such a folder on Windows (a
; package on the Mac), which Explorer opens like any other folder when double-clicked.
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Bezzle"; ValueType: string; ValueName: ""; ValueData: "{cm:OpenInBezzle}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Bezzle"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Bezzle.exe"",0"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Bezzle"; ValueType: string; ValueName: "AppliesTo"; ValueData: "System.ItemName:~>"".bezzle"""
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Bezzle\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Bezzle.exe"" ""%1"""
; What the updater remembers (when it last looked, a version skipped), taken away with Bezzle.
Root: HKCU; Subkey: "Software\Bezzle\Updates"; Flags: uninsdeletekey dontcreatekey

[Run]
Filename: "{app}\Bezzle.exe"; Description: "{cm:OpenBezzle}"; Flags: nowait postinstall skipifsilent
; An update (run by Bezzle's updater with /UPDATE=1) opens Bezzle again once it is in place.
Filename: "{app}\Bezzle.exe"; Flags: nowait; Check: IsUpdate

[Code]
const
  // The Windows App Runtime packages Bezzle's version of WinUI needs, per user (an unpackaged
  // app's bootstrapper finds them there): the framework, its lifetime manager, and the main package.
  PackagesKey = 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages';
  Publisher = '__8wekyb3d8bbwe';

function IsUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function HasPackage(Prefix, Suffix: String): Boolean;
var
  Names: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if RegGetSubkeyNames(HKCU, PackagesKey, Names) then
    for I := 0 to GetArrayLength(Names) - 1 do
      if (Pos(Prefix, Names[I]) = 1) and (Pos(Suffix, Names[I]) = Length(Names[I]) - Length(Suffix) + 1) then
      begin
        Result := True;
        Exit;
      end;
end;

// Whether this person lacks a Windows App Runtime 1.7 for Bezzle's architecture; any 1.7 serves,
// as Bezzle asks for no smallest one. Its installer is run only then: it takes a while even when
// there is nothing to do.
function NeedsRuntime: Boolean;
var
  Arch: String;
begin
  Arch := '{#Arch}';
  Result := not (HasPackage('Microsoft.WindowsAppRuntime.1.7_', '_' + Arch + Publisher)
    and HasPackage('MicrosoftCorporationII.WinAppRuntime.Main.1.7_', '_' + Arch + Publisher)
    and HasPackage('Microsoft.WinAppRuntime.DDLM.7000.', '_' + Arch + Publisher));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if (CurStep = ssPostInstall) and NeedsRuntime then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('Runtime');
    WizardForm.ProgressGauge.Style := npbstMarquee;
    // Microsoft's installer, quietly, for this person alone (it asks for no administrator).
    if not Exec(ExpandConstant('{tmp}\WindowsAppRuntimeInstall.exe'), '--quiet', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      SuppressibleMsgBox(FmtMessage(CustomMessage('RuntimeFailed'), [Format('0x%.8x', [Code])]), mbError, MB_OK, IDOK);
    WizardForm.ProgressGauge.Style := npbstNormal;
  end;
end;
